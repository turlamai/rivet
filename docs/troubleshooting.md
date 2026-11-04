# Troubleshooting

**English** · [简体中文](troubleshooting.zh-CN.md)

Start with the machine-readable facts, not with a guess:

```bash
raco rivet --version
raco rivet doctor
raco rivet doctor --json
raco rivet inspect --json
```

`doctor` reports the toolchain, the embedded runtime and project readiness and
prints a "Fix next" block when something required is missing. `inspect` reports
the project's real edit points, maturity and safe lifecycle commands. Redact
private paths and application data before pasting either report into an issue.

## The command fails before it reads the project

**`no rivet.rktd found in this directory or its parents`**

Run the command from the project root (the directory containing `rivet.rktd`),
or pass an explicit project path where the command supports one. `raco rivet
new <name>` creates a new child directory; it does not initialize an existing
one.

**`invalid project name`**

Project names must start with a letter and contain only letters, digits, `_`
and `-`. Rename the directory or choose another name; the application
identifier is derived from it unless `identifier` is set in `rivet.rktd`.

**A configuration error names a key**

Fix `rivet.rktd`, not a generated file. The accepted keys, defaults and
validation rules are in [project configuration](configuration.md). Generated
`Package.swift`, `RivetHost.vcxproj` and CMake files are outputs; `raco rivet
build` rewrites them.

## The build fails

**After pulling a new Rivet revision, `raco rivet` crashes with a linklet or
"instantiate-linklet: mismatch" error**

This is a stale bytecode cache in a linked checkout, not a project defect:

```bash
find . -name compiled -type d -prune -exec rm -rf {} +
raco setup rivet
```

See [CONTRIBUTING](../CONTRIBUTING.md) for the full symptom set.

**`doctor` reports a missing native toolchain**

Install the platform toolchain named in the "Fix next" block:

- Windows: Visual Studio Build Tools with the C++ workload and the Windows SDK;
  WiX v4 or later only when building an MSI.
- macOS: Xcode and the command-line tools (`xcode-select --install`); production
  signing additionally needs a Developer ID identity and a notary profile.
- Linux: GTK4 development files, CMake, a C++ compiler, `pkg-config` and `ldd`.

Then rerun `raco rivet doctor`.

**Linux cannot find the embeddable Racket CS runtime**

`raco rivet build` needs an embeddable Racket CS runtime, not only the `racket`
executable. Point `RIVET_RACKET_LIBRARY` and `RIVET_RACKET_BOOT_DIR` at a
runtime built for embedding, or use the same setup action the generated CI
workflow uses
(`turlamai/rivet/.github/actions/setup-embed-racket`). The exact contract is in
[embedding](embedding.md) and [continuous integration](ci.md).

**Generated client files differ from the tree**

```bash
raco rivet generate --check
raco rivet generate
```

Commit the regenerated Swift/C++/Kotlin files with the backend change that
caused them. Do not hand-edit generated clients; `doctor --release` rejects a
stale or hand-edited tree.

**The packaged app differs from `raco rivet dev`**

`dev` stages resources under `.rivet/stage/app`; a package reads `app/` beside
the executable on Windows/Linux and `Contents/Resources/app` on macOS. A path
that works in development but not after packaging is almost always a guessed
executable-relative path instead of `resource-path`. Run `raco rivet package`
and launch the packaged artifact, then `raco rivet verify`.

## The app launches and then fails

**No window appears, or the process exits immediately**

Run `raco rivet dev` from a terminal and capture the first error, then:

```bash
raco rivet doctor
raco rivet clean
raco rivet build
```

On Linux confirm a Wayland or X11 session and the GTK4 runtime; on macOS launch
the packaged `.app` from Finder to distinguish a bundle problem from a terminal
environment problem; on Windows launch the packaged executable outside the IDE
to see the real working directory and DLL search path.

**The backend starts but an RPC fails**

Uncaught backend exceptions become bounded Error frames, not process exits.
Check the native diagnostic sink and the application log. Diagnostics are
opt-in and silent by default; see [diagnostics](diagnostics.md). For a
long-running operation that seems to hang, remember that RVT1 Cancel tears the
request down but handlers have no cooperative cancellation check today — chunk
the work into page-sized RPCs.

## Packaging, signing and release

**`release` or `package --production` fails closed on missing credentials**

Production modes refuse to emit an unsigned artifact. Set the environment
documented in [production signing](production-signing.md), or use
`raco rivet package` / `raco rivet release --development` for a development
artifact. Development artifacts are not publisher-trusted and must be labeled
as such.

**AppImage release fails without an icon**

AppImage requires `linux-icon` in `rivet.rktd`; packaging fails closed rather
than shipping a placeholder. Add a PNG and rerun. deb/rpm warn instead of
failing, but the desktop entry is then incomplete.

**The macOS app is rejected by Gatekeeper or notarization**

Check `codesign --verify --deep --strict`, the notary profile name, and
`raco rivet verify --production`. An ad-hoc signed development build is expected
to require the explicit right-click open; it is not evidence of notarization.

**The Windows MSI build cannot find WiX**

Install WiX Toolset v4 or later and make it available on `PATH`. The MSI is the
human installer; the portable ZIP is the update payload.

**A release feed returns 404 or the client says no update is available**

Confirm the feed URL, channel name and manifest file name are the ones the
release actually published (`update-<channel>.json`), and that the manifest's
application id, platform, architecture and installer kind match the installed
build. A feed signed with a different key id is rejected by design; rotate keys
through the dual-trust window, not by editing a published manifest.

**An update downloaded but did not install**

The managed updater intentionally stops at a verified artifact; installation
consent, elevation, restart and health policy belong to the host. Check the
platform handoff (MSI/AppImage), the journal, and the next-launch recovery
path. Never delete a journal or backup by hand before reading
[release and updates](release-and-updates.md).

## Acceptance and CI

**`acceptance` fails with missing coverage or a timeout**

The manifest must declare every requirement for the current platform, and each
suite gets a bounded timeout. A skipped, unrun or wrong-platform leg is not a
pass. Inspect the JSON report and the archived artifact; `acceptance --dry-run`
validates the manifest without launching commands. See
[product acceptance](product-acceptance.md).

**A generated project has no native CI**

New projects contain `.github/workflows/native.yml`. Existing projects can
adopt the contract from [continuous integration](ci.md); keep every Rivet pin on
the same release.

## Clean up and start over

```bash
raco rivet clean     # removes .rivet/, build/, dist/
```

`clean` never deletes application sources, `rivet.rktd`, the schema baseline or
the acceptance manifest. To remove Rivet itself, use `raco pkg remove rivet`;
that does not delete generated projects or user data. Application data lives in
the platform directory documented under [project configuration](configuration.md#application-data-directories);
back it up before deleting it.

## Reporting a bug

Include the output of `raco rivet --version`, `raco rivet doctor --json`, the
platform and architecture, the exact commands, and the smallest reproduction.
Remove credentials, signing keys, private paths and customer data first.
