#!/bin/sh
# Reproducible Swift-only patch; libghostty remains the upstream binary target.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# libghostty-spm 2.2.2026110702; prebuilt Ghostty core 042b16b6146a.
revision=1d84cf66fe29abd1f24f10b88dcfc25882cf68ee
checksum=6f8445f25c56a6868c1a21d65f356aceabf3bdb1970d70cd7933a21253456409
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
if ! grep -q 'Santty retains detached panes' "$package_dir/Sources/GhosttyTerminal/Surface/TerminalSurfaceCoordinator.swift"; then
    patch -s -d "$package_dir" -p1 < "$repo_dir/Patches/TerminalSurfaceCoordinator+DetachedWakeups.patch"
fi
if ! grep -q 'retiringSurface' "$package_dir/Sources/GhosttyTerminal/Surface/TerminalSurfaceCoordinator.swift"; then
    patch -s -d "$package_dir" -p1 < "$repo_dir/Patches/TerminalSurfaceCoordinator+DrainBeforeFree.patch"
fi
if ! grep -q 'idleFramesBeforeRelease = 240' "$package_dir/Sources/GhosttyTerminal/Surface/TerminalSurfaceCoordinator.swift"; then
    patch -s -d "$package_dir" -p1 < "$repo_dir/Patches/TerminalSurfaceCoordinator+DisplayLinkLinger.patch"
fi
if ! grep -q 'wakeGraceInterval' "$package_dir/Sources/GhosttyTerminal/Controller/TerminalController.swift"; then
    patch -s -d "$package_dir" -p1 < "$repo_dir/Patches/TerminalWakeGrace.patch"
fi
if ! grep -q 'core.setWindowVisible(window?.occlusionState' "$package_dir/Sources/GhosttyTerminal/Platform/AppKit/AppTerminalView+Lifecycle.swift"; then
    patch -s -d "$package_dir" -p1 < "$repo_dir/Patches/AppTerminalView+Occlusion.patch"
fi
