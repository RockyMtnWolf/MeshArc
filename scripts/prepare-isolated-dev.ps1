param(
  [Parameter(Mandatory = $true)]
  [string]$TargetDirectory,
  [string[]]$AdditionalSourcePaths = @()
)

$ErrorActionPreference = 'Stop'

$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sourceRootFull = [System.IO.Path]::GetFullPath($sourceRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
$targetLexicalFull = [System.IO.Path]::GetFullPath($TargetDirectory)

if ([System.IO.Directory]::Exists($targetLexicalFull) -or [System.IO.File]::Exists($targetLexicalFull)) {
  throw "Target already exists: $targetLexicalFull"
}

$targetParent = [System.IO.Path]::GetDirectoryName($targetLexicalFull)
if (-not $targetParent -or -not (Test-Path -LiteralPath $targetParent -PathType Container)) {
  throw "Target parent directory must already exist: $targetParent"
}
$targetParentResolved = (Resolve-Path -LiteralPath $targetParent).Path
$targetFull = [System.IO.Path]::GetFullPath((Join-Path $targetParentResolved ([System.IO.Path]::GetFileName($targetLexicalFull))))
$targetForComparison = $targetFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar

$pathComparison = if ($env:OS -eq 'Windows_NT') {
  [System.StringComparison]::OrdinalIgnoreCase
} else {
  [System.StringComparison]::Ordinal
}
$targetLexicalForComparison = $targetLexicalFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
if ($targetLexicalFull.Equals($sourceRoot, $pathComparison) -or $targetLexicalForComparison.StartsWith($sourceRootFull, $pathComparison)) {
  throw "Target must be outside the source repository: $targetLexicalFull"
}

if ($targetFull.Equals($sourceRoot, $pathComparison) -or $targetForComparison.StartsWith($sourceRootFull, $pathComparison)) {
  throw "Target must be outside the source repository: $targetFull"
}

$trackedFiles = @(& git -C $sourceRoot ls-files --cached --full-name)
if ($LASTEXITCODE -ne 0) {
  throw 'Could not enumerate Git-tracked files.'
}
if ($trackedFiles.Count -eq 0) {
  throw 'The source repository has no Git-tracked files to copy.'
}

$appPath = Join-Path $sourceRoot 'AppScope\app.json5'
$stringsPath = Join-Path $sourceRoot 'AppScope\resources\base\element\string.json'
$profileExamplePath = Join-Path $sourceRoot 'build-profile.example.json5'
$requiredTrackedFiles = @(
  'AppScope/app.json5',
  'AppScope/resources/base/element/string.json',
  'build-profile.example.json5'
)
foreach ($requiredTrackedFile in $requiredTrackedFiles) {
  if ($trackedFiles -notcontains $requiredTrackedFile) {
    throw "Required tracked file is missing: $requiredTrackedFile"
  }
}

$validatedAdditionalPaths = @()
foreach ($additionalSourcePath in $AdditionalSourcePaths) {
  if ([string]::IsNullOrWhiteSpace($additionalSourcePath) -or
      [System.IO.Path]::IsPathRooted($additionalSourcePath) -or
      $additionalSourcePath -match '^[A-Za-z]:' -or
      $additionalSourcePath.Contains(':')) {
    throw "Additional source path must be a repository-relative file path: $additionalSourcePath"
  }

  $pathSegments = @($additionalSourcePath -split '[\\/]')
  if ($pathSegments -contains '..' -or @($pathSegments | Where-Object { $_ -ieq '.git' }).Count -gt 0) {
    throw "Additional source path cannot contain '..' or '.git' segments: $additionalSourcePath"
  }

  $normalizedRelativePath = $additionalSourcePath.Replace('\', [System.IO.Path]::DirectorySeparatorChar).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
  $additionalFullPath = [System.IO.Path]::GetFullPath((Join-Path $sourceRoot $normalizedRelativePath))
  if (-not $additionalFullPath.StartsWith($sourceRootFull, $pathComparison)) {
    throw "Additional source path must stay inside the source repository: $additionalSourcePath"
  }
  if (-not (Test-Path -LiteralPath $additionalFullPath -PathType Leaf)) {
    throw "Additional source path must name an existing file: $additionalSourcePath"
  }

  $relativeSegments = @($normalizedRelativePath -split [regex]::Escape([string][System.IO.Path]::DirectorySeparatorChar))
  $walkPath = $sourceRoot
  foreach ($relativeSegment in $relativeSegments) {
    $walkPath = Join-Path $walkPath $relativeSegment
    $walkItem = Get-Item -LiteralPath $walkPath -Force
    if (($walkItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Additional source path cannot traverse symbolic links or reparse points: $additionalSourcePath"
    }
  }

  $validatedAdditionalPaths += $normalizedRelativePath
}

$arkTsFiles = @($trackedFiles | Where-Object { $_ -match '^entry/src/main/ets/.+\.ets$' })
$appSourceContent = [System.IO.File]::ReadAllText($appPath)
$bundleDeclarationPattern = '"bundleName"\s*:\s*"([^"]+)"'
$bundleDeclarations = [regex]::Matches($appSourceContent, $bundleDeclarationPattern)
if ($bundleDeclarations.Count -ne 1) {
  throw 'Expected exactly one source bundleName in AppScope/app.json5. No destination was created.'
}
$sourceBundleName = $bundleDeclarations[0].Groups[1].Value
$sourceBundlePattern = [regex]::Escape($sourceBundleName)
$developmentBundleName = 'io.github.tailscaleohos.devtest'
$bundlePattern = '("bundleName"\s*:\s*")' + $sourceBundlePattern + '(\")'
$bundleNameCount = 0
foreach ($relativePath in $arkTsFiles) {
  $content = [System.IO.File]::ReadAllText((Join-Path $sourceRoot $relativePath))
  $bundleNameCount += [regex]::Matches($content, $sourceBundlePattern).Count
}
if ($bundleNameCount -ne 4) {
  throw "Expected exactly 4 ArkTS bundle-name references for '$sourceBundleName', found $bundleNameCount. No destination was created."
}
$stringsSourceContent = [System.IO.File]::ReadAllText($stringsPath)
$appNamePattern = '("name"\s*:\s*"app_name"\s*,\s*"value"\s*:\s*")([^"]*)(")'
if ([regex]::Matches($stringsSourceContent, $appNamePattern).Count -ne 1) {
  throw 'Expected exactly one app_name label in AppScope/resources/base/element/string.json. No destination was created.'
}
$entryStringFiles = @(($trackedFiles + $validatedAdditionalPaths) |
  Where-Object { $_ -match '^entry[\\/]src[\\/]main[\\/]resources[\\/].+[\\/]element[\\/]string\.json$' } |
  Select-Object -Unique)
$entryabilityLabelPattern = '("name"\s*:\s*"entryability_label"\s*,\s*"value"\s*:\s*")([^"]*)(")'
foreach ($relativePath in $entryStringFiles) {
  $sourcePath = Join-Path $sourceRoot $relativePath
  $content = [System.IO.File]::ReadAllText($sourcePath)
  if ([regex]::Matches($content, $entryabilityLabelPattern).Count -ne 1) {
    throw "Expected exactly one entryability_label in $relativePath. No destination was created."
  }
}

[void][System.IO.Directory]::CreateDirectory($targetFull)
foreach ($relativePath in $trackedFiles) {
  $sourcePath = Join-Path $sourceRoot $relativePath
  if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    continue
  }

  $destinationPath = Join-Path $targetFull $relativePath
  [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destinationPath))
  Copy-Item -LiteralPath $sourcePath -Destination $destinationPath
}

foreach ($relativePath in $validatedAdditionalPaths) {
  $sourcePath = Join-Path $sourceRoot $relativePath
  $destinationPath = Join-Path $targetFull $relativePath
  [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destinationPath))
  Copy-Item -LiteralPath $sourcePath -Destination $destinationPath
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$appCopyPath = Join-Path $targetFull 'AppScope\app.json5'
$appContent = [System.IO.File]::ReadAllText($appCopyPath)
$appContent = [regex]::Replace($appContent, $bundlePattern, ('$1' + $developmentBundleName + '$2'))
[System.IO.File]::WriteAllText($appCopyPath, $appContent, $utf8NoBom)

foreach ($relativePath in $arkTsFiles) {
  $destinationPath = Join-Path $targetFull $relativePath
  $content = [System.IO.File]::ReadAllText($destinationPath)
  $content = $content.Replace($sourceBundleName, $developmentBundleName)
  [System.IO.File]::WriteAllText($destinationPath, $content, $utf8NoBom)
}

$stringsCopyPath = Join-Path $targetFull 'AppScope\resources\base\element\string.json'
$stringsContent = [System.IO.File]::ReadAllText($stringsCopyPath)
$stringsContent = [regex]::Replace($stringsContent, $appNamePattern, { param($match) $match.Groups[1].Value + $match.Groups[2].Value + ' Dev Test' + $match.Groups[3].Value })
[System.IO.File]::WriteAllText($stringsCopyPath, $stringsContent, $utf8NoBom)

foreach ($relativePath in $entryStringFiles) {
  $destinationPath = Join-Path $targetFull $relativePath
  $content = [System.IO.File]::ReadAllText($destinationPath)
  $content = [regex]::Replace($content, $entryabilityLabelPattern, { param($match) $match.Groups[1].Value + $match.Groups[2].Value + ' Dev Test' + $match.Groups[3].Value })
  [System.IO.File]::WriteAllText($destinationPath, $content, $utf8NoBom)
}

Copy-Item -LiteralPath $profileExamplePath -Destination (Join-Path $targetFull 'build-profile.json5')

Write-Host "Created isolated development copy: $targetFull"
Write-Host "Bundle name: $developmentBundleName"
Write-Host 'App label suffix: Dev Test'
Write-Host 'This script does not install, launch, sign, or connect the app to a VPN.'

$nativeDependencies = @(
  'third_party/ohos-go/bin/go.exe',
  'third_party/tailscale/go.mod',
  'native/go_bridge/dist/arm64-v8a/libtailscale_go.so',
  'entry/libs/arm64-v8a/libtailscale_go.so'
)
$missingDependencies = @($nativeDependencies | Where-Object { -not (Test-Path -LiteralPath (Join-Path $targetFull $_)) })
if ($missingDependencies.Count -gt 0) {
  Write-Warning "Native dependencies are not present in the tracked-file copy and must be prepared separately: $($missingDependencies -join ', ')"
}
