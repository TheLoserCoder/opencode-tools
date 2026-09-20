# window-placement

Launch a command from OpenCode (or any terminal) and have the GUI window it opens
appear on **a different monitor than the one OpenCode is running on**, on the
**same Windows virtual desktop**.

It works for any application — Electron, native Win32, .NET, packaged apps — because
it operates at the OS level and does not require changes in the launched program.

## Requirements

- Windows 10 or 11.
- Windows PowerShell 5.1 (built into Windows) or PowerShell 7+. No third-party
  dependencies.

## Install

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

This is idempotent and only touches the global OpenCode configuration:

1. Adds a managed block to `%USERPROFILE%\.config\opencode\AGENTS.md` instructing
   agents to route GUI launches through the launcher.
2. Creates the `/other-screen` slash command in
   `%USERPROFILE%\.config\opencode\commands\other-screen.md`.

Optional: add a `Start-OnOtherScreen` function to your PowerShell profile so you can
call it interactively:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -AddProfileFunction
```

Restart the OpenCode service or start a new session to pick up the changes:

```sh
opencode service restart
```

## Usage

```powershell
# From PowerShell
.\Start-OnOtherScreen.ps1 pnpm dev
.\Start-OnOtherScreen.ps1 -TargetScreen 2 notepad
.\Start-OnOtherScreen.ps1 -TargetScreen '\\.\DISPLAY2' notepad
.\Start-OnOtherScreen.ps1 -TimeoutSeconds 60 pnpm dev
```

```bat
:: From cmd.exe or any shell
Start-OnOtherScreen.cmd pnpm dev
```

From the OpenCode TUI:

```text
/other-screen pnpm dev
```

### Parameters

| Parameter            | Default              | Description                                                                 |
| -------------------- | -------------------- | --------------------------------------------------------------------------- |
| `-Command`           | required (positional)| Command to run, for example `pnpm dev`.                                     |
| `-WorkingDirectory`  | current directory    | Directory to run the command in.                                            |
| `-TargetScreen`      | `other`              | `other` = a monitor other than the active one; or a 1-based index; or a device name such as `\\.\DISPLAY2`. |
| `-TimeoutSeconds`    | `30`                 | How long the background watcher waits for windows to appear.                |

## How it works

1. The launcher asks Win32 for the monitor that currently has focus — normally the
   terminal running OpenCode.
2. It picks the target monitor: the first non-primary monitor that is not the active
   one (or the monitor you requested explicitly).
3. It starts a hidden background watcher for the process tree of the command.
4. It runs the command with the console attached, so stdout/stderr stay visible in
   the terminal that started it.
5. The watcher enumerates new visible top-level windows of every process in the
   tree (so it catches `pnpm -> electron`), and moves each one onto the target
   monitor's working area. Maximized windows stay maximized on the new monitor.

The window is never moved to another virtual desktop. Windows creates new windows on
the active virtual desktop, so a window launched from the OpenCode terminal already
lands on OpenCode's virtual desktop.

## Limitations

- **Flicker.** The window may appear for a fraction of a second on the original
  monitor before it is moved. This is inherent to the OS-level approach.
- **Elevated windows.** Windows belonging to an elevated (administrator) process
  cannot be moved from a non-elevated script.
- **Saved positions.** An application that persists and restores its own window
  position may move itself back after the watcher has placed it.
- **Mixed DPI.** The tool uses system-DPI awareness. On monitors with different
  scaling factors the placement may be off; identical scaling works best.
- **Timeout.** Windows that appear later than `-TimeoutSeconds` are not moved.
- **Single monitor.** If only one monitor is available, the command runs normally
  without repositioning.

## Files

| File                      | Purpose                                                        |
| ------------------------- | -------------------------------------------------------------- |
| `Start-OnOtherScreen.ps1` | Launcher: picks the target monitor, runs the command, starts the watcher. |
| `Move-NewWindow.ps1`      | Background watcher that moves windows of the command's process tree. |
| `WindowInterop.ps1`       | Shared Win32 P/Invoke definitions.                             |
| `Start-OnOtherScreen.cmd` | cmd.exe shim.                                                  |
| `install.ps1`             | Wires the launcher into the global OpenCode configuration.     |
