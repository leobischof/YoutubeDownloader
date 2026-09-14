#Requires -Version 5.1
<#
.SYNOPSIS
    Single source of truth for this repository's developer commands.

.DESCRIPTION
    A self-healing command dispatcher for YoutubeDownloader. Every run/build
    command verifies its prerequisites first and installs whatever is missing,
    so a fresh clone on a bare machine runs with zero manual steps:

        ./dev.ps1 start-app

    Self-healing covers three layers:
      1. The .NET SDK itself (installed via winget if absent or too old).
      2. NuGet packages (dotnet restore).
      3. The Android workload, SDK and JDK - only for the APK commands, so a
         desktop-only contributor never downloads the Android toolchain.

    This script is the ONLY place project commands are defined. Editor tasks
    (.vscode/tasks.json) and CI must call into it - never duplicate command
    logic there.

.EXAMPLE
    ./dev.ps1 install-deps    # install the SDK (if needed) and restore packages
    ./dev.ps1 start-app       # run the desktop app (self-heals first)
    ./dev.ps1 build-project   # build the solution in Release
    ./dev.ps1 publish-app     # produce a self-contained build for this machine
    ./dev.ps1 build-apk       # build a sideloadable Android APK
    ./dev.ps1 install-apk     # push that APK onto a connected device
    ./dev.ps1 help            # list all commands
#>

[CmdletBinding()]
param(
    # The command to run (see Show-Help for the list).
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    # Remaining args forwarded to the underlying tool
    # (e.g. ./dev.ps1 publish-app -- --runtime linux-x64).
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Under StrictMode an unbound ValueFromRemainingArguments parameter is $null, and
# splatting $null into a native command throws. Normalise to an empty array once.
if ($null -eq $Rest) { $Rest = @() }

# Operate from the repo root (this script's directory) regardless of caller CWD.
$RepoRoot = $PSScriptRoot
Set-Location $RepoRoot

# The app project is the entrypoint; Core is a referenced library.
$AppProject = Join-Path $RepoRoot 'YoutubeDownloader'
$AndroidProject = Join-Path $RepoRoot 'YoutubeDownloader.Android'

# Neither ANDROID_HOME nor JAVA_HOME is set by the workload's provisioning step, so the
# locations are pinned here and passed to every Android build explicitly.
$AndroidSdkDir = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$AndroidJdkDir = Join-Path $env:LOCALAPPDATA 'Android\jdk'

# The API level net10.0-android compiles against; a build fails with XA5207 without it.
$AndroidApiLevel = 36

# --- Logging gateway (single source of truth for output formatting) ----------
function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "[ok] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[!]  $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "[x]  $Message" -ForegroundColor Red }

# Run a native command and fail loudly (with context) on a non-zero exit code,
# so failures propagate to CI and editor tasks instead of being swallowed.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$What = 'command'
    )
    # Many CLIs write progress/info to stderr. Under $ErrorActionPreference = 'Stop',
    # Windows PowerShell 5.1 turns native-command stderr into a terminating error even
    # when the tool exits 0. Relax to 'Continue' for the native call and treat the
    # EXIT CODE as the single source of truth for success/failure.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Action
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)." }
}

# --- Layer 1 self-healing: the .NET SDK --------------------------------------

# global.json pins the SDK feature band; keep this in sync with it.
$RequiredSdkMajor = 10

function Test-DotnetInstalled {
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) { return $false }
    # `dotnet --list-sdks` prints one "<version> [<path>]" line per installed SDK.
    $sdks = & dotnet --list-sdks 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    foreach ($line in $sdks) {
        if ($line -match '^(\d+)\.') {
            if ([int]$Matches[1] -ge $RequiredSdkMajor) { return $true }
        }
    }
    return $false
}

