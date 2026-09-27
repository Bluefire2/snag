# snag

Prefix a command with `snag`: it runs normally, output shows live, and when it finishes the command
line plus all its output (stdout and stderr) is on the clipboard:

```
> git status
On branch main
...
```

## Install

```
powershell -ExecutionPolicy Bypass -File install.ps1
```

Adds this folder to your user PATH and dot-sources `snag.ps1` from your PowerShell `$PROFILE`.
Open a new terminal afterwards.

## Usage

| Shell      | Example                                           |
|------------|---------------------------------------------------|
| PowerShell | `snag git status`                                   |
| PowerShell | `snag { Get-Process \| sort CPU -desc \| select -first 5 }` |
| PowerShell | `snag cmd /c dir /b` (cmd builtins)                 |
| cmd        | `snag dir /b`                                       |
| cmd        | `snag dir ^| findstr txt` (escape the pipe)         |
| cmd        | `snag cmd /c "echo a & echo b"` (chaining)          |

## Limits

- **Pipes and `&` belong to the outer shell.** Unescaped, `snag a | b` pipes snag's output into `b`.
  Use a scriptblock in PowerShell, `^|` or `cmd /c "..."` in cmd.
- Output is piped, so programs drop colors, and interactive commands (prompts, pagers) won't work.
- In cmd, `%ERRORLEVEL%` after `snag` is not the command's exit code. In PowerShell,
  `$LASTEXITCODE` is preserved.

## Files

- `snag.ps1` — PowerShell `snag` function
- `snag.cmd` + `snag-sink.ps1` — cmd entry point and the stdin tee it pipes into
- `install.ps1` — one-time setup
