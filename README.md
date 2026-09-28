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

A command run copies every line. PowerShell has no line cap, and no `snag -Full` or `snag -Last`.

`snag -Append` adds to whatever is already on the clipboard instead of replacing it, with one blank line between them. On bare `snag`, `-Append` works in both shells. On a command, `-Append` is PowerShell only. In cmd, bare `snag` keeps 200 lines of the screen buffer unless you pass `-Full`. `SNAG_MAX_LINES` overrides that cap when `-Full` is absent (`0` means no cap). PowerShell ignores it and always copies every line.

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
| PowerShell | `snag -Append` (same, append to the clipboard) |
| PowerShell | `snag git status`                                   |
| PowerShell | `snag { Get-Process \| sort CPU -desc \| select -first 5 }` |
| PowerShell | `snag cmd /c dir /b` (cmd builtins)                 |
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
