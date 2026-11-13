$o=[ordered]@{at=(Get-Date).ToString("o")}
$t=Get-ScheduledTask -TaskName "XDisplayAI-ResumeSetup" -ErrorAction SilentlyContinue
$o.resumeTask=if($t){[string]$t.State}else{"absent"}
$o.bootstrapState=(Test-Path "C:\ProgramData\XDisplayAI\config\bootstrap-state.json")
$o.last=((Get-Content "C:\ProgramData\XDisplayAI\logs\bootstrap.log" -Tail 3 -Encoding UTF8) -join " | ")
$o.xdisplay=@(Get-Process Xdisplay -ErrorAction SilentlyContinue).Count
$o|ConvertTo-Json -Depth 2|Set-Content -Encoding UTF8 "\\tsclient\results\xdai\resume-probe.json"
