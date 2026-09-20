# Wires the window-placement tool into a global OpenCode installation:
#   1. Appends/replaces a managed block in <config>/AGENTS.md so agents route GUI
#      launches through the launcher.
#   2. Creates the /other-screen slash command.
#
# Idempotent: safe to run repeatedly. The tool itself stays in this repository;
# only the global OpenCode config is touched.

[CmdletBinding()]
param(
    [string] $OpenCodeConfigDirectory = (Join-Path $HOME '.config/opencode'),

    [switch] $AddProfileFunction,

    [switch] $SkipVirtualDesktopModule
)

$ErrorActionPreference = 'Stop'

$toolDirectory = $PSScriptRoot
$launcher = Join-Path $toolDirectory 'Start-OnOtherScreen.cmd'
if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Launcher not found at '$launcher'."
}

$commandsDirectory = Join-Path $OpenCodeConfigDirectory 'commands'
New-Item -ItemType Directory -Force -Path $commandsDirectory | Out-Null

$startMarker = '<!-- opencode-tools:window-placement:start -->'
$endMarker = '<!-- opencode-tools:window-placement:end -->'

$agentBlock = @(
    $startMarker
    '# Window placement'
    ''
    '- When you start a GUI application or a dev server that opens a GUI window, launch it'
    '  through the window-placement launcher so the window opens on the virtual desktop where'
    '  OpenCode is running and on a monitor other than the one OpenCode is on:'
    ''
    ('  `' + $launcher + '` <command> [arguments]')
    '- The launcher handles both the virtual desktop and the monitor placement; do not move'
    '  the window anywhere else yourself.'
    ''
    $endMarker
) -join "`r`n"

$agentsPath = Join-Path $OpenCodeConfigDirectory 'AGENTS.md'
if (Test-Path -LiteralPath $agentsPath) {
    $content = Get-Content -LiteralPath $agentsPath -Raw
    if ($content.Contains($startMarker) -and $content.Contains($endMarker)) {
        $pattern = [regex]::Escape($startMarker) + '[\s\S]*?' + [regex]::Escape($endMarker)
        $content = [regex]::Replace($content, $pattern, [System.Text.RegularExpressions.MatchEvaluator] { param($match) $agentBlock })
    } else {
        $content = $content.TrimEnd() + "`r`n`r`n" + $agentBlock + "`r`n"
    }
    Set-Content -LiteralPath $agentsPath -Value $content -Encoding utf8 -NoNewline
    Write-Host "Updated $agentsPath"
} else {
    Set-Content -LiteralPath $agentsPath -Value ($agentBlock + "`r`n") -Encoding utf8 -NoNewline
    Write-Host "Created $agentsPath"
}

$commandPath = Join-Path $commandsDirectory 'other-screen.md'
$commandContent = @"
---
description: Run a command with its GUI window on the monitor other than OpenCode's
---

Start the following through the window-placement launcher so its GUI window opens on a monitor other than the one OpenCode is running on:

& "$launcher" `$ARGUMENTS
"@
Set-Content -LiteralPath $commandPath -Value $commandContent -Encoding utf8 -NoNewline
Write-Host "Wrote $commandPath"

if ($AddProfileFunction) {
    $profilePath = $PROFILE
    $profileDirectory = Split-Path -Parent $profilePath
    if (-not (Test-Path -LiteralPath $profileDirectory)) {
        New-Item -ItemType Directory -Force -Path $profileDirectory | Out-Null
    }

    $profileStart = '# opencode-tools:window-placement:start'
    $profileEnd = '# opencode-tools:window-placement:end'
    $functionBlock = @(
        $profileStart
        'function Start-OnOtherScreen {'
        ('    & "' + $launcher + '" @args')
        '}'
        $profileEnd
    ) -join "`r`n"

    if (Test-Path -LiteralPath $profilePath) {
        $profileContent = Get-Content -LiteralPath $profilePath -Raw
    } else {
        $profileContent = ''
    }

    if ($profileContent.Contains($profileStart) -and $profileContent.Contains($profileEnd)) {
        $pattern = [regex]::Escape($profileStart) + '[\s\S]*?' + [regex]::Escape($profileEnd)
        $profileContent = [regex]::Replace($profileContent, $pattern, [System.Text.RegularExpressions.MatchEvaluator] { param($match) $functionBlock })
    } else {
        $profileContent = $profileContent.TrimEnd() + "`r`n`r`n" + $functionBlock + "`r`n"
    }

    Set-Content -LiteralPath $profilePath -Value $profileContent -Encoding utf8 -NoNewline
    Write-Host "Updated PowerShell profile $profilePath"
}

function Get-UserModuleDirectory {
    $edition = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'WindowsPowerShell' }
    return Join-Path $HOME ("Documents\{0}\Modules" -f $edition)
}

function Ensure-VirtualDesktopModule {
    if (Get-Module -ListAvailable -Name VirtualDesktop) {
        Write-Host 'VirtualDesktop module is already installed.'
        return
    }

    try {
        Install-Module -Name VirtualDesktop -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Write-Host 'Installed the VirtualDesktop module from PSGallery.'
        return
    } catch {
        Write-Warning "Install-Module failed ($($_.Exception.Message)); downloading the module directly."
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $temporaryDirectory = Join-Path $env:TEMP ('VirtualDesktop-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $temporaryDirectory | Out-Null
        $packagePath = Join-Path $temporaryDirectory 'VirtualDesktop.zip'
        Invoke-WebRequest -Uri 'https://www.powershellgallery.com/api/v2/package/VirtualDesktop' -OutFile $packagePath -UseBasicParsing
        $expandedPath = Join-Path $temporaryDirectory 'expanded'
        Expand-Archive -Path $packagePath -DestinationPath $expandedPath -Force

        $moduleDirectory = Join-Path (Get-UserModuleDirectory) 'VirtualDesktop'
        New-Item -ItemType Directory -Force -Path $moduleDirectory | Out-Null
        foreach ($file in @('VirtualDesktop.psd1', 'VirtualDesktop.psm1', 'VirtualDesktop.ps1', 'functions.cat')) {
            $source = Join-Path $expandedPath $file
            if (Test-Path -LiteralPath $source) {
                Copy-Item -LiteralPath $source -Destination $moduleDirectory -Force
            }
        }

        Remove-Item -Recurse -Force $temporaryDirectory -ErrorAction SilentlyContinue
        Write-Host "Installed the VirtualDesktop module to $moduleDirectory"
    } catch {
        Write-Warning "Could not install the VirtualDesktop module: $($_.Exception.Message)"
        Write-Warning 'The tool will still move windows between monitors, but not between virtual desktops.'
    }
}

if (-not $SkipVirtualDesktopModule) {
    Ensure-VirtualDesktopModule
}

Write-Host ''
Write-Host 'Done. Restart the OpenCode service or start a new session to pick up the changes.'
