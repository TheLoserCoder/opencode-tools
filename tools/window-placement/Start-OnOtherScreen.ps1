# Runs a command and places the GUI window(s) it opens on a monitor other than the
# monitor that currently has focus (normally the OpenCode terminal).
#
# The command keeps the current console attached, so its stdout/stderr stay visible
# in the terminal that launched it.
#
# Usage:
#   .\Start-OnOtherScreen.ps1 pnpm dev
#   .\Start-OnOtherScreen.ps1 -TargetScreen 2 notepad
#   .\Start-OnOtherScreen.cmd pnpm dev

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true, ValueFromRemainingArguments = $true)]
    [string[]] $Command,

    [string] $WorkingDirectory = (Get-Location).Path,

    [string] $TargetScreen = 'other',

    [int] $TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'WindowInterop.ps1')
Add-Type -AssemblyName System.Windows.Forms | Out-Null

[OpenCodeTools.WindowInterop]::SetProcessDPIAware() | Out-Null

function Get-ScreenContainingPoint {
    param([int] $X, [int] $Y)

    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $bounds = $screen.Bounds
        if ($X -ge $bounds.Left -and $X -lt $bounds.Right -and $Y -ge $bounds.Top -and $Y -lt $bounds.Bottom) {
            return $screen
        }
    }

    return $null
}

function Get-ActiveScreen {
    $handle = [OpenCodeTools.WindowInterop]::GetForegroundWindow()
    if ($handle -ne [IntPtr]::Zero) {
        $rect = New-Object OpenCodeTools.Rect
        if ([OpenCodeTools.WindowInterop]::GetWindowRect($handle, [ref] $rect)) {
            $centerX = [int] (($rect.Left + $rect.Right) / 2)
            $centerY = [int] (($rect.Top + $rect.Bottom) / 2)
            $screen = Get-ScreenContainingPoint -X $centerX -Y $centerY
            if ($null -ne $screen) {
                return $screen
            }
        }
    }

    return [System.Windows.Forms.Screen]::PrimaryScreen
}

function Resolve-TargetScreen {
    param(
        [System.Windows.Forms.Screen] $ActiveScreen,
        [string] $Selector
    )

    $screens = @([System.Windows.Forms.Screen]::AllScreens)
    if ($screens.Count -le 1) {
        return $null
    }

    if ($Selector -ieq 'other') {
        $candidates = @($screens | Where-Object { $_.DeviceName -ne $ActiveScreen.DeviceName })
        if ($candidates.Count -eq 0) {
            return $null
        }

        $nonPrimary = @($candidates | Where-Object { -not $_.Primary })
        if ($nonPrimary.Count -gt 0) {
            return $nonPrimary[0]
        }

        return $candidates[0]
    }

    $index = 0
    if ([int]::TryParse($Selector, [ref] $index)) {
        if ($index -ge 1 -and $index -le $screens.Count) {
            return $screens[$index - 1]
        }
        throw "TargetScreen '$Selector' is out of range (1..$($screens.Count))."
    }

    $match = @($screens | Where-Object { $_.DeviceName -ieq $Selector })
    if ($match.Count -eq 0) {
        throw "TargetScreen '$Selector' was not found."
    }

    return $match[0]
}

function Quote-CommandLineArgument {
    param([string] $Value)

    if ($Value -match '\s') {
        return '"' + $Value + '"'
    }

    return $Value
}

function Start-WindowPlacementWatcher {
    param(
        [System.Windows.Forms.Screen] $TargetScreen,
        [int] $RootPid,
        [int] $TimeoutSeconds
    )

    $workArea = $TargetScreen.WorkingArea
    $watcherPath = Join-Path $PSScriptRoot 'Move-NewWindow.ps1'
    $powerShellPath = (Get-Process -Id $PID).Path

    $arguments = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', (Quote-CommandLineArgument $watcherPath)
        '-RootPid', $RootPid
        '-TargetLeft', $workArea.Left
        '-TargetTop', $workArea.Top
        '-TargetWidth', $workArea.Width
        '-TargetHeight', $workArea.Height
        '-TimeoutSeconds', $TimeoutSeconds
    )

    Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

$activeScreen = Get-ActiveScreen
$target = Resolve-TargetScreen -ActiveScreen $activeScreen -Selector $TargetScreen

if ($null -eq $target) {
    Write-Warning 'A second monitor was not found; running the command without repositioning.'
} else {
    Start-WindowPlacementWatcher -TargetScreen $target -RootPid $PID -TimeoutSeconds $TimeoutSeconds
}

Push-Location -LiteralPath $WorkingDirectory
$exitCode = 0
try {
    if ($Command.Count -eq 1) {
        Invoke-Expression $Command[0]
    } else {
        & $Command[0] @($Command[1..($Command.Count - 1)])
    }

    if ($null -ne $LASTEXITCODE) {
        $exitCode = $LASTEXITCODE
    }
} catch {
    Write-Error $_
    $exitCode = 1
} finally {
    Pop-Location
}

if ([string]::IsNullOrEmpty($MyInvocation.Line)) {
    # Launched as a separate process (powershell -File): propagate the exit code.
    exit $exitCode
}

$global:LASTEXITCODE = $exitCode
