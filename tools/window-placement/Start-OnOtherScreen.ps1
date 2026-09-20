# Runs a command and places the GUI window(s) it opens on the virtual desktop where
# OpenCode is running and on a monitor other than the one that currently has focus.
#
# The command keeps the current console attached, so its stdout/stderr stay visible
# in the terminal that launched it.
#
# Usage:
#   .\Start-OnOtherScreen.ps1 pnpm dev
#   .\Start-OnOtherScreen.ps1 -TargetScreen 2 notepad
#   .\Start-OnOtherScreen.ps1 -VirtualDesktop 1 notepad
#   .\Start-OnOtherScreen.cmd pnpm dev

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true, ValueFromRemainingArguments = $true)]
    [string[]] $Command,

    [string] $WorkingDirectory = (Get-Location).Path,

    [string] $TargetScreen = 'other',

    [string] $VirtualDesktop = 'auto',

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

function Get-AncestorProcessIds {
    param(
        [int] $ProcessId,
        [int] $MaxDepth = 20
    )

    $processes = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
        Select-Object ProcessId, ParentProcessId

    $parentOf = @{}
    foreach ($process in $processes) {
        $parentOf[[int] $process.ProcessId] = [int] $process.ParentProcessId
    }

    $result = New-Object System.Collections.Generic.List[int]
    $current = $ProcessId
    $depth = 0
    while ($parentOf.ContainsKey($current) -and $depth -lt $MaxDepth) {
        $parent = $parentOf[$current]
        if ($parent -le 0) {
            break
        }
        $result.Add($parent)
        $current = $parent
        $depth++
    }

    return $result
}

function Get-DesktopIndexFromProcessWindows {
    param([int] $ProcessId)

    foreach ($handle in [OpenCodeTools.WindowInterop]::GetTopLevelWindows($ProcessId)) {
        try {
            $index = Get-DesktopIndex (Get-DesktopFromWindow -Hwnd $handle)
            if ($index -ge 0) {
                return $index
            }
        } catch {
            # Window cannot be mapped to a desktop; try the next one.
        }
    }

    return -1
}

function Import-VirtualDesktopModule {
    if (-not (Get-Module -ListAvailable -Name VirtualDesktop)) {
        return $false
    }

    if (-not (Get-Module -Name VirtualDesktop)) {
        Import-Module VirtualDesktop -DisableNameChecking -WarningAction SilentlyContinue -ErrorAction Stop
    }

    return $true
}

function Resolve-DesktopTarget {
    param([string] $Selector)

    if ($Selector -ieq 'none') {
        return $null
    }

    if (-not (Import-VirtualDesktopModule)) {
        Write-Warning 'The VirtualDesktop module is not installed; the window will only be moved between monitors.'
        return $null
    }

    if ($Selector -ieq 'auto') {
        # Prefer the desktop of the process that hosts OpenCode, found by walking the
        # ancestor chain up to the process that owns a visible window. This does not
        # depend on which window currently has focus, so it works when the user is
        # looking at another application on another virtual desktop.
        foreach ($ancestorId in (Get-AncestorProcessIds -ProcessId $PID)) {
            $index = Get-DesktopIndexFromProcessWindows -ProcessId $ancestorId
            if ($index -ge 0) {
                return [string] $index
            }
        }

        # Fall back to the focused window and the console window.
        $candidateHandles = @()
        foreach ($provider in @('Get-ActiveWindowHandle', 'Get-ConsoleHandle')) {
            try {
                $candidateHandles += & $provider
            } catch {
                # Provider is unavailable; try the next one.
            }
        }

        foreach ($handle in $candidateHandles) {
            if ($null -eq $handle -or [int64] $handle -eq 0) {
                continue
            }

            try {
                $index = Get-DesktopIndex (Get-DesktopFromWindow -Hwnd $handle)
                if ($index -ge 0) {
                    return [string] $index
                }
            } catch {
                # Window cannot be mapped to a desktop; try the next candidate.
            }
        }

        Write-Warning 'Could not determine the OpenCode virtual desktop; skipping the virtual desktop move.'
        return $null
    }

    return $Selector
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
        [string] $TargetDesktop,
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
        '-StartedAfter', (Get-Date).AddSeconds(-2).ToString('o')
    )

    if (-not [string]::IsNullOrWhiteSpace($TargetDesktop)) {
        $arguments += @('-TargetDesktop', $TargetDesktop)
    }

    Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

$activeScreen = Get-ActiveScreen
$target = Resolve-TargetScreen -ActiveScreen $activeScreen -Selector $TargetScreen
$desktopTarget = Resolve-DesktopTarget -Selector $VirtualDesktop

if ($null -eq $target -and [string]::IsNullOrWhiteSpace($desktopTarget)) {
    Write-Warning 'No second monitor and no virtual desktop target; running the command without repositioning.'
} elseif ($null -eq $target) {
    Write-Warning 'A second monitor was not found; only the virtual desktop will be adjusted.'
    Start-WindowPlacementWatcher -TargetScreen $activeScreen -RootPid $PID -TargetDesktop $desktopTarget -TimeoutSeconds $TimeoutSeconds
} else {
    Start-WindowPlacementWatcher -TargetScreen $target -RootPid $PID -TargetDesktop $desktopTarget -TimeoutSeconds $TimeoutSeconds
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
