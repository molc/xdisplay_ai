#!/bin/bash
# usage: launch-elev.sh <script-rel-path-under-share> <shotname>   (launches elevated via Start-Process -Verb RunAs, then clicks UAC Yes)
set -u
REL="$1"; SHOT="${2:-elev}"
export DISPLAY=:29
WID=$(xdotool search --name "172.19.103.29" | head -1); [ -n "$WID" ] || { echo NO_RDP_WINDOW; exit 2; }
xdotool windowactivate --sync "$WID" 2>/dev/null; xdotool windowfocus --sync "$WID" 2>/dev/null; sleep 0.3
xdotool mousemove 1200 875; xdotool click 1; sleep 0.4  # taskbar-focus: keep an elevated window from being foreground
xdotool key --clearmodifiers super+r; sleep 1.5; xdotool key --clearmodifiers ctrl+a; sleep 0.2
xdotool type --delay 10 --clearmodifiers "powershell -NoProfile -ExecutionPolicy Bypass -Command \"Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \\\\tsclient\\results\\$REL'\""
sleep 0.4; mkdir -p /tmp/xdai-s63f/shots; scrot -o /tmp/xdai-s63f/shots/${SHOT}-cmd.png
xdotool key --clearmodifiers Return; sleep 4
scrot -o /tmp/xdai-s63f/shots/${SHOT}-uac.png
# UAC "是" button (1600x900 secure desktop) measured at (698,583)
xdotool mousemove 698 583; sleep 0.2; xdotool click 1; sleep 3
scrot -o /tmp/xdai-s63f/shots/${SHOT}-after-yes.png
echo "LAUNCHED_ELEV $REL"
