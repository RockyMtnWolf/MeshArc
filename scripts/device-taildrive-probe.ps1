param(
  [switch]$SkipInstall,
  [string]$MachineName = 'magicbook-pro-14',
  [string]$ShareName = 'downloads',
  [int]$ConnectionTimeoutSeconds = 90,
  [int]$ListingTimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$devecoHome = @(
  $env:DEVECO_STUDIO_HOME,
  $env:DEVECO_HOME,
  'C:\Program Files\Huawei\DevEco Studio'
) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'product-info.json')) } |
  Select-Object -First 1
if (-not $devecoHome) {
  throw 'DevEco Studio was not found.'
}

$hdc = Join-Path $devecoHome 'sdk\default\openharmony\toolchains\hdc.exe'
$usbTargets = @(& $hdc list targets -v |
  Where-Object { $_ -match "`t`tUSB`tConnected`t" })
if ($usbTargets.Count -ne 1) {
  throw 'Expected exactly one connected USB target.'
}
$target = ($usbTargets[0] -split "`t")[0]
$bundleName = 'io.github.rockymtnwolf.mesharc'
$remoteLayout = '/data/local/tmp/mesh-taildrive-probe.json'
$localLayout = Join-Path $projectRoot '.hvigor\outputs\taildrive-probe.json'

if (-not $SkipInstall) {
  $hap = Join-Path $projectRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
  if (-not (Test-Path $hap)) {
    throw 'The signed HAP is missing. Run scripts/build.ps1 first.'
  }
  & $hdc -t $target shell aa force-stop $bundleName | Out-Null
  & $hdc -t $target install -r $hap | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "HAP install failed with exit code $LASTEXITCODE"
  }
}

$startOutput = (& $hdc -t $target shell aa start -b $bundleName -a EntryAbility 2>&1) -join "`n"
if ($startOutput.Contains('device screen is locked')) {
  throw 'The device screen is locked. Unlock it before running the Taildrive probe.'
}
if ($LASTEXITCODE -ne 0 -or -not $startOutput.Contains('start ability successfully')) {
  throw "Ability start failed: $startOutput"
}

New-Item -ItemType Directory -Force -Path (Split-Path $localLayout) | Out-Null

function Receive-Layout {
  & $hdc -t $target shell uitest dumpLayout -p $remoteLayout | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Layout capture failed with exit code $LASTEXITCODE"
  }
  & $hdc -t $target file recv $remoteLayout $localLayout | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Layout receive failed with exit code $LASTEXITCODE"
  }
  return [System.IO.File]::ReadAllText($localLayout)
}

function Get-NodeBounds([string]$Layout, [string]$Id) {
  $match = [regex]::Match(
    $Layout,
    'id":"' + [regex]::Escape($Id) + '".{0,2200}?origBounds":"\[(\d+),(\d+)\]\[(\d+),(\d+)\]"'
  )
  if (-not $match.Success) {
    throw "Could not resolve node bounds: $Id"
  }
  return [pscustomobject]@{
    Left = [int]$match.Groups[1].Value
    Top = [int]$match.Groups[2].Value
    Right = [int]$match.Groups[3].Value
    Bottom = [int]$match.Groups[4].Value
  }
}

function Get-NodeCenter([string]$Layout, [string]$Id) {
  $bounds = Get-NodeBounds $Layout $Id
  return [pscustomobject]@{
    X = [int](($bounds.Left + $bounds.Right) / 2)
    Y = [int](($bounds.Top + $bounds.Bottom) / 2)
  }
}

function Has-Node([string]$Layout, [string]$Id) {
  return $Layout.Contains('"id":"' + $Id + '"')
}

function Is-TaildriveIdle([string]$Layout) {
  return (Has-Node $Layout 'taildrive-refresh') -and -not (Has-Node $Layout 'taildrive-refresh-loading')
}

function Get-FirstNodeIdByPrefix([string]$Layout, [string]$Prefix) {
  $match = [regex]::Match($Layout, 'id":"(' + [regex]::Escape($Prefix) + '[^"\\]+)"')
  if (-not $match.Success) {
    return ''
  }
  return $match.Groups[1].Value
}

function Tap-Node([string]$Layout, [string]$Id) {
  $center = Get-NodeCenter $Layout $Id
  & $hdc -t $target shell uitest uiInput click $center.X $center.Y | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Tap failed: $Id"
  }
}

