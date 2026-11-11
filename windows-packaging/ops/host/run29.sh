#!/bin/bash
# usage: run29.sh <script-name-on-share> [wait-seconds] [shot-name]
set -u
NAME="$1"; WAIT="${2:-25}"; SHOT="${3:-after-run}"
export DISPLAY=:29
WID=$(xdotool search --name "172.19.103.29" | head -1)
[ -n "$WID" ] || { echo "NO_RDP_WINDOW"; exit 2; }
xdotool windowactivate --sync "$WID" 2>/dev/null; xdotool windowfocus --sync "$WID" 2>/dev/null; sleep 0.3
xdotool mousemove 1200 875; xdotool click 1; sleep 0.4  # taskbar-focus: keep an elevated window from being foreground
xdotool key --clearmodifiers super+r; sleep 1.5
xdotool key --clearmodifiers ctrl+a; sleep 0.2
xdotool type --delay 12 --clearmodifiers "powershell -NoProfile -ExecutionPolicy Bypass -File \\\\tsclient\\results\\$NAME"
sleep 0.4
mkdir -p /tmp/xdai-s63f/shots
scrot -o /tmp/xdai-s63f/shots/${SHOT}-run-dialog.png
xdotool key --clearmodifiers Return
sleep "$WAIT"
scrot -o /tmp/xdai-s63f/shots/${SHOT}.png
echo "LAUNCHED $NAME; waited $WAIT"
