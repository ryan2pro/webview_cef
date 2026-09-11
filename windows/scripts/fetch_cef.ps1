<#
.SYNOPSIS
    Fetches the CEF (Chromium Embedded Framework) Windows x64 standard distribution.

.DESCRIPTION
    Downloads and extracts the CEF "standard" distribution into
    <repo>/third_party/cef, which the CMake build uses as CEF_ROOT.

    The standard package is required - the "minimal" one is not enough - because
    only the standard package ships the libcef_dll/ wrapper sources that
    libcef_dll_wrapper has to be compiled from, plus the sample/test projects and
    the full runtime resource set.

    The script is idempotent: the extracted version is recorded in
    third_party/cef/cef_version.txt and the download is skipped when the
    requested version is already in place.

.PARAMETER Version
    CEF version string, for example:
    "150.0.20+ga832838+chromium-150.0.7871.253"
    The version must exist in the windows64 build index on cef-builds.spotifycdn.com.

.PARAMETER Force
    Re-download and re-extract even when the requested version is already present.

.PARAMETER KeepArchive
    Keep the downloaded archive in third_party/.cache after a successful extraction.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File windows/scripts/fetch_cef.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File windows/scripts/fetch_cef.ps1 -Version 144.0.34+g8fc21c8+chromium-144.0.7559.261 -Force
#>
[CmdletBinding()]
param(
    [string]$Version = '150.0.20+ga832838+chromium-150.0.7871.253',
    [switch]$Force,
    [switch]$KeepArchive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Configuration -----------------------------------------------------------

# Version that ships as the project default.
$DefaultVersion = '150.0.20+ga832838+chromium-150.0.7871.253'

# SHA1 of the default version's standard archive, used as an offline fallback
# when the CEF build index cannot be reached. Any other version resolves its
# SHA1 from the index at run time.
$DefaultArchiveSha1 = '110b46ecc46f1b45a7cc41f959de6ce5d9b2110a'

$CefCdnBase = 'https://cef-builds.spotifycdn.com'

# --- Paths -------------------------------------------------------------------

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptDir)) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$RepoRoot      = (Resolve-Path -LiteralPath (Join-Path $ScriptDir '..\..')).Path
$ThirdPartyDir = Join-Path $RepoRoot 'third_party'
$CefRoot       = Join-Path $ThirdPartyDir 'cef'
$CacheDir      = Join-Path $ThirdPartyDir '.cache'
$ExtractDir    = Join-Path $CacheDir 'extract'

$ArchiveName   = 'cef_binary_{0}_windows64.tar.bz2' -f $Version
$ArchivePath   = Join-Path $CacheDir $ArchiveName
$PartialPath   = $ArchivePath + '.part'
$DownloadUrl   = '{0}/{1}' -f $CefCdnBase, $ArchiveName
$VersionMarker = Join-Path $CefRoot 'cef_version.txt'

# --- Helpers -----------------------------------------------------------------

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-CefArchiveSha1FromIndex {
    param(
        [string]$CefVersion,
        [string]$FileName
    )

    $indexUrl = '{0}/index.json' -f $CefCdnBase
    Write-Host "Resolving SHA1 from $indexUrl ..."

    $index = Invoke-RestMethod -Uri $indexUrl -TimeoutSec 180

    $versions = $null
    if ($index.PSObject.Properties.Name -contains 'windows64') {
        $versions = $index.windows64.versions
    }
    if (-not $versions) {
        throw "The CEF build index does not contain a 'windows64' section."
    }

    $entry = $versions | Where-Object { $_.cef_version -eq $CefVersion } | Select-Object -First 1
    if (-not $entry) {
        throw "CEF version '$CefVersion' was not found in the windows64 build index. Pick a version listed at $CefCdnBase."
    }

    $file = $entry.files | Where-Object { $_.name -eq $FileName } | Select-Object -First 1
    if (-not $file) {
        throw "The windows64 build '$CefVersion' does not provide '$FileName'."
    }

    return [string]$file.sha1
}