function Wait-ForLayout([scriptblock]$Predicate, [int]$TimeoutSeconds, [string]$FailureMessage) {
  $startedAt = Get-Date
  do {
    $layout = Receive-Layout
    if (& $Predicate $layout) {
      return $layout
    }
    Start-Sleep -Milliseconds 500
  } while (((Get-Date) - $startedAt).TotalSeconds -lt $TimeoutSeconds)
  throw $FailureMessage
}

function Get-TaildriveEntryNames([string]$Layout) {
  return @([regex]::Matches($Layout, 'id":"taildrive-entry-([^"\\]+)"') |
    ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
}

function Normalize-MachineName([string]$Value) {
  return $Value.Trim().TrimEnd('.').ToLowerInvariant().Split('.')[0]
}

try {
  Start-Sleep -Seconds 3
  $layout = Receive-Layout
  Tap-Node $layout 'tab-home'
  $homeLayout = Wait-ForLayout { param($value) $value.Contains('vpn-stop') } `
    $ConnectionTimeoutSeconds 'Tailscale did not reach the connected state.'

  Tap-Node $homeLayout 'tab-files'
  $rootLayout = Wait-ForLayout {
    param($value)
    (Get-TaildriveEntryNames $value).Count -gt 0 -and (Is-TaildriveIdle $value)
  } $ListingTimeoutSeconds 'Taildrive did not list a tailnet root.'
  $rootEntries = @(Get-TaildriveEntryNames $rootLayout)
  $tailnet = [string]($rootEntries | Select-Object -First 1)
  Tap-Node $rootLayout "taildrive-entry-$tailnet"

  $machineLayout = Wait-ForLayout {
    param($value)
    $expected = Normalize-MachineName $MachineName
    @((Get-TaildriveEntryNames $value) | Where-Object {
      (Normalize-MachineName $_) -eq $expected
    }).Count -gt 0 -and (Has-Node $value 'taildrive-breadcrumb-0') -and (Is-TaildriveIdle $value)
  } $ListingTimeoutSeconds "Taildrive did not list machine: $MachineName"
  $machineMatches = @((Get-TaildriveEntryNames $machineLayout) | Where-Object {
    (Normalize-MachineName $_) -eq (Normalize-MachineName $MachineName)
  })
  $machineEntry = [string]($machineMatches | Select-Object -First 1)
  Tap-Node $machineLayout "taildrive-entry-$machineEntry"

  $shareLayout = Wait-ForLayout {
    param($value)
    @((Get-TaildriveEntryNames $value) | Where-Object {
      $_.Equals($ShareName, [System.StringComparison]::OrdinalIgnoreCase)
    }).Count -gt 0 -and (Has-Node $value 'taildrive-breadcrumb-1') -and (Is-TaildriveIdle $value)
  } $ListingTimeoutSeconds "Taildrive did not list share: $ShareName"
  $shareMatches = @((Get-TaildriveEntryNames $shareLayout) | Where-Object {
    $_.Equals($ShareName, [System.StringComparison]::OrdinalIgnoreCase)
  })
  $shareEntry = [string]($shareMatches | Select-Object -First 1)
  Tap-Node $shareLayout "taildrive-entry-$shareEntry"

  $contentLayout = Wait-ForLayout {
    param($value)
    (Has-Node $value 'taildrive-breadcrumb-2') -and (Is-TaildriveIdle $value)
  } $ListingTimeoutSeconds "Taildrive did not open share: $ShareName"
  $contentEntries = Get-TaildriveEntryNames $contentLayout
  if ($contentEntries.Count -eq 0) {
    throw 'Taildrive share is empty; interactive file-row checks cannot run.'
  }

  $browserBounds = Get-NodeBounds $contentLayout 'taildrive-browser'
  if ($browserBounds.Top -ge 500) {
    throw "Taildrive content is not top aligned: top=$($browserBounds.Top)"
  }

  $backBounds = Get-NodeBounds $contentLayout 'taildrive-back'
  $backIconBounds = Get-NodeBounds $contentLayout 'taildrive-back-icon'
  $backCenterX = ($backBounds.Left + $backBounds.Right) / 2
  $backCenterY = ($backBounds.Top + $backBounds.Bottom) / 2
  $iconCenterX = ($backIconBounds.Left + $backIconBounds.Right) / 2
  $iconCenterY = ($backIconBounds.Top + $backIconBounds.Bottom) / 2
  if ([Math]::Abs($backCenterX - $iconCenterX) -gt 2 -or [Math]::Abs($backCenterY - $iconCenterY) -gt 2) {
    throw 'Taildrive back icon is not centered.'
  }

  Tap-Node $contentLayout 'taildrive-refresh'
  $refreshLayout = Wait-ForLayout {
    param($value)
    Has-Node $value 'taildrive-refresh-loading'
  } 5 'Taildrive refresh did not expose a loading indicator.'
  $contentLayout = Wait-ForLayout {
    param($value)
    (Has-Node $value 'taildrive-breadcrumb-2') -and (Is-TaildriveIdle $value)
  } $ListingTimeoutSeconds 'Taildrive refresh did not finish.'

  Tap-Node $contentLayout 'taildrive-search-trigger'
  $searchLayout = Wait-ForLayout {
    param($value)
    (Has-Node $value 'taildrive-search') -and
      (Has-Node $value 'taildrive-search-back') -and
      (Has-Node $value 'taildrive-multi-select') -and
      -not (Has-Node $value 'taildrive-search-trigger')
  } 10 'Taildrive search header did not transition in place.'
  $searchBounds = Get-NodeBounds $searchLayout 'taildrive-search'
  $multiBounds = Get-NodeBounds $searchLayout 'taildrive-multi-select'
  if ([Math]::Abs((($searchBounds.Top + $searchBounds.Bottom) / 2) -
      (($multiBounds.Top + $multiBounds.Bottom) / 2)) -gt 8) {
    throw 'Taildrive search and multi-select controls are not vertically aligned.'
  }
  $searchToken = ([regex]::Match(($contentEntries -join ' '), '[A-Za-z0-9]{2,}')).Value
  if ($searchToken) {
    $searchCenter = Get-NodeCenter $searchLayout 'taildrive-search'
    & $hdc -t $target shell uitest uiInput inputText $searchCenter.X $searchCenter.Y $searchToken | Out-Null
    & $hdc -t $target shell uitest uiInput keyEvent 2054 | Out-Null
    $searchLayout = Wait-ForLayout {
      param($value)
      (Has-Node $value 'taildrive-search') -and (Get-TaildriveEntryNames $value).Count -gt 0
    } 10 'Taildrive search did not return results after IME confirmation.'
  }
  Tap-Node $searchLayout 'taildrive-search-back'
  $contentLayout = Wait-ForLayout {
    param($value)
    (Has-Node $value 'taildrive-search-trigger') -and (Is-TaildriveIdle $value)
  } 10 'Taildrive search header did not close.'

  Tap-Node $contentLayout 'taildrive-new-folder'
  $editorLayout = Wait-ForLayout {
    param($value)
    (Has-Node $value 'taildrive-editor-input') -and (Has-Node $value 'taildrive-editor-confirm')
  } 10 'Taildrive new-folder editor did not open.'
  & $hdc -t $target shell uitest uiInput keyEvent BACK | Out-Null
  $contentLayout = Wait-ForLayout {
    param($value)
    -not (Has-Node $value 'taildrive-editor-input') -and (Has-Node $value 'taildrive-breadcrumb-2')
  } 10 'Taildrive new-folder editor did not close.'

  $moreId = Get-FirstNodeIdByPrefix $contentLayout 'taildrive-more-'
  if (-not $moreId) {
    throw 'Taildrive share contains no file action button.'
  }
  Tap-Node $contentLayout $moreId
  $detailsLayout = Wait-ForLayout {
    param($value)
    Has-Node $value 'taildrive-details-sheet'
  } 10 'Taildrive file action menu did not open.'
  & $hdc -t $target shell uitest uiInput keyEvent BACK | Out-Null
  $contentLayout = Wait-ForLayout {
    param($value)
    -not (Has-Node $value 'taildrive-details-sheet') -and (Has-Node $value 'taildrive-breadcrumb-2')
  } 10 'Taildrive file action menu did not close.'

  $firstEntry = [string]($contentEntries | Select-Object -First 1)
  $entryCenter = Get-NodeCenter $contentLayout "taildrive-entry-$firstEntry"
  & $hdc -t $target shell uitest uiInput longClick $entryCenter.X $entryCenter.Y | Out-Null
  $selectionLayout = Wait-ForLayout {
    param($value)
    Has-Node $value "taildrive-selection-mark-$firstEntry"
  } 10 'Taildrive long press did not enter multi-select mode.'
  Tap-Node $selectionLayout 'taildrive-multi-select'
  $contentLayout = Wait-ForLayout {
    param($value)
    -not (Has-Node $value "taildrive-selection-mark-$firstEntry") -and
      (Has-Node $value 'taildrive-search-trigger')
  } 10 'Taildrive multi-select mode did not close.'

  Tap-Node $contentLayout 'taildrive-view-toggle'
  $gridLayout = Wait-ForLayout {
    param($value)
    Has-Node $value 'taildrive-grid-view'
  } 10 'Taildrive grid view did not appear.'
  Tap-Node $gridLayout 'taildrive-view-toggle'
  $contentLayout = Wait-ForLayout {
    param($value)
    Has-Node $value 'taildrive-list-view'
  } 10 'Taildrive list view did not return.'

  Tap-Node $contentLayout 'taildrive-sort'
  $sortLayout = Wait-ForLayout {
    param($value)
    Has-Node $value 'taildrive-sort-confirm'
  } 10 'Taildrive sort sheet did not open.'
  $panelBounds = Get-NodeBounds $sortLayout 'taildrive-sort-panel'
  if ($panelBounds.Top -le $browserBounds.Top) {
    throw 'Taildrive sort panel unexpectedly covers the full page.'
  }
  $confirmBounds = Get-NodeBounds $sortLayout 'taildrive-sort-confirm'
  if ($confirmBounds.Bottom -ge 2750) {
    throw "Taildrive sort sheet footer overlaps the gesture area: bottom=$($confirmBounds.Bottom)"
  }

  Tap-Node $sortLayout 'taildrive-sort-modified'
  $sortChangedLayout = Wait-ForLayout {
    param($value)
    (Has-Node $value 'taildrive-sort-confirm') -and (Has-Node $value 'taildrive-sort-modified-selected')
  } 10 'Taildrive sort rule did not respond.'
  Tap-Node $sortChangedLayout 'taildrive-group-type'
  $groupChangedLayout = Wait-ForLayout {
    param($value)
    (Has-Node $value 'taildrive-sort-confirm') -and (Has-Node $value 'taildrive-group-type-selected')
  } 10 'Taildrive group rule did not respond.'
  Tap-Node $groupChangedLayout 'taildrive-sort-confirm'
  $sortedContentLayout = Wait-ForLayout {
    param($value)
    -not (Has-Node $value 'taildrive-sort-confirm') -and (Has-Node $value 'taildrive-breadcrumb-2')
  } 10 'Taildrive sort sheet did not close.'

  Tap-Node $sortedContentLayout 'taildrive-breadcrumb-1'
  $breadcrumbLayout = Wait-ForLayout {
    param($value)
    (Has-Node $value "taildrive-entry-$ShareName") -and
      (Has-Node $value 'taildrive-breadcrumb-1') -and
      -not (Has-Node $value 'taildrive-breadcrumb-2') -and
      (Is-TaildriveIdle $value)
  } $ListingTimeoutSeconds 'Taildrive breadcrumb did not navigate to the device directory.'

  & $hdc -t $target shell uitest uiInput keyEvent BACK | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'System back input failed.'
  }
  $backNavigationLayout = Wait-ForLayout {
    param($value)
    (Has-Node $value 'taildrive-breadcrumb-0') -and
      -not (Has-Node $value 'taildrive-breadcrumb-1') -and
      (Has-Node $value 'hds-navigation-files') -and
      (Is-TaildriveIdle $value)
  } $ListingTimeoutSeconds 'System back did not return to the parent Taildrive directory.'

  [pscustomobject]@{
    Result = 'passed'
    Device = $target
    Connected = $true
    Tailnet = $tailnet
    Machine = $machineEntry
    Share = $shareEntry
    ShareOpened = $true
    VisibleEntryCount = $contentEntries.Count
    ReadOnlyProbe = $true
    ContentTopAligned = $true
    SortSheetSafe = $true
    SortPanelHasNoFullscreenMask = $true
    BackIconCentered = $true
    RefreshAnimationVisible = $true
    SearchHeaderInteractive = $true
    SearchImeSubmitInteractive = [bool]$searchToken
    NewFolderEditorInteractive = $true
    FileActionMenuInteractive = $true
    LongPressMultiSelectInteractive = $true
    ViewModeInteractive = $true
    SortAndGroupInteractive = $true
    BreadcrumbInteractive = $true
    SystemBackNavigatesUp = $true
  }
} finally {
  & $hdc -t $target shell rm -f $remoteLayout | Out-Null
  if (Test-Path $localLayout) {
    Remove-Item -LiteralPath $localLayout -Force
  }
}
