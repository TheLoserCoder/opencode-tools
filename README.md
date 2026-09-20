# opencode-tools

Personal tools and skills for [OpenCode](https://opencode.ai).

## Contents

| Path                   | Description                                                                 |
| ---------------------- | --------------------------------------------------------------------------- |
| `tools/`               | Standalone tools that extend the OpenCode workflow.                         |
| `tools/window-placement` | Launches a command and moves its GUI window to a monitor other than the one OpenCode is running on. Works for any application, no code changes required. |
| `skills/`              | Agent skills collected from various sources, kept here for versioning and reuse. |

## tools/window-placement

See [`tools/window-placement/README.md`](tools/window-placement/README.md).

Quick start:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\window-placement\install.ps1
```

## skills

See [`skills/README.md`](skills/README.md) for the list of skills and their upstream
sources.
