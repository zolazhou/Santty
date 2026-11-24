#!/bin/sh
# Builds only an owned diagnostic client of the original precompiled archive.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
artifact="$repo/Vendor/native-terminal/ghostty-vt.xcframework/macos-arm64_x86_64"
stage=$(mktemp -d /tmp/santty-vt-read-probe.XXXXXX)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
xcrun clang -std=c11 -Wall -Wextra -Werror -I "$artifact/Headers" \
    "$repo/Scripts/Terminal/probe-vt-read.c" \
    "$artifact/libghostty-vt.a" -lc++ -framework Foundation -o "$stage/probe"
"$stage/probe"