function Test-CefUpToDate {
    param(
        [string]$Root,
        [string]$ExpectedVersion,
        [string]$MarkerPath
    )

    if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) { return $false }

    $installedVersion = (Get-Content -LiteralPath $MarkerPath -Raw).Trim()
    if ($installedVersion -ne $ExpectedVersion) { return $false }

    # Guards against a partially removed tree that kept its marker file.
    return (Test-Path -LiteralPath (Join-Path $Root 'libcef_dll\CMakeLists.txt') -PathType Leaf)
}

function Receive-CefArchive {
    param(
        [string]$Url,
        [string]$PartialPath
    )

    # `curl.exe` is used explicitly: in Windows PowerShell 5.1 the bare name
    # `curl` is an alias for Invoke-WebRequest, which buffers the whole response
    # in memory instead of streaming it to disk.
    $curl = Get-Command -Name 'curl.exe' -ErrorAction SilentlyContinue
    if ($curl) {
        Write-Host 'Downloading with curl.exe (streamed to disk, resumable) ...'
        & $curl.Path -L --fail --retry 5 --retry-delay 5 --continue-at - --output $PartialPath $Url
        if ($LASTEXITCODE -ne 0) {
            throw "curl.exe failed with exit code $LASTEXITCODE while downloading $Url. Re-run the script to resume the partial download."
        }
    } else {
        Write-Host 'curl.exe not available, falling back to System.Net.WebClient (not resumable) ...'
        $webClient = New-Object System.Net.WebClient
        try {
            $webClient.DownloadFile($Url, $PartialPath)
        } finally {
            $webClient.Dispose()
        }
    }

    if (-not (Test-Path -LiteralPath $PartialPath -PathType Leaf)) {
        throw "Download reported success but '$PartialPath' does not exist."
    }
}

function Expand-CefArchive {
    param(
        [string]$ArchivePath,
        [string]$DestinationRoot
    )

    if (Test-Path -LiteralPath $DestinationRoot) {
        Remove-Item -LiteralPath $DestinationRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null

    Write-Host 'Extracting archive (this can take a minute) ...'
    # Windows ships bsdtar, which understands .tar.bz2 - no 7-Zip required.
    & tar -xf $ArchivePath -C $DestinationRoot
    if ($LASTEXITCODE -ne 0) {
        throw "tar failed with exit code $LASTEXITCODE while extracting '$ArchivePath'."
    }
}

function Assert-CefDistribution {
    param([string]$Root)

    $requiredFiles = @(
        'CMakeLists.txt',
        'cmake\cef_variables.cmake',
        'cmake\cef_macros.cmake',
        'include\cef_app.h',
        'include\cef_client.h',
        'include\cef_life_span_handler.h',
        'libcef_dll\CMakeLists.txt'
    )

    foreach ($relativePath in $requiredFiles) {
        $fullPath = Join-Path $Root $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "The CEF distribution at '$Root' is incomplete: missing '$relativePath'. Make sure the standard (not minimal) package was downloaded."
        }
    }

    $hasReleaseBinaries = Test-Path -LiteralPath (Join-Path $Root 'Release\libcef.lib') -PathType Leaf
    $hasDebugBinaries   = Test-Path -LiteralPath (Join-Path $Root 'Debug\libcef.lib') -PathType Leaf
    if (-not ($hasReleaseBinaries -or $hasDebugBinaries)) {
        throw "The CEF distribution at '$Root' contains neither Release\libcef.lib nor Debug\libcef.lib."
    }
}

# --- Main --------------------------------------------------------------------

Write-Host 'CEF standard distribution fetcher' -ForegroundColor Green
Write-Host "  version : $Version"
Write-Host "  target  : $CefRoot"
Write-Host "  source  : $DownloadUrl"

if (-not $Force -and (Test-CefUpToDate -Root $CefRoot -ExpectedVersion $Version -MarkerPath $VersionMarker)) {
    Write-Step 'Already up to date'
    Write-Host "CEF $Version is already extracted at '$CefRoot'." -ForegroundColor Green
    Write-Host 'Pass -Force to re-download anyway.'
    exit 0
}

