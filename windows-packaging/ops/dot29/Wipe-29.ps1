$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if($env:COMPUTERNAME -ne 'DESKTOP-LLRKFC6'){throw 'Wrong machine: ONLY .29'}
if([Security.Principal.WindowsIdentity]::GetCurrent().Name -eq 'NT AUTHORITY\SYSTEM' -or (Get-Process -Id $PID).SessionId -eq 0){throw 'Need interactive elevated admin'}
if(-not([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Elevation required'}
$share='\\tsclient\results\xdai'; $logs='C:\Users\Public\XDisplayAI-s63f-wipe'
[void][IO.Directory]::CreateDirectory($share); [void][IO.Directory]::CreateDirectory($logs)
$r=[ordered]@{purpose='DOT29_SCENARIO1_FULL_WIPE_OF_XDISPLAY_AI';machine=$env:COMPUTERNAME;started=(Get-Date).ToString('o');outcome='NOT_RUN';steps=@();errors=@();freedBytes=0}
function Save([string]$o){$r.outcome=$o;$r.updated=(Get-Date).ToString('o');$j=$r|ConvertTo-Json -Depth 10;$j|Set-Content -Encoding UTF8 (Join-Path $logs 'state.json');$j|Set-Content -Encoding UTF8 (Join-Path $share 'wipe-state.json')}
function Regs{@(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue|Where-Object DisplayName -eq 'XDisplay AI Offline Installer'|Select-Object DisplayName,DisplayVersion,PSChildName,BundleCachePath)}
function Docker([string]$arguments,[int]$seconds=120){$d='C:\Program Files\Docker\Docker\resources\bin\docker.exe';$h='--host npipe:////./pipe/dockerDesktopLinuxEngine ';$p=New-Object Diagnostics.Process;$p.StartInfo.FileName=$d;$p.StartInfo.Arguments=($h+$arguments);$p.StartInfo.UseShellExecute=$false;$p.StartInfo.CreateNoWindow=$true;$p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true;[void]$p.Start();$o=$p.StandardOutput.ReadToEndAsync();$e=$p.StandardError.ReadToEndAsync();if(-not$p.WaitForExit($seconds*1000)){$p.Kill();throw ('docker timeout: '+$arguments)};$p.WaitForExit();return @{exit=[int]$p.ExitCode;stdout=$o.Result;stderr=$e.Result}}
function DirBytes([string]$p){if(Test-Path -LiteralPath $p){(Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue|Measure-Object Length -Sum).Sum}else{0}}
function RemoveTree([string]$p,[string]$why){if(Test-Path -LiteralPath $p){$b=DirBytes $p;Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop;$r.steps+=@{removed=$p;bytes=$b;why=$why};$r.freedBytes+=[long]$b;Save 'WIPING'}}
try{
 foreach($p in @(Get-Process -Name Xdisplay,Converter -ErrorAction SilentlyContinue)){$null=$p.CloseMainWindow();if(-not $p.WaitForExit(20000)){throw 'Client still open; no force kill'}}
 $r.regsBefore=Regs; $r.bootBefore=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o'); Save 'PRECHECKS_OK'
 # 1) product's own data-removing uninstall path (compose down --volumes, tasks, state, ProgramData) while scripts still exist
 $rm='C:\Program Files\XDisplayAI\scripts\uninstall\Remove-XDisplayAI.ps1'
 if(Test-Path $rm){ $prevEap=$ErrorActionPreference; $ErrorActionPreference='Continue'; try { $out=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $rm -RemoveVolumes -RemoveDataDirectory 2>&1 | ForEach-Object { [string]$_ } | Out-String } finally { $ErrorActionPreference=$prevEap }; $r.steps+=@{removeScriptExit=$LASTEXITCODE;tail=($out -split '\r?\n'|Select-Object -Last 12)} }
 Save 'PRODUCT_UNINSTALL_SCRIPT_DONE'
 # 2) Burn uninstall of whatever XDisplay AI bundle is registered
 foreach($b in @($r.regsBefore|Where-Object BundleCachePath)){ if(Test-Path -LiteralPath $b.BundleCachePath){ $p=Start-Process -FilePath $b.BundleCachePath -ArgumentList @('/uninstall','/quiet','/norestart','/log',(Join-Path $logs ('wipe-uninstall-'+$b.DisplayVersion+'-burn.log'))) -PassThru -Wait; $r.steps+=@{burnUninstall=$b.BundleCachePath;exit=$p.ExitCode} } }
 # any MSI-only leftovers
 foreach($m in @(Regs|Where-Object{-not $_.BundleCachePath})){ $p=Start-Process msiexec.exe -ArgumentList @('/x',$m.PSChildName,'/qn','/norestart') -PassThru -Wait; $r.steps+=@{msiUninstall=$m.PSChildName;exit=$p.ExitCode} }
 $r.regsAfterUninstall=Regs; Save 'BURN_UNINSTALL_DONE'
 # 3) docker: project containers / volumes / images (backend = all information)
 $ids=@((Docker 'ps -aq --filter label=com.docker.compose.project=xdisplayai').stdout -split '\s+'|Where-Object{$_}); if($ids.Count){ $null=Docker ('rm -f '+($ids -join ' ')) }
 $vols=@((Docker 'volume ls -q --filter label=com.docker.compose.project=xdisplayai').stdout -split '\s+'|Where-Object{$_}); if($vols.Count){ $null=Docker ('volume rm -f '+($vols -join ' ')) }
 foreach($v in 'xdisplayai_app_data','xdisplayai_app_logs','xdisplayai_postgres_data','xdisplayai_redis_data'){ $null=Docker ('volume rm -f '+$v) 30 }
 $null=Docker 'network rm xdisplayai_default' 30
 $imgs=@((Docker 'images --format "{{.Repository}}:{{.Tag}}|{{.ID}}"').stdout -split '\r?\n'|Where-Object{$_ -match '^(orches/|pgvector/pgvector:pg15|redis:7)'})
 $r.imagesRemoved=@(); foreach($line in $imgs){ $ref=($line -split '\|')[0]; $x=Docker ('rmi -f '+$ref) 180; $r.imagesRemoved+=@{ref=$ref;exit=$x.exit} }
 $null=Docker 'image prune -f' 180
 $r.dockerAfter=@{containers=(Docker 'ps -a --format "{{.Names}}"').stdout.Trim();volumes=(Docker 'volume ls -q').stdout.Trim();images=(Docker 'images --format "{{.Repository}}:{{.Tag}}"').stdout.Trim()}
 Save 'DOCKER_CLEANED'
 # 4) filesystem / tasks / registry / per-user client state
 foreach($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object{$_.TaskName -match 'XDisplay'})){Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false; $r.steps+=@{taskRemoved=$t.TaskName}}
 RemoveTree 'C:\Program Files\XDisplayAI' 'product files leftover'
 RemoveTree 'C:\ProgramData\XDisplayAI' 'product data/workspace/config/logs'
 foreach($root in @($env:APPDATA,$env:LOCALAPPDATA,'C:\Users\Public\Documents')){ foreach($d in @(Get-ChildItem $root -Directory -ErrorAction SilentlyContinue|Where-Object{$_.Name -match 'xdisplay|chunxin|淳信|XD_AI|XDAI'})){ RemoveTree $d.FullName 'per-user client state' } }
 foreach($k in @(Get-ChildItem 'HKCU:\Software','HKLM:\SOFTWARE','HKLM:\SOFTWARE\WOW6432Node' -ErrorAction SilentlyContinue|Where-Object{$_.PSChildName -match 'xdisplay|chunxin|淳信'})){ $r.steps+=@{regKeyRemoved=$k.Name}; Remove-Item -Path $k.PSPath -Recurse -Force }
 foreach($lnk in @(Get-ChildItem "$env:PUBLIC\Desktop","$env:USERPROFILE\Desktop","$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Recurse -Include 'XDisplay*.lnk' -ErrorAction SilentlyContinue)){ Remove-Item -LiteralPath $lnk.FullName -Force; $r.steps+=@{shortcutRemoved=$lnk.FullName} }
 Save 'PRODUCT_TRACES_REMOVED'
 # 5) stale deployment leftovers from earlier sessions (user-authorized cleanup). Keep C:\Temp\XdisplayAI_20261108_full (delivered 0.1.3) and the r5 candidate.
 foreach($p in @('C:\Temp\XDisplayAI-0.1.4-189-r4','C:\Temp\XdisplayAI_20261108','C:\Temp\xdpkg','C:\Users\Public\xdisplay-group0-msi','C:\Users\Public\xdisplay-oem-244','C:\Users\Public\xdisplay-pkg','C:\Users\Public\xdisplay-pkg-fix','C:\Users\Public\xdisplay-pkg-kbd','C:\Users\Public\xdisplay-runtime-20261106','C:\Users\Public\XDisplayAI-t222-acceptance','C:\Users\Public\XDisplayAI-t222-readonly','C:\Users\Public\XDisplayAI-t227-installed-case','C:\Users\Public\XDisplayAI-t227-readonly')){ RemoveTree $p 'stale deployment leftover' }
 foreach($d in @(Get-ChildItem 'C:\Users\Public' -Directory -ErrorAction SilentlyContinue|Where-Object{$_.Name -match '^XDisplayAI-reinstall-t201'})){ RemoveTree $d.FullName 'stale deployment leftover' }
 Get-ChildItem 'C:\Temp','C:\Users\Public' -Directory -ErrorAction SilentlyContinue|Where-Object{$_.Name -match 'XDisplay|Xdisplay|xdp'}|ForEach-Object{ $r.steps+=@{kept=$_.FullName;bytes=(DirBytes $_.FullName)} }
 Save 'STALE_LEFTOVERS_REMOVED'
 # 6) verify clean
 $v=[ordered]@{}
 $v.registrations=@(Regs).Count
 $v.programFiles=Test-Path 'C:\Program Files\XDisplayAI'; $v.programData=Test-Path 'C:\ProgramData\XDisplayAI'
 $v.containers=((Docker 'ps -a --filter label=com.docker.compose.project=xdisplayai -q').stdout.Trim()); $v.volumes=((Docker 'volume ls -q --filter name=xdisplayai').stdout.Trim()); $v.orchesImages=((Docker 'images --format "{{.Repository}}:{{.Tag}}" --filter reference=orches/*').stdout.Trim())
 $v.tasks=@(Get-ScheduledTask -ErrorAction SilentlyContinue|Where-Object{$_.TaskName -match 'XDisplay'}).Count
 $v.listener18001=@(Get-NetTCPConnection -LocalPort 18001 -State Listen -ErrorAction SilentlyContinue).Count
 $v.clientProcs=@(Get-Process Xdisplay,Converter -ErrorAction SilentlyContinue).Count
 $v.packageCache=@(Get-ChildItem 'C:\ProgramData\Package Cache' -Directory -ErrorAction SilentlyContinue|Where-Object{Test-Path (Join-Path $_.FullName 'XDisplayAI-*')}).Count
 $v.dockerDesktopStillInstalled=Test-Path 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
 $v.cFreeGB=[math]::Round((Get-Volume -DriveLetter C).SizeRemaining/1GB,1)
 $r.verify=$v
 $clean=($v.registrations -eq 0 -and -not $v.programFiles -and -not $v.programData -and -not $v.containers -and -not $v.volumes -and -not $v.orchesImages -and $v.tasks -eq 0 -and $v.listener18001 -eq 0 -and $v.clientProcs -eq 0)
 $r.bootAfter=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')
 $r.completed=(Get-Date).ToString('o')
 if($clean){Save 'WIPE_CLEAN'}else{Save 'WIPE_INCOMPLETE'}
}catch{$r.errors+=$_.Exception.Message;Save 'STOPPED_FAIL';$_|Out-String|Set-Content -Encoding UTF8 (Join-Path $share 'wipe-ERROR.txt')}
finally{ foreach($f in Get-ChildItem $logs -File -ErrorAction SilentlyContinue){Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $share ('wipe-'+$f.Name)) -Force}; 'DONE '+$r.outcome|Set-Content -Encoding ASCII (Join-Path $share 'wipe-DONE.txt') }
