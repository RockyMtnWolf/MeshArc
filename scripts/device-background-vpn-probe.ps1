param(
  [string]$DeviceId = '',
  [ValidateRange(60, 7200)][int]$DurationSeconds = 720,
  [ValidateRange(10, 60)][int]$IntervalSeconds = 30,
  [int]$AppUserId = 100,
  [switch]$LockScreen,
  [string]$PeerAddress = '',
  [string]$ArtifactDir = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$devecoHome = @($env:DEVECO_STUDIO_HOME, $env:DEVECO_HOME,
  'C:\Program Files\Huawei\DevEco Studio') |
  Where-Object { $_ -and (Test-Path (Join-Path $_ 'product-info.json')) } | Select-Object -First 1
if (-not $devecoHome) { throw 'DevEco Studio was not found.' }
$hdc = Join-Path $devecoHome 'sdk\default\openharmony\toolchains\hdc.exe'
if (-not $DeviceId) {
  $targets = @(& $hdc list targets -v | Where-Object { $_ -match "`t`tUSB`tConnected`t" })
  if ($targets.Count -ne 1) { throw 'Specify DeviceId when exactly one USB device is not connected.' }
  $DeviceId = ($targets[0] -split "`t")[0]
}
$bundleName = 'io.github.rockymtnwolf.mesharc'
$filesDir = "/data/app/el2/$AppUserId/base/$bundleName/haps/entry/files"
if (-not $ArtifactDir) {
  $ArtifactDir = Join-Path $projectRoot ('.codex/background-vpn/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
$samples = [System.Collections.Generic.List[object]]::new()
$elapsed = [Diagnostics.Stopwatch]::StartNew()

function Read-Sample {
  $status = (& $hdc -t $DeviceId shell -b $bundleName cat "$filesDir/vpn-probe-status.txt") -join ''
  if ($LASTEXITCODE -ne 0 -or $status -match '\[Fail\]|Permission denied|No such file') {
    throw 'Cannot read VPN diagnostic status; the installed app must allow HDC bundle access.'
  }
  $deviceEpoch = ((& $hdc -t $DeviceId shell date '+%s') -join '').Trim()
  $heartbeat = [regex]::Match($status, 'heartbeatMs=(\d+)')
  $heartbeatMs = if ($heartbeat.Success) { [long]$heartbeat.Groups[1].Value } else { 0 }
  $ageMs = if ($deviceEpoch -match '^\d+$' -and $heartbeatMs -gt 0) {
    [Math]::Max(0, ([long]$deviceEpoch * 1000) - $heartbeatMs)
  } else { [long]::MaxValue }
  $processes = @(& $hdc -t $DeviceId shell ps -A -o PID,NAME,ARGS | Where-Object { $_ -match 'tailscaleohos' })
  $pids = @($processes | ForEach-Object { ($_ -split '\s+' | Where-Object { $_ })[0] })
  $power = (& $hdc -t $DeviceId shell hidumper -s PowerManagerService -a '-s') -join "`n"
  $powerState = [regex]::Match($power, 'Current State:\s*(\w+)').Groups[1].Value
  return [PSCustomObject]@{
    ElapsedSeconds = [int]$elapsed.Elapsed.TotalSeconds
    Running = $status.Contains('state=Running') -and $status.Contains('tun=true')
    HeartbeatMs = $heartbeatMs
    HeartbeatAgeMs = $ageMs
    ProcessCount = $pids.Count
    ProcessIds = $pids -join ','
    PowerState = $powerState
  }
}

function Test-Peer {
  if (-not $PeerAddress) { return 'not-requested' }
  $ping = [System.Net.NetworkInformation.Ping]::new()
  try {
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
      $reply = $ping.Send($PeerAddress, 5000)
      if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { return 'reachable' }
    }
    return 'unreachable'
  } finally { $ping.Dispose() }
}

$baseline = Read-Sample
if ($LockScreen -and $baseline.PowerState -notin @('AWAKE', 'INACTIVE', 'STAND_BY', 'DOZE', 'SLEEP', 'HIBERNATE')) {
  throw 'Cannot verify the power state for the lock probe.'
}
if (-not $baseline.Running -or $baseline.HeartbeatAgeMs -gt 15000) {
  throw 'Connect VPN in the app before starting the background probe.'
}
$peerBefore = Test-Peer
if ($PeerAddress -and $peerBefore -ne 'reachable') {
  throw 'The optional ICMP baseline is unreachable. Verify the address/firewall, or omit PeerAddress for a liveness-only test and use device-vpn-data-probe.ps1 for tunnel traffic.'
}
$samples.Add($baseline)
if (-not $LockScreen -or $baseline.PowerState -eq 'AWAKE') {
  & $hdc -t $DeviceId shell uitest uiInput keyEvent Home | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Could not send Home.' }
  if ($LockScreen) {
    & $hdc -t $DeviceId shell uitest uiInput keyEvent Power | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not send Power; verify the screen is locked.' }
  }
}

# Deliberately send no peer traffic during the wait. Repeated network probes
# could keep an otherwise idle connection alive and conceal the failure.
while ($elapsed.Elapsed.TotalSeconds -lt $DurationSeconds) {
  $remaining = $DurationSeconds - $elapsed.Elapsed.TotalSeconds
  Start-Sleep -Milliseconds ([int][Math]::Min($IntervalSeconds * 1000, $remaining * 1000))
  $sample = Read-Sample
  $samples.Add($sample)
  $sample | ConvertTo-Json -Compress | Write-Output
  $samples | ConvertTo-Json -Depth 3 | Set-Content -Encoding UTF8 (Join-Path $ArtifactDir 'samples.json')
  if (-not $sample.Running -or $sample.HeartbeatAgeMs -gt 15000 -or $sample.ProcessCount -lt 2) { break }
}
$peerAfter = Test-Peer
$last = $samples[$samples.Count - 1]
$passed = $last.ElapsedSeconds -ge $DurationSeconds -and
  @($samples | Where-Object { -not $_.Running -or $_.HeartbeatAgeMs -gt 15000 -or $_.ProcessCount -lt 2 }).Count -eq 0 -and
  $last.ProcessIds -eq $baseline.ProcessIds -and
  (-not $LockScreen -or @($samples | Select-Object -Skip 1 | Where-Object {
    $_.PowerState -notin @('INACTIVE', 'STAND_BY', 'DOZE', 'SLEEP', 'HIBERNATE')
  }).Count -eq 0) -and
  (-not $PeerAddress -or ($peerBefore -eq 'reachable' -and $peerAfter -eq 'reachable'))
$summary = [PSCustomObject]@{
  Passed = $passed
  DurationSeconds = $last.ElapsedSeconds
  LockRequested = [bool]$LockScreen
  PeerBefore = $peerBefore
  PeerAfter = $peerAfter
  SameProcesses = $last.ProcessIds -eq $baseline.ProcessIds
  MaxHeartbeatAgeMs = ($samples | Measure-Object -Property HeartbeatAgeMs -Maximum).Maximum
  SampleCount = $samples.Count
  Caveat = 'USB/HDC attached. Does not establish unplugged battery survival or force-stop recovery.'
}
$summary | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $ArtifactDir 'summary.json')
$summary | Format-List
if (-not $passed) { throw "Background VPN probe failed. Redacted evidence: $ArtifactDir" }