if (-not (Test-Path -LiteralPath $CacheDir)) {
    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
}

Write-Step 'Resolving expected SHA1'
$expectedSha1 = $null
try {
    $expectedSha1 = Get-CefArchiveSha1FromIndex -CefVersion $Version -FileName $ArchiveName
} catch {
    if ($Version -eq $DefaultVersion) {
        Write-Warning "Could not resolve the SHA1 from the CEF build index ($($_.Exception.Message)). Falling back to the built-in checksum for $DefaultVersion."
        $expectedSha1 = $DefaultArchiveSha1
    } else {
        throw
    }
}
Write-Host "Expected SHA1: $expectedSha1"

$reuseArchive = $false
if (-not $Force -and (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
    $cachedSha1 = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA1).Hash.ToLowerInvariant()
    if ($cachedSha1 -eq $expectedSha1) {
        Write-Host 'Reusing the cached archive (SHA1 matches).'
        $reuseArchive = $true
    } else {
        Write-Host 'The cached archive does not match the expected SHA1, discarding it.'
        Remove-Item -LiteralPath $ArchivePath -Force
    }
}

if ($reuseArchive) {
    Write-Step 'Download skipped'
} else {
    if ($Force) {
        Remove-Item -LiteralPath $PartialPath -Force -ErrorAction SilentlyContinue
    }

    Write-Step 'Downloading'
    Write-Host 'The archive is roughly 350 MB, please be patient.'
    Receive-CefArchive -Url $DownloadUrl -PartialPath $PartialPath

    Write-Step 'Verifying SHA1'
    $downloadedSha1 = (Get-FileHash -LiteralPath $PartialPath -Algorithm SHA1).Hash.ToLowerInvariant()
    if ($downloadedSha1 -ne $expectedSha1) {
        Remove-Item -LiteralPath $PartialPath -Force -ErrorAction SilentlyContinue
        throw "SHA1 mismatch for '$ArchiveName'.`n  expected: $expectedSha1`n  actual:   $downloadedSha1`nThe incomplete archive was discarded, please run the script again."
    }
    Write-Host "SHA1 OK: $downloadedSha1"

    Move-Item -LiteralPath $PartialPath -Destination $ArchivePath -Force
}

Write-Host "Using archive '$ArchivePath'."

Write-Step 'Extracting'
Expand-CefArchive -ArchivePath $ArchivePath -DestinationRoot $ExtractDir

$extractedDirs = @(Get-ChildItem -LiteralPath $ExtractDir -Directory)
if ($extractedDirs.Count -ne 1) {
    throw "Expected exactly one directory inside '$ExtractDir' but found $($extractedDirs.Count)."
}
$extractedRoot = $extractedDirs[0].FullName
Write-Host "Extracted to '$extractedRoot'."

Write-Step 'Installing into third_party/cef'
if (Test-Path -LiteralPath $CefRoot) {
    Write-Host "Removing the previous CEF tree at '$CefRoot' ..."
    Remove-Item -LiteralPath $CefRoot -Recurse -Force
}
Move-Item -LiteralPath $extractedRoot -Destination $CefRoot

Assert-CefDistribution -Root $CefRoot
Set-Content -LiteralPath (Join-Path $CefRoot 'cef_version.txt') -Value $Version -Encoding ASCII

Write-Step 'Cleaning up'
Remove-Item -LiteralPath $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
if ($KeepArchive) {
    Write-Host "Archive kept at '$ArchivePath'."
} else {
    Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
}

Write-Step 'Done'
Write-Host "CEF $Version is ready." -ForegroundColor Green
Write-Host "CEF_ROOT = $CefRoot"
Write-Host ''
Write-Host 'Next: build the example application with "cd example; flutter run -d windows"; the plugin CMake picks up third_party/cef automatically.'
exit 0
