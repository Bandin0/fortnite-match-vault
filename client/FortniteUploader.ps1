<#
  Fortnite Replay Uploader (one-shot)
  -----------------------------------
  Finds your Fortnite replay folder and pushes NEW .replay files to your server.
  Bulk by default: zips all new replays and sends them in ONE request.

  Server URL: pass -Server, or put it in  server.txt  next to this script.

  Run:      powershell -ExecutionPolicy Bypass -File FortniteUploader.ps1 -Server http://YOUR-HOST:8090/api/ingest
  Reset:    ... -Reset            (forget what's been sent, re-send everything)
  Override: ... -Demos "D:\path\to\Demos"
  One-by-one: ... -OneByOne
#>
param(
  [string]$Demos     = "",
  [string]$Server    = "",
  [string]$IngestKey = "",
  [switch]$Reset,
  [switch]$OneByOne
)

$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$serverCfg = Join-Path $PSScriptRoot "server.txt"
if (-not $Server -and (Test-Path $serverCfg)) { $Server = (Get-Content $serverCfg -Raw).Trim() }
if (-not $Server) { Write-Host "No server URL. Pass -Server or create server.txt next to this script." -ForegroundColor Red; exit 1 }
$Server = $Server.TrimEnd('/')

$candidates = @(
  $Demos,
  (Join-Path $env:LOCALAPPDATA 'FortniteGame\Saved\Demos'),
  (Join-Path $env:USERPROFILE 'Documents\Fortnite\FortniteGame\Saved\Demos'),
  (Join-Path $env:USERPROFILE 'OneDrive\Documents\Fortnite\FortniteGame\Saved\Demos'),
  (Join-Path $env:USERPROFILE 'OneDrive\Fortnite\FortniteGame\Saved\Demos'),
  'D:\Documents\Fortnite\FortniteGame\Saved\Demos',
  'D:\Fortnite\FortniteGame\Saved\Demos',
  'D:\Games\Fortnite\FortniteGame\Saved\Demos'
) | Where-Object { $_ -and (Test-Path -Path $_) }
$Demos = $candidates | Select-Object -First 1
if (-not $Demos) { Write-Host "Could not find the Fortnite Demos folder. Re-run with -Demos `"<path>`"." -ForegroundColor Red; exit 1 }
Write-Host "Replay folder: $Demos"

$StateDir  = Join-Path $env:LOCALAPPDATA "FortniteWatcher"
$StateFile = Join-Path $StateDir "sent.txt"
$LogFile   = Join-Path $StateDir "uploader.log"
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
if ($Reset -and (Test-Path $StateFile)) { Remove-Item $StateFile -Force; Write-Host "state reset" }
if (-not (Test-Path $StateFile)) { "" | Set-Content $StateFile }

function Log($msg) {
  $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
  Add-Content $LogFile $line; Write-Host $line
}

$sent = @{}
Get-Content $StateFile | Where-Object { $_ } | ForEach-Object { $sent[$_] = $true }
$files = Get-ChildItem -Path $Demos -Filter *.replay -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime
$new = $files | Where-Object { -not $sent.ContainsKey($_.Name) }
Log ("Found {0} replay(s); {1} already sent; {2} NEW" -f $files.Count, $sent.Count, $new.Count)
if ($new.Count -eq 0) { Log "Nothing new to upload."; exit 0 }

if (-not $OneByOne) {
  $zip = Join-Path $StateDir "bulk.zip"
  if (Test-Path $zip) { Remove-Item $zip -Force }
  Log ("Zipping {0} replay(s)..." -f $new.Count)
  Compress-Archive -Path $new.FullName -DestinationPath $zip -Force
  Log ("Zip is {0} MB - uploading in one request..." -f [math]::Round((Get-Item $zip).Length / 1MB, 1))
  try {
    $headers = @{}
    if ($IngestKey) { $headers["X-Ingest-Key"] = $IngestKey }
    $zipUrl = $Server -replace '/api/ingest$', '/api/ingest-zip'
    $resp = Invoke-RestMethod -Uri $zipUrl -Method Post -InFile $zip -ContentType "application/zip" -Headers $headers -TimeoutSec 1800
    foreach ($f in $new) { Add-Content $StateFile $f.Name }
    Log ("Bulk done: {0} ingested, {1} failed" -f $resp.ingested, $resp.failed)
  } catch { Log ("Bulk FAILED: " + $_.Exception.Message) }
  finally { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
  exit 0
}

$newCount = 0
foreach ($f in $new) {
  try {
    $headers = @{ "X-Replay-Name" = $f.Name }
    if ($IngestKey) { $headers["X-Ingest-Key"] = $IngestKey }
    $resp = Invoke-RestMethod -Uri $Server -Method Post -InFile $f.FullName -ContentType "application/octet-stream" -Headers $headers -TimeoutSec 300
    Add-Content $StateFile $f.Name; $newCount++
    Log ("  sent {0} -> {1} (place {2})" -f $f.Name, $resp.record.playlist, $resp.record.placement)
  } catch { Log ("  FAILED {0}: {1}" -f $f.Name, $_.Exception.Message) }
}
Log ("Done. {0} new match(es) uploaded." -f $newCount)