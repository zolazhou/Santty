#!/bin/sh
# Builds only an owned diagnostic client, never the precompiled terminal core.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
artifact="$repo/Vendor/native-terminal/ghostty-vt.xcframework/macos-arm64_x86_64"
stage=$(mktemp -d /tmp/santty-vt-image-probe.XXXXXX)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
xcrun clang -std=c11 -I "$artifact/Headers" \
    "$repo/Experiments/NativeTerminalLab/Tools/probe-vt-image-api.c" \
    "$artifact/libghostty-vt.a" -lc++ -framework Foundation -o "$stage/probe"
"$stage/probe"
