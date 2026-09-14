#Requires -Version 5.1
<#
.SYNOPSIS
    Single source of truth for this repository's developer commands.

.DESCRIPTION
    A self-healing command dispatcher for YoutubeDownloader. Every run/build
    command verifies its prerequisites first and installs whatever is missing,
    so a fresh clone on a bare machine runs with zero manual steps:

        ./dev.ps1 start-app

    Self-healing covers two layers:
      1. The .NET SDK itself (installed via winget if absent or too old).
      2. NuGet packages (dotnet restore).

    This script is the ONLY place project commands are defined. Editor tasks
    (.vscode/tasks.json) and CI must call into it - never duplicate command
    logic there.

.EXAMPLE
    ./dev.ps1 install-deps    # install the SDK (if needed) and restore packages
    ./dev.ps1 start-app       # run the desktop app (self-heals first)
    ./dev.ps1 build-project   # build the solution in Release
    ./dev.ps1 publish-app     # produce a self-contained build for this machine
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
    'format-code'   { Invoke-FormatCode }
    'clean-all'     { Invoke-CleanAll }
    'help'          { Show-Help }
    default         { Write-Err "Unknown command: $Command"; Show-Help; exit 1 }
}
