$env:XDISPLAY_AI_BASE_URL="http://127.0.0.1:18001"; $env:XDISPLAY_AI_USE_MOCK="0"
$exe="C:\ProgramData\XDisplayAI\workspace\client\Xdisplay.exe"
Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe -Parent)
