#!/bin/sh
# Tiny independent client, linked only to the original precompiled VT archive.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
artifact="$repo/Vendor/native-terminal/ghostty-vt.xcframework/macos-arm64_x86_64"
stage=$(mktemp -d /tmp/santty-vt-paste-probe.XXXXXX)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
xcrun clang -std=c11 -Wall -Wextra -Werror -I "$artifact/Headers" \
    "$repo/Scripts/Terminal/probe-vt-paste.c" \
    "$artifact/libghostty-vt.a" -lc++ -framework Foundation -o "$stage/probe"
"$stage/probe"
