# snag

Prefix a command with `snag`: it runs normally, output shows live, and when it finishes the command
line plus all its output (stdout and stderr) is on the clipboard:

```
> git status
On branch main
...
```

In PowerShell, if a native command exits non-zero, a final `[exit N]` line is added.

Long output is trimmed on the clipboard (the console still shows everything): past 200 lines, only
the first 50 and last 150 are kept, with a `... [N lines omitted] ...` marker between them. Use
`snag -Full ...` in PowerShell to keep everything, or set `SNAG_MAX_LINES` to change the limit
(`0` = no limit) in either shell.

`snag -Last` (PowerShell only) re-runs the previous command from your history, after asking
`y/N` — it can't peek at output already printed, so it has to run the command again, which is
fine for something like `git status` and not for anything that changes state. `snag -Append ...`
(PowerShell only) adds to whatever's already on the clipboard instead of replacing it, so you can
run a few commands and paste all their output together.

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
| PowerShell | `snag -Full git log` (don't trim long output)       |
| PowerShell | `snag -Last` (re-run + copy the previous command, with confirmation) |
| PowerShell | `snag -Append git diff` (add to the clipboard instead of replacing it) |
| cmd        | `snag dir /b`                                       |
| cmd        | `snag dir ^| findstr txt` (escape the pipe)         |
| cmd        | `snag cmd /c "echo a & echo b"` (chaining)          |

## Limits

- **Pipes and `&` belong to the outer shell.** Unescaped, `snag a | b` pipes snag's output into `b`.
  Use a scriptblock in PowerShell, `^|` or `cmd /c "..."` in cmd.
- Output is piped, so most programs drop colors, and interactive commands (prompts, pagers) won't
  work. Color codes that do come through are stripped from the clipboard copy.
- In cmd, `%ERRORLEVEL%` after `snag` is not the command's exit code, and no `[exit N]` line is
  added (the pipe into the tee loses it). In PowerShell, `$LASTEXITCODE` is preserved.

## Files

- `snag.ps1` — PowerShell `snag` function
- `snag.cmd` + `snag-sink.ps1` — cmd entry point and the stdin tee it pipes into
- `install.ps1` — one-time setup
