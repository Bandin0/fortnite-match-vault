<#
  Install-Watcher
  ---------------
  One-time setup: makes the replay watcher run automatically (hidden) at every
  logon. No admin needed — it uses your Startup folder.

  Run from the folder that also contains FortniteWatcher.ps1:
    powershell -ExecutionPolicy Bypass -File Install-Watcher.ps1 -Server http://YOUR-HOST:8090/api/ingest
  (If you omit -Server you'll be prompted for it.)
  Optional: -IngestKey "abc"  if your server requires a key.

  Uninstall:  delete  FortniteReplayWatcher.vbs  from your Startup folder
              (Win+R -> shell:startup), or just reboot after removing it.
#>
param(
  [string]$Server    = "",
  [string]$IngestKey = ""
)

$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

if (-not $Server) { $Server = (Read-Host "Server URL (e.g. http://YOUR-HOST:8090/api/ingest)").Trim() }
if (-not $Server) { Write-Host "No server URL given. Aborting." -ForegroundColor Red; exit 1 }
$Server = $Server.TrimEnd('/')

$src = Join-Path $PSScriptRoot "FortniteWatcher.ps1"
if (-not (Test-Path $src)) { Write-Host "FortniteWatcher.ps1 not found next to this installer." -ForegroundColor Red; exit 1 }

$dir = Join-Path $env:LOCALAPPDATA "FortniteWatcher"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$ps1 = Join-Path $dir "FortniteWatcher.ps1"
Copy-Item $src $ps1 -Force
"$Server" | Set-Content (Join-Path $dir "server.txt") -Encoding ASCII

$vbs    = Join-Path $dir "run-hidden.vbs"
$keyArg = ''
if ($IngestKey) { $keyArg = ' -IngestKey ""' + $IngestKey + '""' }
$vbsLine = 's.Run "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""' +
           $ps1 + '"" -Server ""' + $Server + '""' + $keyArg + '", 0, False'
Set-Content -Path $vbs -Encoding ASCII -Value @('Set s = CreateObject("WScript.Shell")', $vbsLine)

$startup = [Environment]::GetFolderPath('Startup')
$launch  = Join-Path $startup "FortniteReplayWatcher.vbs"
Copy-Item $vbs $launch -Force

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like "*FortniteWatcher.ps1*" } |
  ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch {} }
Start-Process "wscript.exe" -ArgumentList "`"$launch`""

Write-Host ""
Write-Host "Installed and running." -ForegroundColor Green
Write-Host "  Server : $Server"
Write-Host "  Startup: $launch"
Write-Host "  Log    : $dir\watcher.log"