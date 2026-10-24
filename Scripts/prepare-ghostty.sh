#!/bin/sh
# Reproducible Swift-only patch; libghostty remains the upstream binary target.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
revision=b0930320739324886590e865d571eb5dd7073912
checksum=42ac24083cea7ea0f303feac738defb8347647dddd3273ec957e5dc852fd94b8
package_dir="$repo_dir/Vendor/libghostty-spm"
mkdir -p "$repo_dir/Vendor"
if [ ! -d "$package_dir" ]; then
    stage_dir=$(mktemp -d "$repo_dir/Vendor/.ghostty.XXXXXX")
    trap 'rm -rf "$stage_dir"' EXIT HUP INT TERM
    curl --fail --location --silent --show-error \
        "https://codeload.github.com/Lakr233/libghostty-spm/tar.gz/$revision" \
        -o "$stage_dir/source.tar.gz"
    printf '%s  %s\n' "$checksum" "$stage_dir/source.tar.gz" | shasum -a 256 -c -
    mkdir "$stage_dir/package"
    tar -xzf "$stage_dir/source.tar.gz" --strip-components=1 -C "$stage_dir/package"
    printf '%s\n' "$revision" > "$stage_dir/package/.santty-revision"
    mv "$stage_dir/package" "$package_dir"
fi
if [ "$(cat "$package_dir/.santty-revision" 2>/dev/null || true)" != "$revision" ]; then
    echo "Unexpected Vendor/libghostty-spm checkout. Move it aside and rerun $0." >&2
    exit 1
fi
cp "$repo_dir/Patches/TerminalSurface+ReadText.swift" \
   "$package_dir/Sources/GhosttyTerminal/Surface/TerminalSurface+ReadText.swift"
cp "$repo_dir/Patches/TerminalSurface+ScrollMode.swift" \
   "$package_dir/Sources/GhosttyTerminal/Surface/TerminalSurface+ScrollMode.swift"
if ! grep -q 'var scrollModeViewport:' "$package_dir/Sources/GhosttyTerminal/InMemory/TerminalCallbackBridge.swift"; then
    patch -s -d "$package_dir" -p1 < "$repo_dir/Patches/TerminalCallbackBridge+ScrollMode.patch"
fi
