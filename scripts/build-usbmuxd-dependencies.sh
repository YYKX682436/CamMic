#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_root="$repo_root/.build/usbmuxd-deps/source"
install_root="$repo_root/.build/usbmuxd-deps/prefix"
archive_root="$repo_root/Vendor/SourceArchives"
deployment_target="13.0"

for tool in clang clang++ make tar shasum pkg-config autoreconf automake; do
  command -v "$tool" >/dev/null || {
    echo "Missing build tool: $tool. Install Xcode Command Line Tools and the documented Autotools packages." >&2
    exit 1
  }
done
if ! command -v glibtoolize >/dev/null && ! command -v libtoolize >/dev/null; then
  echo "Missing libtoolize. Install the libtool build package." >&2
  exit 1
fi

verify_archive() {
  local archive="$1" expected="$2" actual
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    echo "Pinned dependency source checksum mismatch: $archive" >&2
    exit 1
  }
}

verify_archive "$archive_root/libplist-2.8.0.tar.gz" \
  "9c8923a74ad95f16e07fef94b43f7d8c9a5583b4973f1e41dbf25427f388fdee"
verify_archive "$archive_root/libimobiledevice-glue-1.3.3.tar.gz" \
  "fbcc4a17363b9d048699d2445645be7dbe3d33b02c10f13d4f865c7d402ebdb3"
verify_archive "$archive_root/libusbmuxd-2.1.1.tar.gz" \
  "bcc185615a0f4ba80b617696235a084c64b68a1bf546a1dedd85da6b62b8cfbe"

rm -rf "$source_root" "$install_root"
mkdir -p "$source_root" "$install_root"
export MACOSX_DEPLOYMENT_TARGET="$deployment_target"
export CFLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=$deployment_target ${CFLAGS:-}"
export CXXFLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=$deployment_target ${CXXFLAGS:-}"
export LDFLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=$deployment_target -Wl,-headerpad_max_install_names ${LDFLAGS:-}"
export PKG_CONFIG_PATH="$install_root/lib/pkgconfig"
jobs="$(sysctl -n hw.logicalcpu 2>/dev/null || printf '2')"

build_project() {
  local archive="$1" directory="$2" version="$3"
  shift 3
  tar -xzf "$archive_root/$archive" -C "$source_root"
  (
    cd "$source_root/$directory"
    export RELEASE_VERSION="$version"
    ./autogen.sh --prefix="$install_root" --disable-static "$@"
    if [[ "$directory" == "libplist-2.8.0" ]]; then
      make -j"$jobs" -C libcnary
    fi
    make -j"$jobs" -C src
    make -C src install
    make -C include install
  )
}

build_project libplist-2.8.0.tar.gz libplist-2.8.0 2.8.0 --without-cython --without-tools
build_project libimobiledevice-glue-1.3.3.tar.gz libimobiledevice-glue-1.3.3 1.3.3
build_project libusbmuxd-2.1.1.tar.gz libusbmuxd-2.1.1 2.1.1

[[ "$(PKG_CONFIG_PATH="$install_root/lib/pkgconfig" pkg-config --modversion libplist-2.0)" == "2.8.0" ]]
[[ "$(PKG_CONFIG_PATH="$install_root/lib/pkgconfig" pkg-config --modversion libimobiledevice-glue-1.0)" == "1.3.3" ]]
[[ "$(PKG_CONFIG_PATH="$install_root/lib/pkgconfig" pkg-config --modversion libusbmuxd-2.0)" == "2.1.1" ]]

for library in "$install_root"/lib/libplist-2.0.*.dylib \
              "$install_root"/lib/libimobiledevice-glue-1.0.*.dylib \
              "$install_root"/lib/libusbmuxd-2.0.*.dylib; do
  [[ -f "$library" ]] || { echo "Missing built dependency library: $library" >&2; exit 1; }
  architectures="$(lipo -archs "$library")"
  [[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] || {
    echo "Dependency is missing a required universal architecture: $library" >&2
    exit 1
  }
  build_info="$(vtool -show-build "$library")"
  printf '%s\n' "$build_info" | grep -Fq "minos $deployment_target" || {
    echo "Dependency has an unexpected minimum macOS version: $library" >&2
    exit 1
  }
done

printf 'Pinned LGPL USBMux dependencies built from source for universal macOS %s.\n' "$deployment_target"
printf 'PKG_CONFIG_PATH=%s/lib/pkgconfig\n' "$install_root"