function Install-Dotnet {
    Write-Step "Installing .NET SDK $RequiredSdkMajor"
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw ".NET SDK $RequiredSdkMajor is required but winget is unavailable. " +
              "Install it manually from https://dotnet.microsoft.com/download and re-run."
    }
    Invoke-Native -What 'winget install dotnet-sdk' -Action {
        winget install --id "Microsoft.DotNet.SDK.$RequiredSdkMajor" `
            --exact --silent --accept-package-agreements --accept-source-agreements
    }
    # winget updates the machine PATH, but not this already-running process.
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"
    if (-not (Test-DotnetInstalled)) {
        throw ".NET SDK installed but 'dotnet' is still not resolvable. Open a new terminal and re-run."
    }
    Write-Ok ".NET SDK $RequiredSdkMajor installed"
}

# --- Layer 2 self-healing: NuGet packages ------------------------------------

function Test-PackagesRestored {
    # Restore writes project.assets.json into each project's obj/ directory.
    return (Test-Path (Join-Path $AppProject 'obj\project.assets.json'))
}

function Invoke-InstallDeps {
    if (-not (Test-DotnetInstalled)) { Install-Dotnet }
    Write-Step 'Restoring NuGet packages'
    Invoke-Native -What 'install-deps' -Action { dotnet restore }
    Write-Ok 'Dependencies installed'
}

# Self-healing guard: every run/build command calls this first.
function Confirm-Deps {
    if (-not (Test-DotnetInstalled)) {
        Write-Warn '.NET SDK missing or too old - installing now'
        Install-Dotnet
    }
    if (-not (Test-PackagesRestored)) {
        Write-Warn 'NuGet packages not restored - restoring now'
        Invoke-Native -What 'restore' -Action { dotnet restore }
    }
}

# --- Layer 3 self-healing: the Android toolchain -----------------------------
# Only the APK commands need this, so it is kept out of Confirm-Deps: a desktop-only
# contributor should never be made to download ~2 GB of Android SDK.

function Test-AndroidWorkloadInstalled {
    $workloads = & dotnet workload list 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    # The table lists one workload id per row; match the id at the start of a line.
    return [bool]($workloads | Where-Object { $_ -match '^\s*android\s' })
}

function Test-AndroidSdkInstalled {
    $androidJar = Join-Path $AndroidSdkDir "platforms\android-$AndroidApiLevel\android.jar"
    $java = Join-Path $AndroidJdkDir 'bin\java.exe'
    return (Test-Path $androidJar) -and (Test-Path $java)
}

function Install-AndroidWorkload {
    Write-Step 'Installing the .NET Android workload (~1 GB)'
    Invoke-Native -What 'workload install android' -Action {
        dotnet workload install android --skip-manifest-update
    }
    Write-Ok 'Android workload installed'
}

function Install-AndroidSdk {
    Write-Step "Installing the Android SDK (API $AndroidApiLevel) and JDK"
    # The workload ships this target; it provisions both the SDK and a JDK, so neither
    # Android Studio nor a manual JDK install is needed.
    Invoke-Native -What 'InstallAndroidDependencies' -Action {
        dotnet build $AndroidProject `
            -t:InstallAndroidDependencies `
            -f net10.0-android `
            -p:AndroidSdkDirectory=$AndroidSdkDir `
            -p:JavaSdkDirectory=$AndroidJdkDir `
            -p:AcceptAndroidSDKLicenses=True `
            -p:DownloadFFmpegAndroid=false `
            -v:minimal
    }
    Write-Ok 'Android SDK and JDK installed'
}

# Self-healing guard for the APK commands.
function Confirm-AndroidDeps {
    Confirm-Deps

    if (-not (Test-AndroidWorkloadInstalled)) {
        Write-Warn 'Android workload missing - installing now (this takes a few minutes)'
        Install-AndroidWorkload
    }
    if (-not (Test-AndroidSdkInstalled)) {
        Write-Warn 'Android SDK or JDK missing - installing now (this takes a few minutes)'
        Install-AndroidSdk
    }
}

# Every Android build needs these; kept in one place so they cannot drift apart.
function Get-AndroidBuildArgs {
    return @(
        "-p:AndroidSdkDirectory=$AndroidSdkDir",
        "-p:JavaSdkDirectory=$AndroidJdkDir"
    )
}

# --- Commands ----------------------------------------------------------------
# One function per command (single concern). Descriptive verb-noun names.

