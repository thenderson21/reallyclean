#requires -Version 7.0
<#
.SYNOPSIS
    Aggressively cleans .NET and .NET MAUI projects on Windows.

.DESCRIPTION
    Modes:

      Default
        Runs dotnet clean, stops .NET build servers, and removes all project
        bin, obj, TestResults, AppPackages, publish, Publish, and artifacts folders.

      Rider
        Removes Rider project/user caches, then performs Deep cleanup.

      VSCode
        Removes Visual Studio and VS Code project/user caches, then performs Deep cleanup.

      VStudio
        Alias for VSCode.

      Deep
        Performs the default cleanup, clears NuGet caches and restored packages,
        removes disposable .NET CLI/workload state, and clears known .NET, MSBuild,
        Roslyn, NuGet, Xamarin, and MAUI temporary files.

    Deep cleanup does NOT uninstall SDKs, runtimes, workloads, Visual Studio,
    Rider, VS Code, Android SDKs, Java, signing certificates, or other toolchains.
    A literal factory-fresh .NET installation requires uninstalling/reinstalling
    those products and is intentionally outside this script.

.PARAMETER Mode
    Default, Rider, VSCode, VStudio, or Deep.

.PARAMETER Force
    Skips the typed CLEAN confirmation required by destructive modes.

.PARAMETER WhatIf
    Shows what would be removed without making changes.

.EXAMPLE
    .\reallyclean.ps1

.EXAMPLE
    .\reallyclean.ps1 Rider

.EXAMPLE
    .\reallyclean.ps1 Deep -WhatIf

.EXAMPLE
    .\reallyclean.ps1 VSCode -Force
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Default', 'Rider', 'VSCode', 'VStudio', 'Deep')]
    [string] $Mode = 'Default',

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = (Get-Location).ProviderPath

function Write-Step {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host "==> $Message"
}

function Write-CleanupWarning {
    param([Parameter(Mandatory)][string] $Message)
    Write-Warning $Message
}

