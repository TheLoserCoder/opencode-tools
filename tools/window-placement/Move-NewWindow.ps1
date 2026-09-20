# Watches for GUI windows created by the process tree rooted at -RootPid and moves
# each new window onto the target monitor rectangle and, when -TargetDesktop is given,
# onto the virtual desktop where OpenCode is running. Exits when the root process
# exits (and no descendants remain) or when -TimeoutSeconds elapses.
#
# Moving another application's window to a virtual desktop requires the VirtualDesktop
# PowerShell module (MScholtes/VirtualDesktop); without it the monitor move still runs.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [int] $RootPid,

    [Parameter(Mandatory = $true)]
    [int] $TargetLeft,

    [Parameter(Mandatory = $true)]
    [int] $TargetTop,

    [Parameter(Mandatory = $true)]
    [int] $TargetWidth,

    [Parameter(Mandatory = $true)]
    [int] $TargetHeight,

    [int] $TimeoutSeconds = 30,

    [string] $TargetDesktop = '',

    [string] $StartedAfter = ''
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'WindowInterop.ps1')

[OpenCodeTools.WindowInterop]::SetProcessDPIAware() | Out-Null

$SWP_NOZORDER = 0x0004
$SWP_NOACTIVATE = 0x0010
$SW_RESTORE = 9
$SW_MAXIMIZE = 3
$TREE_REFRESH_MILLISECONDS = 500
$SCAN_INTERVAL_MILLISECONDS = 200

$selfPid = $PID

$startedAfterTime = (Get-Date).AddSeconds(-30)
if (-not [string]::IsNullOrWhiteSpace($StartedAfter)) {
    $parsedStart = [DateTime]::MinValue
    if ([DateTime]::TryParse($StartedAfter, [ref] $parsedStart)) {
        $startedAfterTime = $parsedStart
    }
}

function Resolve-DesktopObject {
    param([string] $Selector)

    $index = 0
    if ([int]::TryParse($Selector, [ref] $index)) {
        return Get-Desktop $index
    }

    return $Selector
}

$desktopObject = $null
if (-not [string]::IsNullOrWhiteSpace($TargetDesktop)) {
    if (Get-Module -ListAvailable -Name VirtualDesktop) {
        Import-Module VirtualDesktop -DisableNameChecking -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if (Get-Module -Name VirtualDesktop) {
            $desktopObject = Resolve-DesktopObject -Selector $TargetDesktop
        }
    }
}

function Get-TrackedProcessIds {
    param([int] $Root)

    $processes = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
        Select-Object ProcessId, ParentProcessId, CreationDate

    $childrenOf = @{}
    $liveIds = New-Object System.Collections.Generic.HashSet[int]
    foreach ($process in $processes) {
        $processId = [int] $process.ProcessId
        [void] $liveIds.Add($processId)
        $parent = [int] $process.ParentProcessId
        if (-not $childrenOf.ContainsKey($parent)) {
            $childrenOf[$parent] = New-Object System.Collections.ArrayList
        }
        [void] $childrenOf[$parent].Add($processId)
    }

    $result = New-Object System.Collections.Generic.List[int]
    $seen = New-Object System.Collections.Generic.HashSet[int]
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($Root)
    [void] $seen.Add($Root)

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $childrenOf.ContainsKey($current)) {
            continue
        }
        foreach ($child in $childrenOf[$current]) {
            if ($seen.Add($child)) {
                $result.Add($child)
                $queue.Enqueue($child)
            }
        }
    }

    # Short-lived intermediate processes (cmd.exe, a wrapper PowerShell) can exit
    # before the window appears, which breaks the live parent chain. Recover such
    # processes when they started after launch and their parent is already gone.
    foreach ($process in $processes) {
        $processId = [int] $process.ProcessId
        if ($processId -eq $Root -or $seen.Contains($processId)) {
            continue
        }

        if ([DateTime] $process.CreationDate -lt $startedAfterTime) {
            continue
        }

        $parent = [int] $process.ParentProcessId
        if ($liveIds.Contains($parent)) {
            continue
        }

        if ($seen.Add($processId)) {
            $result.Add($processId)
        }
    }

    return $result
}

function Move-WindowToTarget {
    param(
        [IntPtr] $Handle,
        [int] $Left,
        [int] $Top,
        [int] $Width,
        [int] $Height
    )

    $rect = New-Object OpenCodeTools.Rect
    if (-not [OpenCodeTools.WindowInterop]::GetWindowRect($Handle, [ref] $rect)) {
        return
    }

    $wasMaximized = [OpenCodeTools.WindowInterop]::IsZoomed($Handle)
    if ($wasMaximized) {
        [OpenCodeTools.WindowInterop]::ShowWindow($Handle, $SW_RESTORE) | Out-Null
    }

    $windowWidth = [Math]::Min($rect.Width, $Width)
    $windowHeight = [Math]::Min($rect.Height, $Height)
    if ($windowWidth -le 0) { $windowWidth = [Math]::Min(800, $Width) }
    if ($windowHeight -le 0) { $windowHeight = [Math]::Min(600, $Height) }

    $targetX = $Left + [int] (($Width - $windowWidth) / 2)
    $targetY = $Top + [int] (($Height - $windowHeight) / 2)

    [OpenCodeTools.WindowInterop]::SetWindowPos(
        $Handle,
        [IntPtr]::Zero,
        $targetX,
        $targetY,
        $windowWidth,
        $windowHeight,
        $SWP_NOZORDER -bor $SWP_NOACTIVATE
    ) | Out-Null

    if ($wasMaximized) {
        [OpenCodeTools.WindowInterop]::ShowWindow($Handle, $SW_MAXIMIZE) | Out-Null
    }
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$movedHandles = New-Object System.Collections.Generic.HashSet[long]
$descendantIds = @()
$lastTreeRefresh = [DateTime]::MinValue

while ((Get-Date) -lt $deadline) {
    if (((Get-Date) - $lastTreeRefresh).TotalMilliseconds -ge $TREE_REFRESH_MILLISECONDS) {
        $descendantIds = Get-TrackedProcessIds -Root $RootPid
        $lastTreeRefresh = Get-Date

        # PowerShell does not wait for GUI applications, so the root process may
        # exit right after spawning the window. Keep watching while any descendant
        # is still alive.
        $rootAlive = [bool] (Get-Process -Id $RootPid -ErrorAction SilentlyContinue)
        if (-not $rootAlive -and $descendantIds.Count -eq 0) {
            break
        }
    }

    foreach ($processId in $descendantIds) {
        if ($processId -eq $selfPid) {
            continue
        }

        foreach ($handle in [OpenCodeTools.WindowInterop]::GetTopLevelWindows($processId)) {
            $key = $handle.ToInt64()
            if ($movedHandles.Contains($key)) {
                continue
            }

            if ($null -ne $desktopObject) {
                try {
                    Move-Window -Desktop $desktopObject -Hwnd $handle -ErrorAction Stop | Out-Null
                } catch {
                    # Keep the window where Windows placed it if the desktop move fails.
                }
            }

            Move-WindowToTarget -Handle $handle -Left $TargetLeft -Top $TargetTop -Width $TargetWidth -Height $TargetHeight
            [void] $movedHandles.Add($key)
        }
    }

    Start-Sleep -Milliseconds $SCAN_INTERVAL_MILLISECONDS
}
