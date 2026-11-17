#pragma once

// Version comparison shared by the platform update handoffs (issue #437): a
// queued installer must never run against an application that is already at
// or above the queued version. Parsing is deliberately conservative — only a
// leading dotted numeric prefix counts, because signed manifests may carry
// prerelease suffixes and an unparseable version is not proof of staleness.

#include <array>
#include <charconv>
#include <optional>
#include <string_view>

namespace rivet::update {

// Parses "1.2.3" / "v1.2" / "0.9.11" into major/minor/patch (missing
// components read as zero). Returns nullopt for anything else — empty text,
// non-numeric components, or trailing characters after the dotted prefix.
inline std::optional<std::array<unsigned long, 3>> parse_dotted_version(
    std::string_view text) {
  if (!text.empty() && (text.front() == 'v' || text.front() == 'V')) {
    text.remove_prefix(1);
  }
  if (text.empty()) return std::nullopt;
  std::array<unsigned long, 3> components{0, 0, 0};
  for (int index = 0; index < 3; ++index) {
    if (text.empty()) return components;
    auto const begin = text.data();
    auto const end = text.data() + text.size();
    unsigned long value = 0;
    auto const result = std::from_chars(begin, end, value);
    if (result.ec != std::errc{} || result.ptr == begin) return std::nullopt;
    components[static_cast<std::size_t>(index)] = value;
    text.remove_prefix(static_cast<std::size_t>(result.ptr - begin));
    if (text.empty()) return components;
    if (text.front() != '.') return std::nullopt;
    text.remove_prefix(1);
    // A trailing dot ("1.2.") has no component after it.
    if (text.empty()) return std::nullopt;
  }
  // More than three components is a shape this comparison does not claim to
  // order; reject rather than silently ignoring the tail.
  return std::nullopt;
}

// nullopt when either version is unparseable — the caller keeps the queued
// attempt, because a malformed or suffixed version is not proof of
// staleness. Otherwise true when queued > running.
inline std::optional<bool> version_is_upgrade(std::string_view queued,
                                              std::string_view running) {
  auto const queued_version = parse_dotted_version(queued);
  auto const running_version = parse_dotted_version(running);
  if (!queued_version || !running_version) return std::nullopt;
  return *queued_version > *running_version;
}

}  // namespace rivet::update
