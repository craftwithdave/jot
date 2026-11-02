#!/bin/bash
# Publishes the Mac app source to <server>/mac/ (install.sh builds it on the Mac).
# Usage: ./publish.sh [version]   (default: bump the minor number in version.txt)
# The server address comes from JOT_ORIGIN or origin.txt (e.g. https://notes.example.com) and is written into install.sh.
set -euo pipefail
cd "$(dirname "$0")"
V=${1:-$(awk -F. '{printf "%d.%d", $1, $2+1}' version.txt)}
echo "$V" > version.txt
OUT=../server/public/mac
mkdir -p "$OUT"
ORIGIN=${JOT_ORIGIN:-$(cat origin.txt 2>/dev/null || true)}
[ -n "$ORIGIN" ] || { echo "set JOT_ORIGIN or put the server address in origin.txt"; exit 1; }
cp Sources/*.swift version.txt "$OUT/"
sed "s|__JOT_ORIGIN__|$ORIGIN|" install.sh > "$OUT/install.sh"
cp Resources/highlight.min.js Resources/jothl.js Resources/highlight.LICENSE Resources/AppIcon.icns "$OUT/"
echo "published Jot for Mac $V"
