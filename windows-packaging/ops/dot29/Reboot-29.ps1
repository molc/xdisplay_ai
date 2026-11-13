$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -ne 'DESKTOP-LLRKFC6'){throw 'Wrong machine'}
if(-not([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Elevation required'}
$share='\\tsclient\results\xdai'
@{at=(Get-Date).ToString('o');bootBefore=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o');reason='XDisplayAI 0.1.4 upgrade reported reboot-pending; rebooting so XDisplayAI-ResumeSetup can continue'}|ConvertTo-Json|Set-Content -Encoding UTF8 (Join-Path $share 'reboot-29-requested.json')
foreach($p in @(Get-Process -Name Xdisplay -ErrorAction SilentlyContinue)){$null=$p.CloseMainWindow();$null=$p.WaitForExit(15000)}
& shutdown.exe /r /t 8 /c "XDisplayAI s63f upgrade: reboot to let XDisplayAI-ResumeSetup continue"
