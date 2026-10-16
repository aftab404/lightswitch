#!/bin/bash
# Records a short demo of Lightswitch using sample windows, tabs and apps (nothing real), then writes
# media/lightswitch-demo.mp4 and media/lightswitch-demo.gif.
#   demo/record.sh          the video
#   demo/record.sh stills   still frames of the panel instead, which demo/gallery.swift lays out as the Product Hunt
#                           images in media/producthunt and the site's share image, assets/og.png
# Needs Screen Recording permission for the app running this script (System Settings → Privacy & Security).
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh demo
OUT="$PWD/build/demo"
LOG="$OUT/demo.log"
mkdir -p "$OUT" media
rm -f "$LOG"

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
field() { awk -v key="$1" '$1 == key { print $2 }' "$LOG"; }

if [[ "${1:-}" == "stills" ]]; then
    STILLS="$OUT/stills"
    rm -rf "$STILLS"
    mkdir -p "$STILLS"
    open -n --stdout "$LOG" build/Lightswitch-demo.app --args --stills "$STILLS"
    # The demo poses each still, prints "STILL <name> <rect>" and waits for its PNG before moving on.
    captured=0
    until grep -q '^DONE ' "$LOG" 2>/dev/null; do
        line=$(grep '^STILL ' "$LOG" 2>/dev/null | sed -n "$((captured + 1))p" || true)
        if [[ -z "$line" ]]; then
            sleep 0.1
            continue
        fi
        read -r _ name rect <<< "$line"
        screencapture -x -R"$rect" "$STILLS/$name-capturing.png"
        mv "$STILLS/$name-capturing.png" "$STILLS/$name.png"
        captured=$((captured + 1))
    done
    swift demo/gallery.swift "$STILLS"
    exit
fi

rm -f "$OUT/raw.mov"
open -n --stdout "$LOG" build/Lightswitch-demo.app
until grep -q '^RECT ' "$LOG" 2>/dev/null; do sleep 0.1; done

# The demo waits 3 s before it starts and finishes about 18 s later.
START=$(now)
screencapture -v -x -V 25 -R"$(field RECT)" "$OUT/raw.mov"
until grep -q '^DONE ' "$LOG"; do sleep 0.2; done

TRIM=$(awk -v show="$(field SHOW)" -v start="$START" 'BEGIN { t = show - start - 0.3; printf "%.2f", (t < 0 ? 0 : t) }')
LENGTH=$(awk -v show="$(field SHOW)" -v done="$(field DONE)" 'BEGIN { printf "%.2f", done - show + 0.5 }')
swift demo/convert.swift "$OUT/raw.mov" "$TRIM" "$LENGTH" media/lightswitch-demo
