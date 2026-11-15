#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/santty-pty-api.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
xcrun clang -Wall -Wextra -Werror "$here/probe-local-pty-api.c" -o "$work/probe"
"$work/probe"
