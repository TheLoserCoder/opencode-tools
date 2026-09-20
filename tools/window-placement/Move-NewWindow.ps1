# Watches for GUI windows created by the process tree rooted at -RootPid and moves
# each new window onto the target monitor rectangle. Exits when the root process
# exits or when -TimeoutSeconds elapses.

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

    [int] $TimeoutSeconds = 30
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

function Get-DescendantProcessIds {
    param([int] $Root)

    $processes = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
        Select-Object ProcessId, ParentProcessId

    $childrenOf = @{}
    foreach ($process in $processes) {
        $parent = [int] $process.ParentProcessId
        if (-not $childrenOf.ContainsKey($parent)) {
            $childrenOf[$parent] = New-Object System.Collections.ArrayList
        }
        [void] $childrenOf[$parent].Add([int] $process.ProcessId)
    }

    $result = New-Object System.Collections.Generic.List[int]
    $queue = New-Object System.Collections.Generic.Queue[int]
    $seen = New-Object System.Collections.Generic.HashSet[int]
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
        $descendantIds = Get-DescendantProcessIds -Root $RootPid
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

            Move-WindowToTarget -Handle $handle -Left $TargetLeft -Top $TargetTop -Width $TargetWidth -Height $TargetHeight
            [void] $movedHandles.Add($key)
        }
    }

    Start-Sleep -Milliseconds $SCAN_INTERVAL_MILLISECONDS
}
