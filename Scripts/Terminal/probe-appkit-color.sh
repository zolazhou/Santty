#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
stage=$(mktemp -d /tmp/santty-appkit-color-probe.XXXXXX)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
xcrun swiftc -swift-version 6 "$here/probe-appkit-color.swift" -o "$stage/probe"
"$stage/probe"
