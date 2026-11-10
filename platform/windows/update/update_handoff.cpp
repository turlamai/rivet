#include "update_handoff.hpp"

#include <windows.h>

#include "rivet/version_compare.hpp"

#include <chrono>
#include <cstddef>
#include <cwctype>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <vector>

namespace rivet::update {
namespace {

std::wstring safe_component(std::wstring value) {
  for (auto& ch : value) {
    if (!(std::iswalnum(ch) || ch == L'.' || ch == L'_' || ch == L'-')) {
      ch = L'_';
    }
  }
  if (value.empty() || value == L"." || value == L"..") {
    throw std::invalid_argument("application id has no safe path component");
  }
  return value;
}

std::filesystem::path update_root(std::wstring const& application_id) {
  wchar_t buffer[32768]{};
  auto const length = ::GetEnvironmentVariableW(
      L"LOCALAPPDATA", buffer, static_cast<DWORD>(std::size(buffer)));
  if (length == 0 || length >= std::size(buffer)) {
    throw std::system_error(::GetLastError(), std::system_category(),
                            "LOCALAPPDATA is unavailable");
  }
  auto root = std::filesystem::path(buffer) / L"Rivet" / L"updates" /
              safe_component(application_id);
  std::filesystem::create_directories(root);
  return root;
}

std::string handoff_script(unsigned long pid, unsigned timeout_seconds) {
  // Paths never enter the script body; they travel as quoted %~1...%~4
  // parameters so Unicode is preserved by CreateProcessW's command line.
  auto const tries = timeout_seconds == 0 ? 1 : timeout_seconds;
  std::string script =
      "@echo off\r\n"
      "rem Rivet MSI handoff - generated; safe to delete.\r\n"
      "set /a n=0\r\n"
      ":wait\r\n"
      "tasklist /FI \"PID eq " +
      std::to_string(pid) + "\" 2>nul | find \"" + std::to_string(pid) +
      "\" >nul\r\n"
      "if errorlevel 1 goto install\r\n"
      "ping -n 2 127.0.0.1 >nul\r\n"
      "set /a n+=1\r\n"
      "if %n% LSS " +
      std::to_string(tries) +
      " goto wait\r\n"
      "> \"%~4\" echo process-exit-timeout\r\n"
      "exit /b 1\r\n"
      ":install\r\n"
      "msiexec /passive /norestart /i \"%~1\" /l*v \"%~2\"\r\n"
      "set \"rivet_exit=%errorlevel%\"\r\n"
      "if \"%rivet_exit%\"==\"0\" goto relaunch\r\n"
      "if \"%rivet_exit%\"==\"1641\" goto relaunch\r\n"
      "if \"%rivet_exit%\"==\"3010\" goto relaunch\r\n"
      "> \"%~4\" echo msiexec-failed-%rivet_exit%\r\n"
      ":relaunch\r\n"
      "start \"\" \"%~3\"\r\n"
      "exit /b %rivet_exit%\r\n";
  return script;
}

std::wstring quote(std::filesystem::path const& value) {
  // Windows paths cannot contain a quote. Reject explicitly rather than
  // attempting cmd.exe escaping at a security-sensitive boundary.
  auto text = value.wstring();
  if (text.find(L'\"') != std::wstring::npos) {
    throw std::invalid_argument("update path contains a quote");
  }
  return L"\"" + text + L"\"";
}

std::optional<std::filesystem::path> newest_failure(
    std::filesystem::path const& root) {
  std::optional<std::filesystem::path> result;
  std::filesystem::file_time_type newest{};
  std::error_code ec;
  for (auto const& entry : std::filesystem::directory_iterator(root, ec)) {
    auto marker = entry.path() / L"failure.txt";
    if (!entry.is_directory(ec) || !std::filesystem::is_regular_file(marker, ec)) {
      continue;
    }
    auto stamp = std::filesystem::last_write_time(marker, ec);
    if (!ec && (!result || stamp > newest)) {
      result = marker;
      newest = stamp;
    }
  }
  return result;
}

}  // namespace

std::optional<MsiHandoff::Failure> MsiHandoff::ConsumeFailure(
    std::wstring const& application_id) {
  auto const marker = newest_failure(update_root(application_id));
  if (!marker) return std::nullopt;
  std::ifstream input(*marker, std::ios::binary);
  std::string bytes((std::istreambuf_iterator<char>(input)),
                    std::istreambuf_iterator<char>());
  std::error_code ignored;
  std::filesystem::remove(*marker, ignored);
  if (bytes.empty()) bytes = "update-install-failed";
  return Failure{std::wstring(bytes.begin(), bytes.end())};
}

void MsiHandoff::CleanupStaleAttempts(std::wstring const& application_id,
                                      unsigned max_age_hours) {
  auto const root = update_root(application_id);
  auto const cutoff = std::filesystem::file_time_type::clock::now() -
                      std::chrono::hours(max_age_hours);
  std::error_code ec;
  for (auto const& entry : std::filesystem::directory_iterator(root, ec)) {
    if (!entry.is_directory(ec)) continue;
    auto const stamp = entry.last_write_time(ec);
    if (!ec && stamp < cutoff) {
      std::filesystem::remove_all(entry.path(), ec);
      ec.clear();
    }
  }
}

std::size_t MsiHandoff::DiscardNonUpgrades(
    std::wstring const& application_id, std::wstring const& running_version) {
  auto const root = update_root(application_id);
  // Versions are ASCII (validated at queue time; the running identity comes
  // from the same manifest family), so byte truncation is exact.
  std::string const running_narrow(running_version.begin(),
                                   running_version.end());
  auto const running =
      rivet::update::parse_dotted_version(running_narrow);
  if (!running) {
    // A running version this class cannot parse means the caller's own
    // identity is broken; refusing to touch any attempt is the safe answer.
    return 0;
  }
  std::size_t discarded = 0;
  std::error_code ec;
  for (auto const& entry : std::filesystem::directory_iterator(root, ec)) {
    if (!entry.is_directory(ec)) continue;
    auto const version_file = entry.path() / L"version.txt";
    if (!std::filesystem::is_regular_file(version_file, ec)) continue;
    std::ifstream input(version_file, std::ios::binary);
    std::string bytes((std::istreambuf_iterator<char>(input)),
                      std::istreambuf_iterator<char>());
    // nullopt (unparseable recorded version) keeps the attempt: not
    // provably stale. false (parsed and not an upgrade) discards it.
    auto const is_upgrade = rivet::update::version_is_upgrade(
        std::string_view(bytes), running_narrow);
    if (is_upgrade.has_value() && !*is_upgrade) {
      std::filesystem::remove_all(entry.path(), ec);
      ec.clear();
      ++discarded;
    }
  }
  return discarded;
}

void MsiHandoff::LaunchVerifiedInstaller(
    std::wstring const& application_id,
    std::filesystem::path const& verified_msi,
    std::wstring const& queued_version,
    std::filesystem::path const& relaunch_executable,
    std::function<void()> release_lease,
    unsigned exit_timeout_seconds) {
  if (!std::filesystem::is_regular_file(verified_msi) ||
      verified_msi.extension() != L".msi") {
    throw std::invalid_argument("verified installer must be an existing .msi");
  }
  if (!std::filesystem::is_regular_file(relaunch_executable)) {
    throw std::invalid_argument("relaunch executable does not exist");
  }
  // Versions are ASCII by manifest contract; anything else would write a
  // version.txt DiscardNonUpgrades can never parse, so reject at queue time.
  for (wchar_t const ch : queued_version) {
    if (ch == 0 || ch > 0x7f) {
      throw std::invalid_argument(
          "queued version must be non-empty ASCII");
    }
  }
  if (queued_version.empty()) {
    throw std::invalid_argument("queued version must be non-empty ASCII");
  }

  auto const root = update_root(application_id);
  auto const attempt = root / (std::to_wstring(::GetCurrentProcessId()) + L"-" +
                               std::to_wstring(::GetTickCount64()));
  std::filesystem::create_directories(attempt);
  auto const script_path = attempt / L"install.cmd";
  auto const log_path = attempt / L"msiexec.log";
  auto const failure_path = attempt / L"failure.txt";
  auto const version_path = attempt / L"version.txt";
  auto const script = handoff_script(::GetCurrentProcessId(),
                                     exit_timeout_seconds);
  {
    std::ofstream output(script_path, std::ios::binary | std::ios::trunc);
    output.write(script.data(), static_cast<std::streamsize>(script.size()));
    output.close();
    if (!output) {
      throw std::system_error(std::make_error_code(std::errc::io_error),
                              "could not write MSI handoff script");
    }
  }
  {
    std::ofstream output(version_path, std::ios::binary | std::ios::trunc);
    output.write(queued_version.data(),
                 static_cast<std::streamsize>(queued_version.size()));
    output.close();
    if (!output) {
      throw std::system_error(std::make_error_code(std::errc::io_error),
                              "could not record the queued version");
    }
  }

  std::wstring command = L"cmd.exe /d /s /c call " + quote(script_path) + L" " +
                         quote(std::filesystem::absolute(verified_msi)) + L" " +
                         quote(log_path) + L" " +
                         quote(std::filesystem::absolute(relaunch_executable)) +
                         L" " + quote(failure_path);
  std::vector<wchar_t> mutable_command(command.begin(), command.end());
  mutable_command.push_back(L'\0');
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!::CreateProcessW(nullptr, mutable_command.data(), nullptr, nullptr,
                        FALSE, CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP,
                        nullptr, attempt.c_str(), &startup, &process)) {
    auto const error = ::GetLastError();
    std::error_code ignored;
    std::filesystem::remove_all(attempt, ignored);
    throw std::system_error(error, std::system_category(),
                            "could not launch MSI handoff");
  }
  ::CloseHandle(process.hThread);
  ::CloseHandle(process.hProcess);
  if (release_lease) release_lease();
}

}  // namespace rivet::update
