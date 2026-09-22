<#
  Fortnite Replay Watcher
  -----------------------
  Runs in the background and auto-uploads every new .replay the moment Fortnite
  finishes writing it. Does a fast BULK catch-up of anything unsent on start.

  Where does it send to?  Set it one of these ways (first match wins):
    1) -Server "http://YOUR-HOST:8090/api/ingest"
    2) a file called  server.txt  next to this script, containing that URL

  Run directly:   powershell -ExecutionPolicy Bypass -File FortniteWatcher.ps1 -Server http://HOST:8090/api/ingest
  Install (auto-start at logon, hidden):  .\Install-Watcher.ps1
#>
param(
  [string]$Demos     = "",
  [string]$Server    = "",
  [string]$IngestKey = "",
  [int]   $IntervalSec = 3
)

$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ---- resolve the server URL ----
$serverCfg = Join-Path $PSScriptRoot "server.txt"
if (-not $Server -and (Test-Path $serverCfg)) { $Server = (Get-Content $serverCfg -Raw).Trim() }
if (-not $Server) {
  Write-Host "No server URL configured." -ForegroundColor Yellow
  Write-Host "  Pass -Server http://YOUR-HOST:8090/api/ingest  or create server.txt next to this script."
  exit 1
}
$Server = $Server.TrimEnd('/')

function Find-Demos {
  param([string]$Override)
  $c = @(
    $Override,
    (Join-Path $env:LOCALAPPDATA 'FortniteGame\Saved\Demos'),
    (Join-Path $env:USERPROFILE 'Documents\Fortnite\FortniteGame\Saved\Demos'),
    (Join-Path $env:USERPROFILE 'OneDrive\Documents\Fortnite\FortniteGame\Saved\Demos'),
    (Join-Path $env:USERPROFILE 'OneDrive\Fortnite\FortniteGame\Saved\Demos'),
    'D:\Documents\Fortnite\FortniteGame\Saved\Demos',
    'D:\Fortnite\FortniteGame\Saved\Demos',
    'D:\Games\Fortnite\FortniteGame\Saved\Demos'
  ) | Where-Object { $_ -and (Test-Path -Path $_) }
  return ($c | Select-Object -First 1)
}

$StateDir  = Join-Path $env:LOCALAPPDATA "FortniteWatcher"
$StateFile = Join-Path $StateDir "sent.txt"
$LogFile   = Join-Path $StateDir "watcher.log"
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
if (-not (Test-Path $StateFile)) { "" | Set-Content $StateFile }

function Log($m) {
  $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m
  try { Add-Content $LogFile $line } catch {}
}

$sent = @{}
Get-Content $StateFile | Where-Object { $_ } | ForEach-Object { $sent[$_] = $true }

$ZipUrl = $Server -replace '/api/ingest$', '/api/ingest-zip'

function Send-One($full, $name) {
  $headers = @{ "X-Replay-Name" = $name }
  if ($IngestKey) { $headers["X-Ingest-Key"] = $IngestKey }
  return Invoke-RestMethod -Uri $Server -Method Post -InFile $full `
           -ContentType "application/octet-stream" -Headers $headers -TimeoutSec 600
}
function Send-Bulk($items) {
  $tmp = Join-Path $StateDir "catchup.zip"
  if (Test-Path $tmp) { Remove-Item $tmp -Force }
  Compress-Archive -Path ($items | ForEach-Object { $_.FullName }) -DestinationPath $tmp -Force
  $headers = @{}
  if ($IngestKey) { $headers["X-Ingest-Key"] = $IngestKey }
  try {
    return Invoke-RestMethod -Uri $ZipUrl -Method Post -InFile $tmp `
             -ContentType "application/zip" -Headers $headers -TimeoutSec 3600
  } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

Log ("Watcher starting (interval=${IntervalSec}s, server=$Server)")

# ---- initial bulk catch-up ----
$demosPath = Find-Demos -Override $Demos
if ($demosPath) {
  Log "Replay folder: $demosPath"
  $pending = Get-ChildItem -Path $demosPath -Filter *.replay -File -ErrorAction SilentlyContinue |
             Where-Object { -not $sent.ContainsKey($_.Name) }
  if ($pending.Count -gt 0) {
    Log ("Catch-up: {0} unsent replay(s) - bulk uploading..." -f $pending.Count)
    try {
      $r = Send-Bulk $pending
      foreach ($p in $pending) { Add-Content $StateFile $p.Name; $sent[$p.Name] = $true }
      Log ("Catch-up done: {0} ingested, {1} failed" -f $r.ingested, $r.failed)
    } catch { Log ("Catch-up bulk FAILED (will retry one-by-one): " + $_.Exception.Message) }
  } else { Log "Catch-up: nothing new." }
} else {
  Log "Replay folder not found yet - will keep looking."
}

# ---- live watch loop ----
$lastSize = @{}
while ($true) {
  if (-not $demosPath -or -not (Test-Path $demosPath)) {
    $demosPath = Find-Demos -Override $Demos
    if (-not $demosPath) { Start-Sleep -Seconds 20; continue }
    Log "Watching: $demosPath"
  }
  $files = Get-ChildItem -Path $demosPath -Filter *.replay -File -ErrorAction SilentlyContinue
  foreach ($f in $files) {
    if ($sent.ContainsKey($f.Name)) { continue }
    $sz = $f.Length
    if ($sz -le 0) { continue }
    if (-not $lastSize.ContainsKey($f.Name) -or $lastSize[$f.Name] -ne $sz) { $lastSize[$f.Name] = $sz; continue }
    try {
      $r = Send-One $f.FullName $f.Name
      Add-Content $StateFile $f.Name
      $sent[$f.Name] = $true
      $lastSize.Remove($f.Name)
      Log ("sent {0} -> {1}" -f $f.Name, $r.record.playlist)
    } catch {
      Log ("FAIL {0}: {1}" -f $f.Name, $_.Exception.Message)
      $lastSize.Remove($f.Name)
    }
  }
  Start-Sleep -Seconds $IntervalSec
}