#!/usr/bin/env bash
# Build the embeddable Racket CS runtime for iOS targets.
#
# Rivet's standalone iOS hosts embed a portable-bytecode (pb) Racket CS:
# `--enable-pb --enable-mach=tpb64l` builds a bytecode virtual machine with
# no run-time code generation, which is what App Store review requires on a
# platform that enforces W^X (see the "writes to space_code memory" note in
# ChezScheme/c/segment.md and docs/mobile-hosts.md for the full rationale).
#
# Stages (all three are needed for a device or simulator build):
#   host-base      native Racket CS build of the pinned source; provides the
#                  `--enable-racket`/`--enable-scheme` pair every pb and
#                  cross build bootstraps from
#   host-compiler  native pb (tpb64l) build that RUNS on this Mac; its raco
#                  compiles product backend modules into the portable pb
#                  bytecode an iOS host executes
#   device         cross build for the iPhoneOS SDK (arm64)
#   simulator      cross build for the iPhoneSimulator SDK (arm64)
#
# The libffi dependency of pb builds is compiled per SDK from the libffi
# bundled in the Racket source (src/bc/foreign/libffi) and exposed to the
# configure probe through a PKG_CONFIG_PATH shim.
#
# Usage:
#   build-embedded-racket.sh --stage host-base    --output DIR [--jobs N] [--source-dir DIR]
#   build-embedded-racket.sh --stage host-compiler --output DIR --base-dir DIR [--jobs N] [--source-dir DIR]
#   build-embedded-racket.sh --stage device|simulator --output DIR --base-dir DIR [--jobs N] [--source-dir DIR]
set -euo pipefail

racket_version="9.3"
archive_sha256="3a01324d559a15e3f1f58b0c57a92bb344dce534e72e564e0d8b75e3b9c65295"
ios_min_version="16.0"
stage=""
output=""
base_dir=""
source_dir=""
jobs="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stage) stage="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --base-dir) base_dir="$2"; shift 2 ;;
    --source-dir) source_dir="$2"; shift 2 ;;
    --jobs) jobs="$2"; shift 2 ;;
    *) usage ;;
  esac
done

case "$stage" in
  host-base|host-compiler|device|simulator) ;;
  *) echo "unknown or missing --stage: $stage" >&2; usage ;;
esac
[ -n "$output" ] || { echo "missing --output" >&2; usage; }
# Resolve the output prefix to an absolute path immediately: relative
# paths would otherwise resolve inside each build subshell (and an
# unresolvable path silently produced an empty --prefix, pointing the
# install at the filesystem root).
mkdir -p "$output"
output="$(cd "$output" && pwd)"
if [ "$stage" != "host-base" ] && [ -z "$base_dir" ]; then
  echo "--stage $stage requires --base-dir (the host-base output)" >&2
  exit 2
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/rivet-ios-racket.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

if [ -z "$source_dir" ]; then
  archive="$work_dir/racket-minimal-$racket_version-src-builtpkgs.tgz"
  curl --fail --location --retry 3 --output "$archive" \
    "https://download.racket-lang.org/releases/$racket_version/installers/racket-minimal-$racket_version-src-builtpkgs.tgz"
  checksum_tool="sha256sum"; command -v sha256sum >/dev/null 2>&1 || checksum_tool="shasum -a 256"
  echo "$archive_sha256  $archive" | $checksum_tool --check -
  tar -xzf "$archive" -C "$work_dir"
  source_dir="$work_dir/racket-$racket_version"
fi
source_dir="$(cd "$source_dir" && pwd)"

# Racket's pure-Racket Mach-O signer (src/mac/codesign.rkt) misplaces the
# ad-hoc signature on pb-build binaries ("code signature is not at end of
# file"), which aborts host-pb and simulator builds on current toolchains.
# Route the signing through the system codesign instead — standard for
# iOS-family Mach-O images. Upstream issue to report against Racket.
signer="$source_dir/src/mac/codesign.zuo"
sed -e 's/(define codesign-via-racket? #t)/(define codesign-via-racket? #f)/' \
    -e 's/(if (or cross? codesign-via-racket?)/(if codesign-via-racket?/g' \
    "$signer" > "$signer.portable" && mv "$signer.portable" "$signer"
source_dir="$(cd "$source_dir" && pwd)"

# The host-base stage records its Chez bootstrap directory beside the
# installed prefix; a sibling build tree still wins when discoverable.
scheme_dir="$(cat "$base_dir/share/rivet-chez-build-dir" 2>/dev/null || true)"
if [ -z "$scheme_dir" ]; then
  scheme_dir="$(find "$base_dir" -type d -path '*src/build/cs/c' -print -quit 2>/dev/null || true)"
fi
base_racket="$base_dir/bin/racket"
if [ "$stage" != "host-base" ]; then
  [ -x "$base_racket" ] || { echo "host-base racket not found: $base_racket" >&2; exit 1; }
  [ -n "$scheme_dir" ] || [ -d "$scheme_dir" ] || { echo "Chez bootstrap dir not found under --base-dir: $base_dir" >&2; exit 1; }
fi

