#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
DIST_DIR="$SCRIPT_DIR/dist"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# public/ is the complete publication boundary; new files need no build changes.
cp -R "$SCRIPT_DIR/public/." "$DIST_DIR/"