function Test-IsDangerousPath {
    param([Parameter(Mandatory)][string] $Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    $fullPath = [System.IO.Path]::GetFullPath($expanded).TrimEnd('\', '/')

    $dangerous = @(
        [System.IO.Path]::GetPathRoot($fullPath).TrimEnd('\', '/'),
        $HOME.TrimEnd('\', '/'),
        $script:ProjectRoot.TrimEnd('\', '/')
    ) | Where-Object { $_ }

    return $dangerous -contains $fullPath
}

function Remove-SafeItem {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $LiteralPath
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($LiteralPath)

    if (-not (Test-Path -LiteralPath $expanded -Force)) {
        return
    }

    if (Test-IsDangerousPath -Path $expanded) {
        throw "Refusing to remove dangerous path: $expanded"
    }

    if ($PSCmdlet.ShouldProcess($expanded, 'Remove recursively')) {
        Remove-Item -LiteralPath $expanded -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Remove-SafeGlob {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    Get-Item -Path $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-SafeItem -LiteralPath $_.FullName -WhatIf:$WhatIfPreference
    }
}

function Test-DotNetRepository {
    $markers = @(
        '*.sln',
        '*.slnx',
        '*.csproj',
        'global.json',
        'Directory.Build.props',
        'Directory.Build.targets'
    )

    foreach ($marker in $markers) {
        if (Get-ChildItem -LiteralPath $script:ProjectRoot -Filter $marker -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1) {
            return $true
        }
    }

    return $false
}

function Assert-SafeProjectRoot {
    $root = [System.IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd('\', '/')
    $driveRoot = [System.IO.Path]::GetPathRoot($root).TrimEnd('\', '/')

    if ($root -eq $driveRoot) {
        throw 'Do not run this script from a drive root.'
    }

    if ($root -eq $HOME.TrimEnd('\', '/')) {
        throw 'Do not run this script from your home directory.'
    }

    if (-not (Test-DotNetRepository)) {
        throw "No .NET solution or project marker found below: $root"
    }
}

function Confirm-DestructiveMode {
    if ($Mode -eq 'Default' -or $Force -or $WhatIfPreference) {
        return
    }

    Write-Host ''
    Write-Host "Mode '$Mode' removes user-level caches outside this repository."
    Write-Host 'Close Rider, Visual Studio, VS Code, dotnet watch, emulators, and build tools.'
    $answer = Read-Host 'Type CLEAN to continue'

    if ($answer -cne 'CLEAN') {
        throw 'Cleanup cancelled.'
    }
}

function Invoke-DotNet {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [switch] $IgnoreFailure
    )

    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) {
        Write-CleanupWarning 'dotnet was not found; skipping dotnet command.'
        return
    }

    $display = 'dotnet ' + ($Arguments -join ' ')
    if ($PSCmdlet.ShouldProcess($display, 'Execute')) {
        & $dotnet.Source @Arguments
        if ($LASTEXITCODE -ne 0 -and -not $IgnoreFailure) {
            throw "Command failed with exit code ${LASTEXITCODE}: $display"
        }
    }
}

function Stop-DotNetBuildServers {
    Write-Step 'Stopping .NET/MSBuild build servers'
    Invoke-DotNet -Arguments @('build-server', 'shutdown') -IgnoreFailure
}

function Invoke-DotNetClean {
    Write-Step 'Running dotnet clean'

    $targets = @(
        Get-ChildItem -LiteralPath $script:ProjectRoot -File -Filter '*.slnx' -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $script:ProjectRoot -File -Filter '*.sln'  -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $script:ProjectRoot -File -Filter '*.csproj' -ErrorAction SilentlyContinue
    )

    if ($targets.Count -gt 0) {
        foreach ($target in $targets) {
            Invoke-DotNet -Arguments @('clean', $target.FullName, '--nologo') -IgnoreFailure
        }
    }
    else {
        Invoke-DotNet -Arguments @('clean', '--nologo') -IgnoreFailure
    }
}

function Remove-ProjectOutput {
    Write-Step 'Removing generated project output'

    $directoryNames = @(
        'bin',
        'obj',
        'TestResults',
        'AppPackages',
        'Publish',
        'publish',
        'artifacts'
    )

    Get-ChildItem -LiteralPath $script:ProjectRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notlike '*\.git\*' -and
            $directoryNames -contains $_.Name
        } |
        Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object {
            Remove-SafeItem -LiteralPath $_.FullName -WhatIf:$WhatIfPreference
        }

    $localPaths = @(
        (Join-Path $script:ProjectRoot '.vs'),
        (Join-Path $script:ProjectRoot '.idea'),
        (Join-Path $script:ProjectRoot '.ionide'),
        (Join-Path $script:ProjectRoot '.fake'),
        (Join-Path $script:ProjectRoot '.paket'),
        (Join-Path $script:ProjectRoot '.dotnet'),
        (Join-Path $script:ProjectRoot '.nuget'),
        (Join-Path $script:ProjectRoot '.local'),
        (Join-Path $script:ProjectRoot '.cache'),
        (Join-Path $script:ProjectRoot '.maui'),
        (Join-Path $script:ProjectRoot '.xamarin'),
        (Join-Path $script:ProjectRoot '.mono'),
        (Join-Path $script:ProjectRoot '.DS_Store'),
        (Join-Path $script:ProjectRoot '.vscode\.browse.VC.db'),
        (Join-Path $script:ProjectRoot '.vscode\ipch'),
        (Join-Path $script:ProjectRoot '.vscode\.csharp')
    )

    foreach ($path in $localPaths) {
        Remove-SafeItem -LiteralPath $path -WhatIf:$WhatIfPreference
    }
}

function Clear-NuGetAndDotNetState {
    Write-Step 'Clearing NuGet caches and restored packages'
    Invoke-DotNet -Arguments @('nuget', 'locals', 'all', '--clear') -IgnoreFailure

    $nugetPaths = @(
        (Join-Path $HOME '.nuget\packages'),
        (Join-Path $env:LOCALAPPDATA 'NuGet\v3-cache'),
        (Join-Path $env:LOCALAPPDATA 'NuGet\plugins-cache'),
        (Join-Path $env:LOCALAPPDATA 'NuGet\Cache'),
        (Join-Path $env:TEMP 'NuGetScratch')
    )

    foreach ($path in $nugetPaths) {
        Remove-SafeItem -LiteralPath $path -WhatIf:$WhatIfPreference
    }

    Write-Step 'Clearing disposable .NET CLI state'

    $dotnetPaths = @(
        (Join-Path $HOME '.dotnet\.store'),
        (Join-Path $HOME '.dotnet\store'),
        (Join-Path $HOME '.dotnet\toolResolverCache'),
        (Join-Path $HOME '.dotnet\sdk-advertising'),
        (Join-Path $HOME '.dotnet\workloads'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\sdk-advertising'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\workloads')
    )

    foreach ($path in $dotnetPaths) {
        Remove-SafeItem -LiteralPath $path -WhatIf:$WhatIfPreference
    }

    Remove-SafeGlob -Path (Join-Path $HOME '.dotnet\.workloadAdvertisingManifestSentinel*') -WhatIf:$WhatIfPreference
    Remove-SafeGlob -Path (Join-Path $HOME '.dotnet\.workloadSetUpdateSentinel*') -WhatIf:$WhatIfPreference
    Remove-SafeItem -LiteralPath (Join-Path $HOME '.dotnet\.firstUseSentinel') -WhatIf:$WhatIfPreference
    Remove-SafeItem -LiteralPath (Join-Path $HOME '.dotnet\.telemetry') -WhatIf:$WhatIfPreference

    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($dotnet) {
        $help = & $dotnet.Source workload clean --help 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Step 'Removing orphaned workload components'
            Invoke-DotNet -Arguments @('workload', 'clean') -IgnoreFailure
        }
    }
}

function Clear-DotNetTemporaryFiles {
    Write-Step 'Removing known .NET, NuGet, MSBuild, Roslyn, Xamarin, and MAUI temporary files'

    $roots = @(
        $env:TEMP,
        $env:TMP,
        (Join-Path $env:LOCALAPPDATA 'Temp')
    ) | Where-Object { $_ } | Select-Object -Unique

    $patterns = @(
        'NuGetScratch*',
        'MSBuildTemp*',
        'VBCSCompiler*',
        'Roslyn*',
        '.NETCoreApp*',
        'dotnet-*',
        'clr-debug-pipe-*',
        'CoreFxPipe_*',
        'xamarin-*',
        'maui-*',
        'MonoDevelop-*',
        'servicehub-*',
        'VSFeedbackIntelliCodeLogs*'
    )

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        foreach ($pattern in $patterns) {
            Get-ChildItem -LiteralPath $root -Filter $pattern -Force -ErrorAction SilentlyContinue |
                ForEach-Object {
                    Remove-SafeItem -LiteralPath $_.FullName -WhatIf:$WhatIfPreference
                }
        }
    }
}

function Clear-MauiBuildState {
    Write-Step 'Removing user-level MAUI/Xamarin build caches'

    $paths = @(
        (Join-Path $env:LOCALAPPDATA 'Xamarin'),
        (Join-Path $env:APPDATA 'Xamarin'),
        (Join-Path $env:LOCALAPPDATA 'Temp\Xamarin'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Xamarin'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\MAUI'),
        (Join-Path $HOME '.xamarin'),
        (Join-Path $HOME '.maui')
    )

    foreach ($path in $paths) {
        Remove-SafeItem -LiteralPath $path -WhatIf:$WhatIfPreference
    }
}

function Clear-RiderCaches {
    Write-Step 'Removing Rider caches for all installed versions'
    Write-CleanupWarning 'This removes Rider indexes, logs, generated caches, and project .idea state.'

    $paths = @(
        (Join-Path $script:ProjectRoot '.idea'),
        (Join-Path $env:LOCALAPPDATA 'JetBrains\Rider*\caches'),
        (Join-Path $env:LOCALAPPDATA 'JetBrains\Rider*\index'),
        (Join-Path $env:LOCALAPPDATA 'JetBrains\Rider*\log'),
        (Join-Path $env:LOCALAPPDATA 'JetBrains\Rider*\resharper-host'),
        (Join-Path $env:LOCALAPPDATA 'JetBrains\Rider*\LocalHistory')
    )

    foreach ($path in $paths) {
        if ($path -like '*`**') {
            Remove-SafeGlob -Path $path -WhatIf:$WhatIfPreference
        }
        else {
            Remove-SafeGlob -Path $path -WhatIf:$WhatIfPreference
        }
    }
}

function Clear-VisualStudioAndCodeCaches {
    Write-Step 'Removing Visual Studio and VS Code caches'
    Write-CleanupWarning 'This removes caches, indexes, logs, and workspace storage—not settings or extensions.'

    $projectPaths = @(
        (Join-Path $script:ProjectRoot '.vs'),
        (Join-Path $script:ProjectRoot '.vscode\.browse.VC.db'),
        (Join-Path $script:ProjectRoot '.vscode\ipch'),
        (Join-Path $script:ProjectRoot '.vscode\.csharp')
    )

    foreach ($path in $projectPaths) {
        Remove-SafeItem -LiteralPath $path -WhatIf:$WhatIfPreference
    }

    $visualStudioPatterns = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\VisualStudio\*\ComponentModelCache'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\VisualStudio\*\ImageLibrary'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\VisualStudio\*\Cache'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\VSCommon\*\MEFCacheBackup'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\VisualStudio\*\Roslyn'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\VisualStudio\*\Designer'),
        (Join-Path $env:TEMP 'servicehub'),
        (Join-Path $env:TEMP 'VSFeedbackIntelliCodeLogs')
    )

    foreach ($path in $visualStudioPatterns) {
        Remove-SafeGlob -Path $path -WhatIf:$WhatIfPreference
    }

    $codeRoot = Join-Path $env:APPDATA 'Code'
    $codePaths = @(
        (Join-Path $codeRoot 'Cache'),
        (Join-Path $codeRoot 'CachedData'),
        (Join-Path $codeRoot 'CachedExtensions'),
        (Join-Path $codeRoot 'CachedExtensionVSIXs'),
        (Join-Path $codeRoot 'Code Cache'),
        (Join-Path $codeRoot 'GPUCache'),
        (Join-Path $codeRoot 'logs'),
        (Join-Path $codeRoot 'User\workspaceStorage')
    )

    foreach ($path in $codePaths) {
        Remove-SafeItem -LiteralPath $path -WhatIf:$WhatIfPreference
    }
}

function Invoke-DeepClean {
    Stop-DotNetBuildServers
    Invoke-DotNetClean
    Remove-ProjectOutput
    Clear-NuGetAndDotNetState
    Clear-DotNetTemporaryFiles
    Clear-MauiBuildState
}

try {
    if ($Mode -eq 'VStudio') {
        $Mode = 'VSCode'
    }

    Assert-SafeProjectRoot
    Confirm-DestructiveMode

    Write-Step "Repository: $script:ProjectRoot"
    Write-Step "Mode: $Mode"

    switch ($Mode) {
        'Default' {
            Stop-DotNetBuildServers
            Invoke-DotNetClean
            Remove-ProjectOutput
        }

        'Deep' {
            Invoke-DeepClean
        }

        'Rider' {
            Clear-RiderCaches
            Invoke-DeepClean
        }

        'VSCode' {
            Clear-VisualStudioAndCodeCaches
            Invoke-DeepClean
        }

        default {
            throw "Unsupported cleanup mode: $Mode"
        }
    }

    Write-Step 'Cleanup complete'

    if ($Mode -ne 'Default') {
        Write-Host ''
        Write-Host 'The next build will restore packages, regenerate indexes,'
        Write-Host 'and may re-download workload advertising or manifest data.'
        Write-Host ''
        Write-Host 'Suggested verification:'
        Write-Host '  dotnet --info'
        Write-Host '  dotnet workload list'
        Write-Host '  dotnet restore'
    }
}
catch {
    Write-Error $_
    exit 1
}
