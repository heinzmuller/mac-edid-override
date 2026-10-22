#!/bin/bash
set -euo pipefail

# Stage files only. A successful interactive test and explicit --enable follow.
INSTALL_DIR="$HOME/.config/edid-override"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "$EUID" -eq 0 ]; then echo 'Run as your normal user, without sudo.' >&2; exit 1; fi
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    echo 'Usage: ./install.sh /path/to/your-own-monitor-edid.bin' >&2; exit 1
fi
if [ -e "$INSTALL_DIR" ] || [ -L "$INSTALL_DIR" ]; then
    echo 'Existing installation found. Uninstall it first; no files changed.' >&2; exit 1
fi
xcode-select -p >/dev/null
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
clang -fmodules -Wall -Wextra -Werror -framework Foundation -framework CoreGraphics -framework IOKit -framework AppKit \
    -o "$build_dir/edid_override" "$SCRIPT_DIR/edid_override.m"
clang -fmodules -Wall -Wextra -Werror -framework Foundation -framework CoreGraphics \
    -o "$build_dir/edid_check" "$SCRIPT_DIR/edid_check.m"
"$build_dir/edid_override" --self-test
"$build_dir/edid_override" --validate "$1"
umask 077
mkdir -p "$INSTALL_DIR"
cp "$build_dir/edid_override" "$build_dir/edid_check" "$INSTALL_DIR/"
cp "$1" "$INSTALL_DIR/edid.bin"
printf 'Files staged. No display or startup settings changed.\n\nTest interactively:\n  "%s/edid_override" --test "%s/edid.bin"\n\nOnly after a successful test, enable startup:\n  "%s/edid_override" --enable\n' "$INSTALL_DIR" "$INSTALL_DIR" "$INSTALL_DIR"
