#!/bin/sh
# Only builds a tiny owned client against the original precompiled archive.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
artifact="$repo/Vendor/native-terminal/ghostty-vt.xcframework/macos-arm64_x86_64"
stage=$(mktemp -d /tmp/santty-vt-settings-probe.XXXXXX)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
xcrun clang -std=c11 -Wall -Wextra -Werror -I "$artifact/Headers" \
    "$repo/Scripts/Terminal/probe-vt-settings.c" \
    "$artifact/libghostty-vt.a" -lc++ -framework Foundation -o "$stage/probe"
"$stage/probe"