# CSharpier.MsBuild rewrites source files as part of a normal build. Bypass it for
# plain build/run so a build never silently reformats the working tree; `format-code`
# is the explicit, opt-in way to apply formatting (this mirrors CI).
$SkipFormatter = '-p:CSharpier_Bypass=true'

function Invoke-StartApp {
    Confirm-Deps
    Write-Step 'Starting YoutubeDownloader (Debug)'
    Invoke-Native -What 'start-app' -Action {
        dotnet run --project $AppProject $SkipFormatter @Rest
    }
}

function Invoke-BuildProject {
    Confirm-Deps
    Write-Step 'Building solution (Release)'
    Invoke-Native -What 'build-project' -Action {
        dotnet build --configuration Release $SkipFormatter @Rest
    }
}

function Invoke-PublishApp {
    Confirm-Deps
    # Default to this machine's RID so `publish-app` alone produces a runnable build;
    # override with e.g. ./dev.ps1 publish-app -- --runtime linux-x64
    $outputDir = Join-Path $AppProject 'bin\publish'
    Write-Step "Publishing self-contained app to $outputDir"
    Invoke-Native -What 'publish-app' -Action {
        dotnet publish $AppProject `
            --configuration Release `
            --self-contained `
            --output $outputDir `
            $SkipFormatter @Rest
    }
    Write-Ok "Published to $outputDir"
}

function Invoke-FormatCode {
    Confirm-Deps
    # Applies CSharpier formatting in place - same target CI verifies against.
    Write-Step 'Formatting sources with CSharpier'
    Invoke-Native -What 'format-code' -Action {
        dotnet build -t:CSharpierFormat --configuration Release --no-restore @Rest
    }
    Write-Ok 'Formatting applied'
}

function Invoke-BuildApk {
    Confirm-AndroidDeps

    # Release by default: that is the build you would actually put on a phone. Override
    # with e.g. ./dev.ps1 build-apk -- -c Debug
    Write-Step 'Building Android APK (Release)'
    $androidArgs = Get-AndroidBuildArgs
    Invoke-Native -What 'build-apk' -Action {
        dotnet build $AndroidProject -c Release $SkipFormatter @androidArgs @Rest
    }

    $apk = Get-ChildItem -Path (Join-Path $AndroidProject 'bin') -Filter '*-Signed.apk' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    # A green build with no APK means the packaging step was skipped; surface that rather
    # than letting it look like success.
    if (-not $apk) { throw 'build-apk reported success but produced no signed APK.' }

    Write-Ok "APK: $($apk.FullName)"
    Write-Host (
        '      {0:N0} MB, signed with the Android debug key - enable "install from unknown sources" to sideload' -f ($apk.Length / 1MB)
    ) -ForegroundColor DarkGray
}

