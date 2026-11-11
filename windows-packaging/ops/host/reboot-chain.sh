#!/bin/bash
# usage: reboot-chain.sh <run>  (e.g. r12): reboot .29 (elevated), reconnect RDP (= interactive logon -> XDisplayAI-ResumeSetup fires), run PostResume-<RUN>-29.ps1 gates
RUN="${1:?run id, e.g. r12}"; RUNU="$(echo "$RUN" | tr a-z A-Z)"
# reboot .29 (elevated), reconnect RDP (= interactive logon -> XDisplayAI-ResumeSetup fires), then run post-resume gates
set -u
cd /tmp/xdisplay29-rdp-results/xdai
rm -f reboot-29-requested.json postresume-${RUN}-state.json postresume-${RUN}-DONE.txt
echo "[$(date -u +%T)] launching elevated reboot"
/tmp/xdai-s63f/launch-elev.sh "xdai\\Reboot-29.ps1" rbt
for i in $(seq 1 24); do timeout 3 bash -c "</dev/tcp/172.19.103.29/3389" 2>/dev/null || { echo "[$(date -u +%T)] 3389 down after $((i*5))s"; break; }; sleep 5; done
cat reboot-29-requested.json 2>/dev/null | head -5
for i in $(seq 1 120); do timeout 3 bash -c "</dev/tcp/172.19.103.29/3389" 2>/dev/null && { echo "[$(date -u +%T)] 3389 back after $((i*5))s"; break; }; sleep 5; done
sleep 25
echo "[$(date -u +%T)] reconnecting RDP (interactive logon)"
/tmp/xdai-s63f/restart-rdp29.sh
sleep 20; DISPLAY=:29 scrot -o /tmp/xdai-s63f/shots/post-logon-20s.png
sleep 40; DISPLAY=:29 scrot -o /tmp/xdai-s63f/shots/post-logon-60s.png
# resume task should be running now; start the post-resume gate script (it waits up to 20 min for health)
echo "[$(date -u +%T)] launching PostResume gates"
/tmp/xdai-s63f/run29.sh "xdai\\PostResume-${RUNU}-29.ps1" 10 postresume-launch
for i in $(seq 1 150); do
  [ -f postresume-${RUN}-DONE.txt ] && { echo "[$(date -u +%T)] DONE: $(cat postresume-${RUN}-DONE.txt)"; break; }
  if [ $((i % 12)) -eq 0 ]; then DISPLAY=:29 scrot -o /tmp/xdai-s63f/shots/resume-wait-$i.png; echo "[$(date -u +%T)] waiting (t+$((i*10))s)"; fi
  sleep 10
done
python3 - <<PY
import json
try:
    d=json.load(open("postresume-${RUN}-state.json",encoding="utf-8-sig"))
except Exception as e:
    print("no postresume state:",e); raise SystemExit
print("outcome:",d.get("outcome")); print("failedGates:",d.get("failedGates")); print("errors:",d.get("errors"))
print("healthSeconds:",d.get("healthSeconds"),"appImageId:",d.get("appImageId"),"wsRev:",d.get("workspaceRev"),"migrationRows:",d.get("migrationRows"))
print("gates:",json.dumps(d.get("gates"),ensure_ascii=False))
print("lastBootstrapBlock:"); [print("  ",l[:260]) for l in d.get("lastBootstrapBlock",[])]
PY
DISPLAY=:29 scrot -o /tmp/xdai-s63f/shots/post-resume-final.png
