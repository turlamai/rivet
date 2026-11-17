#include "rivet/version_compare.hpp"

#include <cassert>
#include <string>

namespace {

using rivet::update::parse_dotted_version;
using rivet::update::version_is_upgrade;

}  // namespace

int main() {
  // Full triples, in every ordering.
  assert(version_is_upgrade("1.2.3", "1.2.2") == true);
  assert(version_is_upgrade("1.2.3", "1.2.3") == false);
  assert(version_is_upgrade("1.2.2", "1.2.3") == false);

  // Missing components read as zero.
  assert(version_is_upgrade("1.3", "1.2.9") == true);
  assert(version_is_upgrade("2", "1.9.9") == true);
  assert(parse_dotted_version("1.2").value()[2] == 0);

  // Component boundaries never leak digits across dots.
  assert(version_is_upgrade("1.2.10", "1.2.9") == true);
  assert(version_is_upgrade("1.10", "1.9.5") == true);

  // A leading v is tolerated.
  assert(version_is_upgrade("v1.2.3", "1.2.2") == true);
  assert(version_is_upgrade("V0.9", "0.8.1") == true);

  // Unparseable shapes are not provable upgrades: the caller keeps the
  // queued attempt rather than discarding a possibly valid update.
  assert(version_is_upgrade("", "1.2.3") == std::nullopt);
  assert(version_is_upgrade("1.2.3", "") == std::nullopt);
  assert(version_is_upgrade("1.2.3-beta.1", "1.2.2") == std::nullopt);
  assert(version_is_upgrade("1.2", "1.2.x") == std::nullopt);
  assert(version_is_upgrade("1..3", "1.2.3") == std::nullopt);
  assert(version_is_upgrade("1.2.", "1.2.3") == std::nullopt);
  assert(version_is_upgrade("1.2.3.4", "1.2.3") == std::nullopt);
  assert(version_is_upgrade("abc", "1") == std::nullopt);

  return 0;
}