function Invoke-InstallApk {
    $adb = Join-Path $AndroidSdkDir 'platform-tools\adb.exe'
    if (-not (Test-Path $adb)) {
        throw "adb not found at $adb. Run ./dev.ps1 build-apk first to provision the Android SDK."
    }

    # On first use adb forks a background daemon that inherits stdout. If that output is a
    # captured pipe - as it is below, and in any editor task - the pipe never closes and the
    # call blocks. Start the daemon first with its output pinned to files instead, so it
    # inherits file handles rather than the pipe.
    # This step alone can take over a minute the first time (virus scanners inspect the
    # daemon); afterwards it returns instantly.
    Write-Step 'Starting the adb server'
    $adbOut = [System.IO.Path]::GetTempFileName()
    $adbErr = [System.IO.Path]::GetTempFileName()
    try {
        Start-Process -FilePath $adb -ArgumentList 'start-server' -NoNewWindow -Wait `
            -RedirectStandardOutput $adbOut -RedirectStandardError $adbErr
    } finally {
        Remove-Item $adbOut, $adbErr -Force -ErrorAction SilentlyContinue
    }

    # Only devices in the 'device' state can be installed to; 'unauthorized' means the USB
    # debugging prompt on the phone has not been accepted yet.
    $devices = @(& $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\sdevice$' })
    if ($devices.Count -eq 0) {
        throw 'No authorised Android device found. Connect one with USB debugging enabled and accept the prompt on the device.'
    }

    $apk = Get-ChildItem -Path (Join-Path $AndroidProject 'bin') -Filter '*-Signed.apk' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $apk) {
        Write-Warn 'No APK built yet - building one now'
        Invoke-BuildApk
        $apk = Get-ChildItem -Path (Join-Path $AndroidProject 'bin') -Filter '*-Signed.apk' -Recurse |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }

    Write-Step "Installing $($apk.Name) to the connected device"
    Invoke-Native -What 'install-apk' -Action { & $adb install -r $apk.FullName }
    Write-Ok 'Installed'
}

function Invoke-CleanAll {
    Write-Step 'Cleaning build artifacts'
    # Remove bin/ and obj/ from every project rather than a hardcoded list, so new
    # projects are covered automatically.
    $stale = @(Get-ChildItem -Path $RepoRoot -Include 'bin', 'obj' -Directory -Recurse -ErrorAction SilentlyContinue)

    # Delete deepest paths first: a nested obj/ inside a bin/ would otherwise be
    # enumerated after its parent was already removed, turning into a spurious error.
    $stale = $stale | Sort-Object { $_.FullName.Length } -Descending

    # Collect failures instead of swallowing them - a clean that silently left files
    # behind sends you debugging a stale build later.
    $failed = @()
    foreach ($dir in $stale) {
        if (-not (Test-Path $dir.FullName)) { continue }
        try {
            Remove-Item -Recurse -Force $dir.FullName -ErrorAction Stop
        } catch {
            $failed += $dir.FullName
        }
    }

    if ($failed.Count -gt 0) {
        foreach ($path in $failed) { Write-Warn "Could not remove: $path" }
        throw "clean-all could not remove $($failed.Count) director$(if ($failed.Count -eq 1) { 'y' } else { 'ies' }) (file in use?)."
    }
    Write-Ok 'Clean complete'
}

# --- Help --------------------------------------------------------------------
# Each command prints as: descriptive-name + an indented subtitle line.
function Write-Cmd {
    param([string]$Name, [string]$Subtitle)
    Write-Host ("  {0}" -f $Name) -ForegroundColor White
    Write-Host ("      {0}" -f $Subtitle) -ForegroundColor DarkGray
}

function Show-Help {
    Write-Host ''
    Write-Host 'dev.ps1 - repository command dispatcher' -ForegroundColor White
    Write-Host 'Usage: ./dev.ps1 <command> [-- args...]' -ForegroundColor DarkGray
    Write-Host ''
    Write-Cmd 'install-deps'   'Install the .NET SDK if missing, then restore NuGet packages'
    Write-Cmd 'start-app'      'Run the desktop app (installs prerequisites first)'
    Write-Cmd 'build-project'  'Build the whole solution in Release'
    Write-Cmd 'publish-app'    'Produce a self-contained build under YoutubeDownloader/bin/publish'
    Write-Cmd 'build-apk'      'Build a sideloadable Android APK (installs the Android SDK if needed)'
    Write-Cmd 'install-apk'    'Install the built APK onto a connected Android device via adb'
    Write-Cmd 'format-code'    'Apply CSharpier formatting (what CI checks)'
    Write-Cmd 'clean-all'      'Delete every bin/ and obj/ directory'
    Write-Cmd 'help'           'Show this help'
    Write-Host ''
}

# --- Dispatcher (keep entries in sync with the functions above) --------------
switch ($Command.ToLowerInvariant()) {
    'install-deps'  { Invoke-InstallDeps }
    'start-app'     { Invoke-StartApp }
    'build-project' { Invoke-BuildProject }
    'publish-app'   { Invoke-PublishApp }
    'build-apk'     { Invoke-BuildApk }
    'install-apk'   { Invoke-InstallApk }
    'format-code'   { Invoke-FormatCode }
    'clean-all'     { Invoke-CleanAll }
    'help'          { Show-Help }
    default         { Write-Err "Unknown command: $Command"; Show-Help; exit 1 }
}
