#!/bin/sh
# Optional lab dependencies only. Never builds or replaces the production C core.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
root="$repo_dir/Vendor/native-terminal"
mkdir -p "$root"
stage=$(mktemp -d "$root/.prepare.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM

swiftterm_revision=28c6d1d95de156a36a2eaa278177ee7f8a15d322
swiftterm_checksum=d77fff6d836b6a142325d736e84b481f637d9b4733aad36431f1d2ff24338d2e
if [ ! -d "$root/SwiftTerm" ]; then
    curl --fail --location --silent --show-error \
        "https://codeload.github.com/migueldeicaza/SwiftTerm/tar.gz/$swiftterm_revision" \
        -o "$stage/swiftterm.tar.gz"
    printf '%s  %s\n' "$swiftterm_checksum" "$stage/swiftterm.tar.gz" | shasum -a 256 -c -
    mkdir "$stage/SwiftTerm"
    tar -xzf "$stage/swiftterm.tar.gz" --strip-components=1 -C "$stage/SwiftTerm"
    printf '%s\n' "$swiftterm_revision" > "$stage/SwiftTerm/.santty-revision"
    mv "$stage/SwiftTerm" "$root/SwiftTerm"
fi
if [ "$(head -n 1 "$root/SwiftTerm/.santty-revision" 2>/dev/null || true)" != "$swiftterm_revision" ]; then
    echo "Unexpected SwiftTerm checkout. Move $root/SwiftTerm aside and rerun $0." >&2
    exit 1
fi

if ! grep -q 'public func presentExternalFrame()' "$root/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalRenderView.swift"; then
    patch -s -d "$root/SwiftTerm" -p1 < "$repo_dir/Patches/SwiftTerm+ExternalFramePresentation.patch"
fi

vt_version=1.0.0
vt_checksum=2c32b7409b2b6c2ef6cfd606526de357762ad458bdc27134ad074e86506a8bc2
if [ ! -d "$root/ghostty-vt.xcframework" ]; then
    curl --fail --location --silent --show-error \
        "https://release.files.ghostty.org/libghostty-vt/$vt_version/ghostty-vt-$vt_version.xcframework.zip" \
        -o "$stage/ghostty-vt.zip"
    printf '%s  %s\n' "$vt_checksum" "$stage/ghostty-vt.zip" | shasum -a 256 -c -
    ditto -x -k "$stage/ghostty-vt.zip" "$stage/vt"
    printf '%s\n' "$vt_version:$vt_checksum" > "$stage/vt/ghostty-vt.xcframework/.santty-revision"
    mv "$stage/vt/ghostty-vt.xcframework" "$root/ghostty-vt.xcframework"
fi
if [ "$(head -n 1 "$root/ghostty-vt.xcframework/.santty-revision" 2>/dev/null || true)" != "$vt_version:$vt_checksum" ]; then
    echo "Unexpected Ghostty VT artifact. Move $root/ghostty-vt.xcframework aside and rerun $0." >&2
    exit 1
fi
