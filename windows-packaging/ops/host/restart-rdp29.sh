#!/bin/bash
# reconnect the .29 RDP session on DISPLAY :29 (1600x900) after a reboot; keeps Xvfb :29
set -u
PASSFILE=/tmp/rdp29-now.pass; [ -s "$PASSFILE" ] || { echo missing_pass; exit 2; }
PW=$(tr -d '\r\n' < "$PASSFILE")
for p in $(pgrep -f "xfreerdp /v:172.19.103.29"); do kill "$p" 2>/dev/null || true; done; sleep 2
pgrep -f "Xvfb :29" >/dev/null || { Xvfb :29 -screen 0 1600x900x24 >/tmp/xvfb29.log 2>&1 & sleep 1; }
export DISPLAY=:29
LOG=/tmp/xdai-s63f/rdp29-session.log
nohup xfreerdp /v:172.19.103.29 /u:admin "/p:$PW" /cert:ignore /size:1600x900 /network:auto +clipboard /drive:results,/tmp/xdisplay29-rdp-results /log-level:ERROR > "$LOG" 2>&1 < /dev/null &
echo $! > /tmp/xdai-s63f/rdp29.pid
sleep 18
python3 - "$LOG" "$PW" <<'PY'
import sys
log,pw=sys.argv[1],sys.argv[2]
t=open(log,errors="replace").read().replace(pw,"***"); open(log,"w").write(t)
print("log_tail:", "\n".join(t.splitlines()[-4:]))
PY
pgrep -af "xfreerdp /v:172.19.103.29" | sed 's#/p:[^ ]*#/p:***#' | head -1
mkdir -p /tmp/xdai-s63f/shots; scrot -o /tmp/xdai-s63f/shots/rdp29-reconnected.png && echo reconnected_shot