# Compile the libffi bundled in the Racket source for one SDK. pb builds
# link libffi for their foreign-function boundary; the probe reads the
# flags from the generated pkg-config file.
build_target_libffi() {
  # Function-scope the scratch variables: an unqualified `sdk=` here would
  # clobber the caller's canonicalized simulator SDK symlink.
  local sdk_name="$1" arch="$2" min_flag="$3" prefix="$4"
  local sdk build_dir
  sdk="$(xcrun -sdk "$sdk_name" --show-sdk-path)"
  build_dir="$work_dir/libffi-$sdk_name"
  mkdir -p "$build_dir" "$prefix"
  (
    cd "$build_dir"
    CC="xcrun -sdk $sdk_name clang" \
    CFLAGS="-arch $arch -isysroot $sdk $min_flag" \
    LDFLAGS="-arch $arch -isysroot $sdk" \
    "$source_dir/src/bc/foreign/libffi/configure" \
      --host="$arch-apple-darwin" --prefix="$prefix"
    make -j"$jobs"
    make install
  )
}

# Assemble lib/libracketcs.a, the boot trio, and the embedding headers from
# a cross build directory. Mirrors the non-Windows install path of
# src/cs/c/build.zuo: repack the bundled static libraries, archive the pb
# stage objects plus boot.o, install the -v boot files under their runtime
# names, and copy the version-matched headers.
harvest_cross_build() {
  build_dir="$1" source_root="$2" dest="$3" bootstrap_racket="$4" libffi_prefix="$5"
  cs_c="$build_dir/cs/c"
  mach="tpb64l"
  chez_boot="$cs_c/ChezScheme/$mach/boot/$mach"

  repack="$cs_c/repack"
  rm -rf "$repack"
  mkdir -p "$repack" "$dest/lib" "$dest/include" "$dest/runtime"
  # Extract each member archive into its own subdirectory: libkernel.a and
  # libffi.a both contain an `ffi.o` (Chez's FFI glue vs libffi's raw
  # layer), and a shared extraction directory would let one clobber the
  # other.
  (
    cd "$repack"
    mkdir libz liblz4 rktio libkernel libffi
    (cd libz && ar x "$cs_c/ChezScheme/$mach/zlib/libz.a")
    (cd liblz4 && ar x "$cs_c/ChezScheme/$mach/lz4/lib/liblz4.a")
    (cd rktio && ar x "$cs_c/rktio/librktio.a")
    (cd libkernel && ar x "$chez_boot/libkernel.a")
    # libffi is merged in so consumers link a single archive; a native
    # install would instead rely on a system libffi.
    (cd libffi && ar x "$libffi_prefix/lib/libffi.a")
  )
  ar cr "$dest/lib/libracketcs.a" \
    "$repack"/*/*.o \
    "$cs_c"/petite*.o "$cs_c"/scheme*.o "$cs_c"/racket*.o \
    "$cs_c/boot.o"
  ranlib "$dest/lib/libracketcs.a"

  # add-terminator.rkt applies the same defensive trailing byte the real
  # install applies to the installed boot files.
  for pair in "petite-v.boot:petite.boot" "scheme-v.boot:scheme.boot" \
              "racket-v.boot:racket.boot"; do
    src_boot="${pair%%:*}" dest_boot="${pair##*:}"
    "$bootstrap_racket" "$source_root/src/cs/c/add-terminator.rkt" \
      "$cs_c/$src_boot" "$dest/lib/$dest_boot"
    cp "$dest/lib/$dest_boot" "$dest/runtime/$dest_boot"
  done

  cp "$source_root/src/cs/c/api.h" "$dest/include/racketcs.h"
  cp "$source_root/src/cs/c/boot.h" "$dest/include/racketcsboot.h"
  cp "$chez_boot/scheme.h" "$dest/include/chezscheme.h"
}

stage_build() {
  mkdir -p "$output"
  case "$stage" in
    host-base)
      build_dir="$work_dir/build-base"
      mkdir -p "$build_dir"
      (
        cd "$build_dir"
        "$source_dir/src/configure" --prefix="$(cd "$output" && pwd)" --enable-xonx
        make -j"$jobs"
        make install
      )
      # Persist the Chez bootstrap build tree inside the prefix: later
      # stages need it (--enable-scheme), and the work directory is deleted
      # on exit.
      mv "$build_dir" "$output/build-base"
      mkdir -p "$output/share"
      printf '%s\n' "$(cd "$output/build-base/cs/c" && pwd)" \
        > "$output/share/rivet-chez-build-dir"
      ;;
    host-compiler)
      build_dir="$work_dir/build-host-pb"
      mkdir -p "$build_dir"
      (
        cd "$build_dir"
        "$source_dir/src/configure" \
          --prefix="$(cd "$output" && pwd)" --enable-xonx \
          --enable-pb --enable-mach=tpb64l \
          --enable-racket="$base_racket" --enable-scheme="$scheme_dir"
        make -j"$jobs"
        make install
      )
      ;;
    device|simulator)
      if [ "$stage" = "device" ]; then
        sdk_name="iphoneos" min_flag="-miphoneos-version-min=$ios_min_version"
      else
        sdk_name="iphonesimulator" min_flag="-miphonesimulator-version-min=$ios_min_version"
      fi
      sdk="$(xcrun -sdk "$sdk_name" --show-sdk-path)"
      if [ "$stage" = "simulator" ]; then
        # The CS configure only recognizes a simulator SDK when its path ENDS
        # in "iPhoneSimulator.sdk" (versioned directories like
        # "iPhoneSimulator27.2.sdk" fall through to -miphoneos-version-min,
        # which retargets the build at the device and breaks the iconv link).
        # A canonically named symlink satisfies the matcher without patching.
        canonical="$work_dir/sdk-iPhoneSimulator.sdk"
        ln -sfn "$sdk" "$canonical"
        sdk="$canonical"
      fi
      libffi_prefix="$work_dir/libffi-$sdk_name"
      build_target_libffi "$sdk_name" arm64 "$min_flag" "$libffi_prefix"
      # The cross build's executables are build-side artifacts the harvest
      # never consumes (only the archive, boot files, and headers are), and
      # codesign rejects the simulator Mach-O layout under strict
      # validation. Replace the mac signing helper with a no-op for this
      # stage; native stages keep real signing.
      cat > "$source_dir/src/mac/codesign.zuo" <<'ZUO'
#lang zuo
(require "../lib.zuo")
(provide codesign-via-racket?
         strip-signature*
         restore-signature*
         install_name_tool*)
(define codesign-via-racket? #f)
(define (strip-signature* cross? bootstrap-racket dest) (void))
(define (restore-signature* cross? bootstrap-racket dest) (void))
(define (install_name_tool* cross? bootstrap-racket args) (void))
ZUO
      echo "=== Rivet iOS toolchain: stage=$stage sdk=$sdk"
      build_dir="$work_dir/build-$sdk_name"
      mkdir -p "$build_dir"
      (
        cd "$build_dir"
        PKG_CONFIG_PATH="$libffi_prefix/lib/pkgconfig" \
        "$source_dir/src/configure" \
          --prefix="$(cd "$output" && pwd)" --enable-xonx \
          --host=aarch64-apple-darwin --enable-ios="$sdk" \
          --enable-pb --enable-mach=tpb64l \
          --enable-racket="$base_racket" --enable-scheme="$scheme_dir"
        make -j"$jobs"
      )
      # A cross build's `make install` re-runs host-side steps (ad-hoc
      # signing, package collection) that assume the built binaries run on
      # this machine, so the embedding layout is harvested directly from the
      # build tree following src/cs/c/build.zuo's install recipe instead.
      harvest_cross_build "$build_dir" "$source_dir" "$output" "$base_racket" "$libffi_prefix"
      ;;
  esac
}

# Stages are idempotent: a completed stage is skipped (and re-verified)
# unless RIVET_TOOLCHAIN_FORCE=1. This gives CI cache hits a clean hook.
stage_done="$output/share/rivet-stage-$stage-done"
if [ -f "$stage_done" ] && [ "${RIVET_TOOLCHAIN_FORCE:-0}" != "1" ]; then
  echo "=== stage $stage already built; skipping (RIVET_TOOLCHAIN_FORCE=1 rebuilds)"
else
  stage_build
  mkdir -p "$output/share"
  touch "$stage_done"
fi

# Per-stage artifact verification. Host stages ship a runnable racket/raco
# plus (for host-base) the persisted Chez bootstrap tree; cross stages ship
# the merged static archive, the boot trio, and the embedding headers. The
# verification matches each platform's install layout rather than the
# macOS action's discovery.
case "$stage" in
  host-base)
    for artifact in "$output/bin/racket" "$output/bin/raco" \
                    "$output/share/rivet-chez-build-dir" \
                    "$output/build-base/cs/c"; do
      [ -e "$artifact" ] || { echo "missing expected artifact: $artifact" >&2; exit 1; }
    done
    printf 'RIVET_PB_HOST_BASE=%s\n' "$output"
    ;;
  host-compiler)
    for artifact in "$output/bin/racket" "$output/bin/raco"; do
      [ -e "$artifact" ] || { echo "missing expected artifact: $artifact" >&2; exit 1; }
    done
    printf 'RIVET_PB_HOST_COMPILER=%s\n' "$output"
    ;;
  device|simulator)
    library="$(find "$output" -name 'libracketcs*.a' -print -quit)"
    include_dir="$(dirname "$(find "$output" -name chezscheme.h -print -quit)")"
    boot_dir="$output/runtime"
    for artifact in "$library" "$include_dir/chezscheme.h" "$include_dir/racketcs.h" \
                    "$boot_dir/petite.boot" "$boot_dir/scheme.boot" "$boot_dir/racket.boot"; do
      [ -e "$artifact" ] || { echo "missing expected artifact: $artifact" >&2; exit 1; }
    done
    printf 'RIVET_IOS_LIBRARY=%s\n' "$library"
    printf 'RIVET_IOS_INCLUDE=%s\n' "$include_dir"
    printf 'RIVET_IOS_BOOT_DIR=%s\n' "$boot_dir"
    ;;
esac
