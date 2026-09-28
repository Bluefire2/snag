# snag

Prefix a command with `snag`: it runs normally, output shows live, and when it finishes the command
line plus all its output (stdout and stderr) is on the clipboard:

```
> git status
On branch main
...
```

`snag` with no command copies the previous command's output already on screen, in PowerShell and in
cmd. It does not run that command again. No-argument `snag` used to print usage; usage is now
`snag -?`.

In PowerShell, if a native command exits non-zero, a final `[exit N]` line is added. A copy of
output already on screen does not add one.

Long output is trimmed on the clipboard (the console still shows everything): past 200 lines, only
the first 50 and last 150 are kept, with a `... [N lines omitted] ...` marker between them. Use
`snag -Full` to keep everything, or set `SNAG_MAX_LINES` to change the limit (`0` = no limit).
Bare `snag -Full` works in both shells. In cmd, `snag -Full dir` is still a command run, so the
command name is `-Full`; uncapped output there is `set SNAG_MAX_LINES=0`.

`snag -Last` (PowerShell only) re-runs the previous command from your history, after asking
`y/N`. Bare `snag` copies what is already printed; `-Last` is still the re-run, which is fine for
something like `git status` and not for anything that changes state. `snag -Append` adds to
whatever is already on the clipboard instead of replacing it, with one blank line between them.
On bare `snag`, `-Append` works in both shells (`snag -Full -Append`, either flag order). On a
command, `-Append` is PowerShell only.

## Install

```
powershell -ExecutionPolicy Bypass -File install.ps1
```

Adds this folder to your user PATH and dot-sources `snag.ps1` from your PowerShell `$PROFILE`.
Open a new terminal afterwards.

## Usage

| Shell      | Example                                           |
|------------|---------------------------------------------------|
| PowerShell | `snag` (copy the previous command's on-screen output; does not re-run) |
| PowerShell | `snag -Full` (same, no line cap) |
| PowerShell | `snag -Append` (same, append to the clipboard) |
| PowerShell | `snag -Full -Append` (both) |
| PowerShell | `snag git status`                                   |
| PowerShell | `snag { Get-Process \| sort CPU -desc \| select -first 5 }` |
| PowerShell | `snag cmd /c dir /b` (cmd builtins)                 |
| PowerShell | `snag -Full git log` (don't trim long output)       |
| PowerShell | `snag -Last` (re-run + copy the previous command, with confirmation) |
| PowerShell | `snag -Append git diff` (add to the clipboard instead of replacing it) |
| cmd        | `snag` (copy the previous command's on-screen output; does not re-run) |
| cmd        | `snag -Full` (same, no line cap) |
| cmd        | `snag -Append` (same, append to the clipboard) |
| cmd        | `snag -Full -Append` (both) |
| cmd        | `snag dir /b`                                       |
| cmd        | `snag dir ^| findstr txt` (escape the pipe)         |
| cmd        | `snag cmd /c "echo a & echo b"` (chaining)          |

## Limits

- **Pipes and `&` belong to the outer shell.** Unescaped, `snag a | b` pipes snag's output into `b`.
  Use a scriptblock in PowerShell, `^|` or `cmd /c "..."` in cmd.
- Output is piped, so most programs drop colors, and interactive commands (prompts, pagers) won't
  work. Color codes that do come through are stripped from the clipboard copy.
- **Bare `snag` reads the Win32 console screen buffer.** Windows Terminal, VS Code, and Cursor use
  ConPTY, so that buffer is the visible viewport, not the terminal's own scrollback. Classic
  conhost can include its scrollback up to the buffer height. If the previous command line has
  scrolled out, snag still copies what is left above the `snag` line, still writes a `> ` header
  (from history when it has the command), and warns that the copy may be partial.
- In cmd, `%ERRORLEVEL%` after `snag` is not the command's exit code, and no `[exit N]` line is
  added (the pipe into the tee loses it). In PowerShell, `$LASTEXITCODE` is preserved.

## Files

- `snag.ps1` — PowerShell `snag` function
- `snag.cmd` + `snag-sink.ps1` — cmd entry point and the stdin tee it pipes into
- `snag-buffer.ps1` — bare `snag` copies the previous command's on-screen output
- `install.ps1` — one-time setup
