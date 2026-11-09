#!/bin/sh
# Reproducible Swift-only patch; libghostty remains the upstream binary target.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# libghostty-spm 2.2.2026102101; prebuilt Ghostty core 1e9e14af5df1.
revision=5b9cb63d83e687b4a66d6c3a3c2a840341c576d9
checksum=257d234648b8951f94f20627d73e1fb374af4282604eea841d1c06d33bb5ae96
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
if ! grep -q 'enum TerminalDisplayLinkKeeper' "$package_dir/Sources/GhosttyTerminal/Surface/TerminalSurfaceCoordinator.swift"; then
    patch -s -d "$package_dir" -p1 < "$repo_dir/Patches/TerminalSurfaceCoordinator+DisplayLinkKeeper.patch"
fi
if ! grep -q 'core.setWindowVisible(window?.occlusionState' "$package_dir/Sources/GhosttyTerminal/Platform/AppKit/AppTerminalView+Lifecycle.swift"; then
    patch -s -d "$package_dir" -p1 < "$repo_dir/Patches/AppTerminalView+Occlusion.patch"
fi
