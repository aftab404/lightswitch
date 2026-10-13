#!/bin/bash
# Records a short demo of Lightswitch using sample windows (no real window titles), then writes
# media/lightswitch-demo.mp4 and media/lightswitch-demo.gif.
# Needs Screen Recording permission for the app running this script (System Settings → Privacy & Security).
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh demo
OUT="$PWD/build/demo"
LOG="$OUT/demo.log"
mkdir -p "$OUT" media
rm -f "$LOG" "$OUT/raw.mov"

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
field() { awk -v key="$1" '$1 == key { print $2 }' "$LOG"; }

open -n --stdout "$LOG" build/Lightswitch-demo.app
until grep -q '^RECT ' "$LOG" 2>/dev/null; do sleep 0.1; done

# The demo waits 3 s before opening the panel and finishes about 11 s later.
START=$(now)
screencapture -v -x -V 16 -R"$(field RECT)" "$OUT/raw.mov"
until grep -q '^DONE ' "$LOG"; do sleep 0.2; done

TRIM=$(awk -v show="$(field SHOW)" -v start="$START" 'BEGIN { t = show - start - 0.8; printf "%.2f", (t < 0 ? 0 : t) }')
LENGTH=$(awk -v show="$(field SHOW)" -v done="$(field DONE)" 'BEGIN { printf "%.2f", done - show + 1.6 }')
swift demo/convert.swift "$OUT/raw.mov" "$TRIM" "$LENGTH" media/lightswitch-demo
