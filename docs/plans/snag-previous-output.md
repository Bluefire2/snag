# Plan: bare `snag` copies the previous command's screen output

## Summary

Bare `snag` (no command) in PowerShell and in cmd copies the previous command's **already printed** output from the Win32 console screen buffer onto the clipboard. It does not run that command again. `snag -Last` stays the PowerShell-only re-run-with-confirmation path.

This is a behavior change: today, `snag` with no arguments prints usage and copies nothing. After this change, no-argument `snag` performs the copy. Usage moves to `snag -?` (and unknown options).

Both shells call one implementation, `snag-buffer.ps1`. Win32 P/Invoke is isolated in `Read-SnagConsoleBuffer`. The pure functions `Join-SnagConsoleRows`, `Resolve-SnagCmdHistory`, and `Select-SnagPreviousOutput` decide the command header and the output lines from already-read text, so they can be tested on Linux with no console. cmd captures `doskey /history` itself and passes it in, because the child `powershell` process does not share cmd's history. Consecutive identical doskey lines are collapsed, so the cmd history resolver drops the last line only when that line is the in-flight invocation and the screen does not already show a longer prompt-boundary match for it above the anchor. A bare output line equal to `snag` does not count.

`install.ps1` stays unchanged: `snag.ps1` dot-sources `snag-buffer.ps1`, and `snag.cmd` launches that file with `-File`.

## Behavior spec

Clipboard shape matches a normal snag: `> <command>` then the output, joined with CRLF, no extra trailing CRLF after the last output line. The same blank-line trim and the same line cap apply (`SNAG_MAX_LINES`, default 200: first quarter + tail, with `... [N lines omitted] ...`). `-Full` or `SNAG_MAX_LINES=0` keeps everything captured. `-Append` uses the same "blank line between the existing clipboard and the new block" rule as `snag.ps1`.

Buffer copies do **not** add an `[exit N]` line. If an exit line is already visible in the captured text, it is ordinary output. The buffer path must not read or write `$LASTEXITCODE`.

| Invocation | Shell | Result |
|---|---|---|
| `snag` | PowerShell, cmd | Copy previous output from the screen buffer. Do not re-run. |
| `snag -Full` | PowerShell, cmd | Same, no line cap. |
| `snag -Append` | PowerShell, cmd | Same, append to the clipboard. |
| `snag -Full -Append` and `snag -Append -Full` | PowerShell, cmd | Both. |
| `snag -Last` | PowerShell | Unchanged: confirm with `y/N`, then re-run. |
| `snag -Last` | cmd | Usage. `-Last` is not implemented in cmd. |
| `snag git status`, `snag { ... }` | PowerShell | Unchanged run-and-copy, including `[exit N]` when a native command fails. |
| `snag dir /b` | cmd | Unchanged run-and-tee through `snag-sink.ps1`. |
| `snag -Full git status` | PowerShell | Unchanged: run `git status` with no line cap. |
| `snag -Full git status` | cmd | Unchanged: the run path, so the command name is `-Full`. Not buffer mode. |
| `snag -?`, `snag /?`, `snag --help` | PowerShell, cmd | Usage, including the no-command form. Clipboard unchanged. |
| `snag -Bogus` (no command after it) | PowerShell, cmd | Unknown-option line, then usage. Clipboard unchanged. |
| `snag -Bogus git status` | PowerShell | Same as today: unknown option, do not run `git status`. Also print usage. |
| stdout is not a console | PowerShell, cmd | One short error. Clipboard unchanged. Exit code 1 from `snag.cmd`. |

PowerShell examples (conhost, so the previous command is still in the buffer):

```
PS C:\repo> git status
On branch main
nothing to commit
PS C:\repo> snag
[snag] copied 2 lines
```

Clipboard:

```
> git status
On branch main
nothing to commit
```

```
PS C:\repo> snag -Full -Append
```

Same text, uncapped, appended to the existing clipboard with one blank line between blocks. Status line ends with ` (appended)`, same as today.

cmd:

```
C:\repo> dir /b
README.md
snag.cmd
C:\repo> snag
[snag] copied 2 lines
```

Clipboard header is `> dir /b`, then those two names. No `[exit N]`.

When the previous command line has scrolled out of the readable buffer, still copy what is left above the `snag` line, still emit a `> ` header (the history text when history has it), and warn:

```
snag: the previous command isn't in the readable screen buffer; the copy may be partial
[snag] copied N lines
```

That region can include older commands that are still on screen. The warning is the signal that the cut is not exact.

When history has no previous command:

```
snag: no previous command in history; copying the screen above this line
```

Header is `> ` with an empty command. The readable lines above `snag` are still copied.

When stdout is not a console (`snag > file`, or a host that does not expose a console handle):

```
snag: stdout isn't a console, so the previous output can't be copied
```

Usage text (PowerShell, yellow `Write-Host`), used for `-?` / `--help` / `/?` and after `snag: unknown option '<token>'`:

```
usage: snag [-Full] [-Append]
       snag [-Full] [-Append] <command> [args...]
       snag [-Full] [-Append] { <pipeline> }
       snag -Last
Bare snag copies the previous command's output already on screen.
snag -Last re-runs that command, after y/N.
```

cmd usage (also the `-Last` response):

```
usage: snag [-Full] [-Append]
       snag <command> [args...]
Bare snag copies the previous command's output already on screen.
-Last is PowerShell only; it re-runs the previous command.
```

`-Full` on the buffer path wins over `SNAG_MAX_LINES`, same precedence as the run path. The cap message on this path is `N of M lines (snag -Full for all)` in both shells, because bare `snag -Full` exists in both. Do not change the cmd **run-path** message in `snag-sink.ps1` (`set SNAG_MAX_LINES=0 for all`).

## Non-goals

- Do not change `snag -Last`: same history lookup, same `y/N` prompt, same re-run, same `[exit N]` rules.
- Do not read Windows Terminal, VS Code, or Cursor scrollback beyond the Win32 screen buffer. ConPTY's buffer is the viewport.
- Do not install a profile hook, PSReadLine predictor, or doskey macro to record future output.
- Do not add `-Full` or `-Append` to cmd's run-a-command path. `snag -Full dir` in cmd keeps today's meaning.
- Do not synthesize `[exit N]` from `$LASTEXITCODE` or `%ERRORLEVEL%`.
- Do not refactor the run path in `snag.ps1` or `snag-sink.ps1` onto a shared clipboard helper. Duplicate the small trim / append / `Set-Clipboard` block in the buffer path.
- Do not take a new dependency (no Pester module, no C# project, no NuGet).
- Do not change `install.ps1` or `.gitattributes`.

## Algorithm

### Files and entry

`snag-buffer.ps1` defines functions and, only when it is the `-File` entry (not dot-sourced), parses `$args` and calls the orchestrator. Detection: `$MyInvocation.InvocationName -ne '.'`. Do not put a `param()` block on the script. A `param()` block would bind the caller's arguments when `snag.ps1` or the test script dot-sources the file.

Dot-source check must be the script's own `$MyInvocation`, not a function's.

Script-entry arguments, any order:

- `-FromCmd` — required for the cmd entry. History comes from `-HistoryFile`, not `Get-History`.
- `-HistoryFile <path>` — doskey output captured by `snag.cmd`.
- `-CurrentInvocation <text>` — the doskey line for this run (`snag` plus any bare-snag flags). Required with `-FromCmd`. Passed to `Resolve-SnagCmdHistory`.
- `-Full` — max lines = 0.
- `-Append` — append to the clipboard.

Exit 0 on a copy (including a partial copy). Exit 1 when the console cannot be read or cmd history cannot be read. The `-File` footer does **not** delete `-HistoryFile`. `snag.cmd` is the only deleter, after it has saved `%ERRORLEVEL%`. A second `del` of a missing file would print `Could Not Find` after a successful copy.

`snag.ps1` dot-sources `snag-buffer.ps1` at file scope, then the no-command branch calls `Copy-SnagPreviousOutput -MaxLines $maxLines -Append:$appendClip`. That branch does not pipe through `snag-sink.ps1` (the sink only sees stdin of a command `snag.cmd` is running).

### 1. Read the screen buffer (`Read-SnagConsoleBuffer`)

Isolated P/Invoke. Add the type only if it is not already loaded (`'Snag.ConsoleNative' -as [type]`). `Add-Type` cannot unload a type in a session; a second `Add-Type` of the same name throws. If `Add-Type` throws and the type is present afterward, continue.

```csharp
namespace Snag {
    public class ConsoleNative {
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr GetStdHandle(int nStdHandle);

        [StructLayout(LayoutKind.Sequential)]
        public struct COORD {
            public short X;
            public short Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct SMALL_RECT {
            public short Left, Top, Right, Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct CONSOLE_SCREEN_BUFFER_INFO {
            public COORD dwSize;
            public COORD dwCursorPosition;
            public short wAttributes;
            public SMALL_RECT srWindow;
            public COORD dwMaximumWindowSize;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetConsoleScreenBufferInfo(
            IntPtr hConsoleOutput, out CONSOLE_SCREEN_BUFFER_INFO lpConsoleScreenBufferInfo);

        // EntryPoint is explicit so CharSet.Unicode does not look up a doubled "WW" name.
        [DllImport("kernel32.dll", EntryPoint = "ReadConsoleOutputCharacterW",
            SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool ReadConsoleOutputCharacter(
            IntPtr hConsoleOutput, [Out] char[] lpCharacter, int nLength,
            COORD dwReadCoord, out int lpNumberOfCharsRead);
    }
}
```

Steps:

1. `handle = GetStdHandle(-11)` (`STD_OUTPUT_HANDLE`). If the handle is `IntPtr.Zero` or `-1`, fail.
2. `GetConsoleScreenBufferInfo`. On failure, fail. Ignore `srWindow` on purpose: row 0 is the top of the Win32 buffer, which is the viewport under ConPTY and includes conhost scrollback.
3. Let `width = dwSize.X`, `cursorY = dwCursorPosition.Y`. Read rows with `for ($y = 0; $y -lt $cursorY; $y++)` (cursor row exclusive). Do not use PowerShell's `..` range here: when `cursorY` is 0, `0..-1` is not empty. While `snag` is running and has not yet written, the cursor sits on the line after the echoed command, so the echoed `snag` line is the last row of this range. That holds for cmd (cooked read writes the newline before `ReadConsole` returns, and `powershell -NoProfile -File` does not move the cursor back up) and for PowerShell (`PSReadLine`'s `AcceptLineImpl`, and the legacy host's cooked read, write the newline before the `snag` function runs).
4. Each read asks for `width` characters at `COORD { X = 0, Y = y }`. Replace `` `0 `` with a space. If the call fails, fail the whole read (do not copy a half buffer). If fewer than `width` chars come back, pad with spaces on the right so every row is exactly `width` characters.
5. Drop trailing rows whose every character is a space.
6. Return `{ Width, Rows }`. On failure return `$null`; the caller prints the error and does not touch the clipboard.

Call this before any `Write-Host`, so snag's own messages are not part of the capture.

Rendered cells come back as characters. Do not run the ANSI stripper on this path.

### 2. Unwrap rows (`Join-SnagConsoleRows`)

```powershell
function Join-SnagConsoleRows {
    param([string[]]$Rows, [int]$Width)
}
```

Pure. Each input row is `Width` characters (tests pad them). Walk in order:

- If the row's length equals `Width` and its last character is not a space, it continues: append all `Width` characters to the current logical line and do not flush.
- Otherwise append `row.TrimEnd(' ')` and flush a logical line.
- After the loop, flush a leftover piece if the final row was a continuation (end of the readable buffer).

A row shorter than `Width` never continues. The output lines are already right-trimmed. A row of only spaces becomes `''`.

### 3. Choose history text

**PowerShell** (`-FromCmd` absent): `(Get-History -Count 1).CommandLine`. The in-flight `snag` call is not in history yet, so this is the previous command. No history → `''`. Do not trim the command. Do not touch `$LASTEXITCODE`.

**cmd** (`-FromCmd`): read `-HistoryFile` with `[System.Text.Encoding]::GetEncoding([Console]::OutputEncoding.CodePage)`, same code page `snag-sink.ps1` uses for the arg file. `doskey /history` is one command per line. If the file is missing or unreadable, print `snag: couldn't read cmd history`, do not touch the clipboard, and `exit 1` from the `-File` footer only. Do not join doskey lines together.

Conhost's cooked read calls `CommandHistory::Add` before `ReadConsole` returns, so `snag.cmd` runs after history has been updated. `Add` then skips the append when the new line equals the previous one, so consecutive duplicates are collapsed even with "Discard Old Duplicates" off. After `dir` then `snag`, the last line is the in-flight `snag`. After `snag` then `snag` again, the second `snag` is not stored, and the last line is the previous `snag`. Comparing the last line to the text `snag` cannot tell those two histories apart. Always dropping the last line is wrong for the second case.

`snag.cmd` passes the full history and the current invocation (the line doskey would have stored: `snag`, `snag -Full`, `snag -Append`, `snag -Full -Append`, or `snag -Append -Full`, single spaces, flags in the order typed). A pure function resolves the history text before `Select-SnagPreviousOutput`:

```powershell
function Resolve-SnagCmdHistory {
    param(
        [string[]]$HistoryLines,
        [string]$CurrentInvocation,
        [string[]]$LogicalLines
    )
}
```

Strip trailing empty history lines. Let `last` be the final remaining line, or `''` when none remain.

- If `last` equals `$CurrentInvocation` under ordinal ignore-case, and some logical line above the anchor is a **longer prompt-boundary match** for `$last` (the doskey text, not the canonical invocation), keep `last`. The duplicate was collapsed, so `last` is the previous command. Ignore-case is required because cmd accepts `-Full` / `-Append` in any case and the batch file rewrites them (`snag -full` is passed as `snag -Full`). The screen search stays ordinal and uses `$last`, because that is the text on screen (`Snag`, `snag -full`).
- If `last` equals `$CurrentInvocation` under ordinal ignore-case and no such earlier line exists, drop `last` and take the new final line. That dropped line is the in-flight command.
- If `last` does not equal `$CurrentInvocation` even ignoring case, keep `last`. The in-flight line was not recorded, so `last` is already the previous command.

A longer prompt-boundary match uses the first-segment rule below: `TrimEnd` the line, it matches `$last` (the line equals `$last`, or it ends with `$last` and the character immediately before is whitespace or `>`), and the trimmed line is strictly longer than `$last`. A bare output line equal to `snag` does not count. The anchor is the same last non-blank logical line `Select-SnagPreviousOutput` excludes. No history left after this rule → `''`.

Return that one line as the history string. `Resolve-SnagCmdHistory` does not `Write-Host`.

PowerShell does not use this function. `Get-History` has not recorded the in-flight call, so `(Get-History -Count 1).CommandLine` is already the previous command.

### 4. Select the region (`Select-SnagPreviousOutput`)

```powershell
function Select-SnagPreviousOutput {
    param(
        [string[]]$LogicalLines,
        [string]$HistoryText,
        [ValidateSet('powershell', 'cmd')][string]$Shell
    )
}
```

Returns one object:

| Property | Meaning |
|---|---|
| `CommandText` | Header text without the leading `> `. `''` when there is no history. |
| `OutputLines` | Output lines after leading/trailing `''` removal. Internal blank lines stay. |
| `Partial` | History was non-empty and the command was not found above the snag line. |
| `NoHistory` | History text was empty. Never combined with `Partial`. |

No `Write-Host` inside this function.

**Current line.** The last non-blank logical line is the echoed `snag` invocation. Call its index `anchor`. Lines at `anchor` and after are excluded. If every line is blank, the search region is empty and `anchor = -1`.

PowerShell's `..` operator is not a slice. `1..0` yields both indexes, and `0..-1` is not an empty range. Build the region above the anchor with an explicit bound check: when `anchor -le 0`, the region is an empty list. Do not write `0..(anchor-1)`. The row loop in `Read-SnagConsoleBuffer` has the same trap: when `cursorY` is 0, read nothing. Do not write `0..($cursorY-1)`.

**History segments.** If `$HistoryText` is `$null` or `''`, `NoHistory = $true`, `CommandText = ''`, and `OutputLines` is the blank-trimmed region above `anchor` (empty when `anchor -le 0`). Stop.

Otherwise strip exactly one trailing newline (`\r\n`, `\n`, or `\r`) if present, then split on `\r\n|\n|\r` keeping empty internal segments. `CommandText` is the segments joined back with `` `n `` (the clipboard writer normalizes to CRLF). Do not use the on-screen text as the header. The screen line includes the prompt; history does not.

**Continuation prefix** for segments after the first: PowerShell `>> `, cmd `More? `. A continuation line matches segment `S` when, after `TrimEnd`, it equals `S` or equals `(prefix + S)`. An empty segment matches a line that trims to `''`, `>>`, or `More?`.

**First-segment match** (literal, ordinal, not a regex — command text may contain `.`, `(`, `|`):

Let `L` be the line with `TrimEnd` applied. It matches `S0` when `L` ends with `S0` and either `L` equals `S0` or the character immediately before the match is whitespace or `>`.

So `PS C:\repo> git status` matches `git status`, and a full line `git status` matches too. `mygit status` does not. `echo git status` matches `git status` because of the space. That is intentional: the real invocation is the **last** match.

**Search.** `for ($start = $anchor - 1; $start -ge 0; $start--)`. When `anchor -le 0`, do not enter the loop and do not build a range from `-1`. Accept the first `start` where segment 0 matches `LogicalLines[$start]` **and** every later segment matches the following line as a continuation, without crossing `anchor`. That is the bottom-most full match above the snag line.

Output region: if `start + segmentCount -ge anchor`, the region is empty (test 8: `anchor` 1, `start` 0, `segmentCount` 1). Otherwise copy indexes `start + segmentCount` through `anchor - 1` with a loop, or with `..` only when the start index is less than or equal to the end index. Never write `(start + segmentCount)..(anchor - 1)` unconditionally: PowerShell's `1..0` includes both ends, which would put the snag line and the command line into `OutputLines`. Then drop leading and trailing `''` the same way `snag.ps1` does (`while` first/last is `''`). Do not drop internal `''`. Blank trimming does not remove non-blank lines, so the bound check is what keeps test 8 at length 0.

**No full match.** `Partial = $true`, `CommandText` = history text, `OutputLines` = blank-trimmed lines above `anchor` (the whole readable region). Do not guess a start line from the prompt shape.

### 5. Clipboard (`Copy-SnagPreviousOutput`)

Orchestrator, after the read and the select:

1. Map warnings, yellow `Write-Host`, before the success line:
   - `NoHistory` → `snag: no previous command in history; copying the screen above this line`
   - `Partial` → `snag: the previous command isn't in the readable screen buffer; the copy may be partial`
2. Duplicate the run-path cap, do not call into `snag.ps1`:
   - `maxLines` from the argument (`-Full` already resolved to 0) else the same `SNAG_MAX_LINES` regex as `snag.ps1` (default 200).
   - If `maxLines -gt 0` and the output count is greater, keep `Floor(maxLines/4)` head lines, then `... [{0:N0} lines omitted] ...`, then the tail. Status text: `'{0} of {1:N0} lines (snag -Full for all)'`.
   - Otherwise status text is `'{0} lines'`.
3. Normalize the header, then join. Do not append `[exit N]`.

```powershell
$header = $CommandText -replace "`r`n|`n|`r", "`r`n"
$text = "> $header`r`n" + ($lines -join "`r`n")
```

4. Append, copied from `snag.ps1`: `Get-Clipboard -Raw` inside `try/catch`; if it returns text, `$existing.TrimEnd("`r","`n") + "`r`n`r`n" + $text`. A throw or empty clipboard means replace.
5. `Set-Clipboard -Value $text`.
6. `Write-Host "[snag] copied $copied$(if ($append) { ' (appended)' })"` in `DarkGray`. No exit-code suffix.

On read failure, `Copy-SnagPreviousOutput` **returns**. It does not `exit`. An `exit` here would close an interactive PowerShell session, because `snag.ps1` dot-sources this file. Only the `-File` footer may `exit 1`. The footer checks a failure result from the orchestrator (a returned `$false`, or a thrown path the footer catches) and then exits. Dot-source callers (`snag` the function, the tests) never hit that footer.

### cmd classification (`snag.cmd`)

Keep `DisableDelayedExpansion` for the existing `%*` run path. A leading `setlocal EnableDelayedExpansion` may classify arguments, but `endlocal` back to delayed-expansion **off** before the run path so `!` inside a real command is unchanged.

Classify only the no-command form:

- No arguments → buffer mode.
- `%1` is `-?`, `/?`, or `--help` → usage, `exit /b 1`. Compare with quotes, `if "%~1"=="/?"`, so `if` does not treat `/?` as its own switch. Same quoting for `-?` and `--help`.
- `%1` is `-Last` (any following arguments) → usage, `exit /b 1`. Do not re-run.
- `%1` is `-Full` and `%2` is empty → buffer, `-Full`.
- `%1` is `-Append` and `%2` is empty → buffer, `-Append`.
- `%1`/`%2` are `-Full` and `-Append` in either order and `%3` is empty → buffer, both flags.
- `%2` is empty and `%1` starts with `-` or `/` → `snag: unknown option '%1'`, then usage, `exit /b 1`. Quote `"%~1"` in the `if` test.
- Anything else, including `snag -Full dir`, falls through to the existing run path with `%*` intact. Delete the old "no arguments prints usage" branch; that case is buffer mode now.

Buffer mode, still inside cmd (history must be captured here):

```bat
set "SNAG_HIST=%TEMP%\snag-hist-%RANDOM%%RANDOM%.txt"
doskey /history > "%SNAG_HIST%"
```

Quote the path. If `doskey` fails, print `snag: couldn't read cmd history` and `exit /b 1`. Then:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0snag-buffer.ps1" -FromCmd -HistoryFile "%SNAG_HIST%" -CurrentInvocation "snag -Full -Append"
```

Pass `-Full` / `-Append` only when those flags were set. `-CurrentInvocation` is the doskey line for this run, built with single spaces and the flags in the order the user typed (`snag`, `snag -Full`, `snag -Append`, `snag -Full -Append`, or `snag -Append -Full`).

Buffer mode does **not** fall through into the run body. A label does not stop `cmd`, and `del` replaces `%ERRORLEVEL%`, so capture the powershell exit code before deleting:

```bat
set "SNAG_EC=%ERRORLEVEL%"
del "%SNAG_HIST%"
exit /b %SNAG_EC%
```

Delete the history file even when powershell fails. The run path is a separate branch: the existing `SNAG_ARGFILE` + `%* 2>&1 | powershell ... snag-sink.ps1` body, reached only when the classifier did not take buffer mode or usage.

### PowerShell option parsing

The leading-switch loop only accepts arguments `-like '-*'`, so `/?` never enters it and would be executed as a command. Before that loop, if `$args.Count -ge 1` and `$args[0]` is exactly `/?`, print the usage block and `return`. Clipboard unchanged. Do not call `Copy-SnagPreviousOutput`.

Leave the rest of the loop as it is, including `-Last` rejecting extra arguments. In the `default` arm, keep `snag: unknown option '...'` and then print the usage block from the behavior spec (this is new; today it returns without usage). Inside the switch, `-?`, `-h`, and `--help` print that usage and `return`, with no unknown-option line. Usage must not fall through into `Copy-SnagPreviousOutput`.

Replace the `elseif ($cmdArgs.Count -eq 0)` usage `return` with the buffer-copy call. `-Last` is still handled before that branch, so `snag -Last` does not read the screen. `-?`, `-h`, `--help`, and a leading `/?` have already returned.

## File-by-file change list

| File | Change |
|---|---|
| `snag-buffer.ps1` | **New.** Header comment (buffer copy, ConPTY viewport, cursor-row exclusive, doskey duplicate collapse). `Join-SnagConsoleRows`, `Resolve-SnagCmdHistory`, `Select-SnagPreviousOutput`, `Read-SnagConsoleBuffer`, `Copy-SnagPreviousOutput`, `-File` entry. One code comment on the join: a row of length `Width` whose last character is not a space is glued to the next row. The footer does not delete the history file. |
| `tests/snag-previous-output.tests.ps1` | **New.** Dot-sources `snag-buffer.ps1`, asserts the cases below, exits 1 on any failure. CRLF, because `*.ps1` is CRLF in `.gitattributes`. |
| `snag.ps1` | Dot-source `snag-buffer.ps1` next to the file header. No-command branch calls the orchestrator. Usage text updated. Unknown options and `-?` print that usage. Header comment gains a bare-`snag` line. Run path, `-Last`, `-Full`, and `-Append` on a real command stay put. |
| `snag.cmd` | Classifier above the current body. Empty / flag-only → doskey + `snag-buffer.ps1`. Usage text updated. Run path unchanged. |
| `README.md` | Opening behavior, the usage-change sentence, usage-table rows, ConPTY vs conhost limit. |
| `snag-sink.ps1` | No change. |
| `install.ps1` | No change. |
| `.gitattributes` | No change. `*.ps1 text eol=crlf` already covers the new files. |

## Implementation steps

1. **[core]** Add `snag-buffer.ps1` with only the pure functions `Join-SnagConsoleRows`, `Resolve-SnagCmdHistory`, and `Select-SnagPreviousOutput`, plus the file header. Match the matching rule, continuation prefixes, anchor exclusion, blank trim, and the cmd duplicate-history rule in the algorithm section. No `Add-Type` and no `Set-Clipboard` yet, so the file loads on Linux under `pwsh`. `Add-Type` and `Set-Clipboard` must stay inside later functions, never at script scope, or this dot-source breaks.

2. **[core]** Add `tests/snag-previous-output.tests.ps1` and run it. Dot-source the buffer script; assert element-wise (do not use `ConvertTo-Json`, which differs between Windows PowerShell 5.1 and PowerShell 7). Print `ok` / `FAIL` per case and `exit 1` if any assertion failed. Cases are fixed in the test plan below.

3. **[core]** Add `Read-SnagConsoleBuffer` and `Copy-SnagPreviousOutput` to `snag-buffer.ps1`, then the `-File` footer (`-FromCmd`, `-HistoryFile`, `-CurrentInvocation`, `-Full`, `-Append`). Guard `Add-Type` inside the read function. Duplicate the trim / append / `Set-Clipboard` / `[snag] copied` block. Do not add `[exit N]`. Do not modify `$LASTEXITCODE`. Map `Partial` and `NoHistory` to the warning strings in the behavior spec. `Copy-SnagPreviousOutput` returns on failure; only the footer `exit`s. The footer does not delete `-HistoryFile`. Show the CRLF header replacement from the algorithm section. Empty output regions use the `start + segmentCount -ge anchor` check, not an unconditional `..`.

4. **[core]** Wire `snag.ps1`: dot-source `snag-buffer.ps1` from `$PSScriptRoot`, replace the empty-args usage return with `Copy-SnagPreviousOutput`, and extend `-?` / unknown-option handling. Leave the `-Last` block and the run-path tee byte-for-byte aside from the usage string those paths do not use.

5. **[core]** Wire `snag.cmd`: classify the flag-only forms, capture `doskey /history` into a temp file, call `powershell -File snag-buffer.ps1 -FromCmd -CurrentInvocation ...`, then `set SNAG_EC=%ERRORLEVEL%`, delete the history file, and `exit /b %SNAG_EC%`. Buffer mode must not fall through into the run path. Keep the existing run path under `DisableDelayedExpansion`. Update the usage echo.

6. **[core]** Update `README.md`: bare `snag` copies screen output and does not re-run; say explicitly that no-argument `snag` used to print usage; `-Last` is still the re-run; document the ConPTY viewport limit next to the other limits; add table rows for `snag`, `snag -Full`, `snag -Append`, and `snag -Full -Append` in both shells.

7. **[core]** Re-run `tests/snag-previous-output.tests.ps1` under `pwsh`. Do not treat a green run as coverage of the Win32 read, clipboard, or either shell's entry point. Those stay on the manual Windows list.

## Test plan

### Runnable here (Linux)

This agent has neither `pwsh` nor `powershell` on `PATH`, and it has no Windows console, so `Read-SnagConsoleBuffer`, `Set-Clipboard`, `Get-History`, and `doskey` cannot be exercised here.

What can run here is the pure parser: `Join-SnagConsoleRows` and `Select-SnagPreviousOutput`. The implementer installs PowerShell 7 (`pwsh`) as a test host only — not a repo dependency, not Pester — and runs:

```
pwsh -NoProfile -File tests/snag-previous-output.tests.ps1
```

Expected: exit 0, one `ok` line per case. The script must also pass under Windows PowerShell 5.1, but 5.1 is not available on this machine; the script simply cannot use PS 7-only syntax (`?.`, ternary, `&&`).

If `pwsh` cannot be installed, the script is still the deliverable and the Windows list is the only execution. Do not claim the console path was verified.

Assertions (expected `OutputLines`, `CommandText`, `Partial`, `NoHistory`):

1. **Simple prompt + output.** Shell `powershell`. History `git status`. Lines: `PS C:\repo> git status`, `On branch main`, `nothing to commit`, `PS C:\repo> snag`. Expect command `git status`, output those two result lines, both flags false.

2. **Previous command not in the buffer.** Same history, lines: `On branch main`, `nothing to commit`, `PS C:\repo> snag`. Expect `Partial = $true`, `NoHistory = $false`, command `git status`, output the two result lines.

3. **Command string also appears in the output; take the last match above the snag line.** History `git status`. Lines: `PS C:\repo> echo git status`, `git status`, `PS C:\repo> git status`, `On branch main`, `PS C:\repo> snag`. Expect output = `On branch main` only. The earlier `echo git status` line and the output line `git status` must not start the region.

4. **Multiline history.** History is `foreach ($i in 1..2) {` + newline + `$i` + newline + `}`. Lines: `PS C:\repo> foreach ($i in 1..2) {`, `>> $i`, `>> }`, `1`, `2`, `PS C:\repo> snag`. Shell `powershell`. Expect output `1`, `2`, and `CommandText` equal to the history string with `` `n `` separators. A cmd twin: history `echo one` + newline + `two`, screen lines `C:\> echo one`, `More? two`, `one`, `two`, `C:\> snag`, shell `cmd`, output `one`, `two`.

5. **Wrapped console rows.** Width 20. Each row is exactly 20 characters: `PS C:\> echo hello w`, `orld` + 16 spaces, `hello world` + 9 spaces, `PS C:\> snag` + 8 spaces. Join, then select with history `echo hello world`. The joined command line on screen is `PS C:\> echo hello world`. Expect `CommandText` `echo hello world` (the history text, not the screen line), `Partial` false, `NoHistory` false, output `hello world` only.

6. **Leading and trailing blank lines dropped; internal blanks kept.** Lines: `PS> cmd`, `''`, `out`, `''`, `more`, `''`, `PS> snag`. History `cmd`. Expect output `out`, `''`, `more`.

7. **Current snag line excluded.** Lines: `PS> echo hi`, `hi`, `PS> snag -Full`. History `echo hi`. Expect output `hi` only. `snag -Full` must not appear in `OutputLines` or `CommandText`.

8. **Empty output.** Lines: `PS> cmd`, `PS> snag`. History `cmd`. Expect `OutputLines` length 0, `Partial` false, command `cmd`.

9. **No history.** Lines: `some output`, `PS> snag`. History `''`. Expect `NoHistory = $true`, `Partial = $false`, `CommandText = ''`, output `some output`.

10. **cmd history, current line recorded.** `Resolve-SnagCmdHistory`. History lines `dir`, `snag`. Current invocation `snag`. Logical lines: `C:\repo> dir`, `file.txt`, `C:\repo> snag`. Expect history text `dir` (the in-flight `snag` is dropped because nothing above the anchor matches it).

11. **cmd history, consecutive `snag` collapsed.** `Resolve-SnagCmdHistory`. History lines `dir`, `snag` (the second `snag` was not stored). Current invocation `snag`. Logical lines: `C:\repo> dir`, `file.txt`, `C:\repo> snag`, `[snag] copied 1 lines`, `C:\repo> snag`. The earlier `C:\repo> snag` is a longer prompt-boundary match, so expect history text `snag`. Feeding that text to `Select-SnagPreviousOutput` with shell `cmd` then yields `CommandText` `snag` and output `[snag] copied 1 lines` only.

### Manual on Windows

Not runnable in this environment. Check both Windows PowerShell 5.1 and PowerShell 7, in classic conhost and in Windows Terminal (ConPTY).

- `git status` then `snag`. Clipboard is `> git status` plus the output that is still on screen. The command is not run a second time (no extra `git status` output appears).
- `snag -Full`, `snag -Append`, `snag -Full -Append`, `snag -Append -Full` on a command whose output is still visible. `-Append` keeps the previous clipboard and inserts a blank line. `-Full` does not insert an omission marker on a long buffer.
- `snag -Last` still prompts `y/N` and re-runs. Declining does not change the clipboard.
- A previous native failure that printed nothing: buffer copy does not invent `[exit N]` even if `$LASTEXITCODE` is set. The run path `snag cmd /c exit 3` still appends `[exit 3]`.
- Clear the screen, run a command that prints more than a viewport of lines, then `snag` in Windows Terminal. Expect the partial warning, a header from history, and only the visible tail. Repeat in conhost with a tall buffer: more of the command is available, and a hit on the command line does not warn.
- Previous command scrolled away entirely (command line gone): warning, history text in the header, rest of the viewport above `snag` copied.
- Multiline PowerShell command (backtick or an unclosed `{` so `>>` shows), then `snag`. Header is the history command, not the `>>` prompts. Output is what the command printed.
- cmd: `dir /b` then `snag`, then `snag -Append`. `doskey /history` is not empty and the header is `dir /b`, not `snag`.
- `snag -?` and `snag -Bogus` in both shells print usage and leave the clipboard alone. `snag` with no args does not print usage.
- Redirect: `snag > %TEMP%\snag-out.txt` from cmd, and a PowerShell host with stdout redirected. Error text, clipboard unchanged.
- Open a second PowerShell 5.1 session and run bare `snag` twice so `Add-Type` hits an already-loaded `Snag.ConsoleNative` and does not throw.
- Profile load: existing `install.ps1` line `. "...\snag.ps1"` still defines `snag`, and bare `snag` finds `snag-buffer.ps1` beside it.

## Risks and limits

- **Exact-width join.** A row of length `Width` whose last character is not a space is glued to the next row, even when the row contains spaces earlier (that is the wrap case, including test 5). The inverse also holds: a wrap that lands on a space is treated as a line end. One comment on `Join-SnagConsoleRows` states that.
- **ConPTY viewport.** Windows Terminal, VS Code, and Cursor use ConPTY. `ReadConsoleOutputCharacterW` sees the visible buffer, not the terminal's own scrollback. Classic conhost can include its scrollback up to the buffer height. The README must say this. Users with a long listing in Windows Terminal get a partial copy and the warning once the command line has left the viewport.
- **False command line.** If the real invocation has scrolled away and a later output line is still a boundary-suffix of the history text (`... git status`), the selector treats that line as the command and does not warn. Taking the last match fixes the case where the real line is still on screen.
- **Partial means "command line not found".** The copied text is then everything above `snag` still in the buffer, which may include older commands and may omit the top of the previous output.
- **cmd multiline.** `doskey /history` contributes one line. A cmd command that was entered across `More?` prompts is not reconstructed. If that single history line is not a suffix of the first screen line, the result is the partial path (whole region above `snag`, plus a warning), which is safe and inexact.
- **cmd duplicate collapse.** Consecutive identical lines are not both stored. `Resolve-SnagCmdHistory` keeps the last line when an earlier longer prompt-boundary match is already on screen. A line such as `C:\repo> echo snag` is also a longer match for invocation `snag`, so `echo snag` followed by `snag` can keep `snag` as the header and take the partial or mis-cut region. Same class of false match as the scrolled-away command line.
- **cmd invocation spacing.** `-CurrentInvocation` is built with single spaces. If the user typed `snag  -Full`, doskey's line does not equal that string, the last line is kept, and the header becomes the in-flight command. Normal `snag` / `snag -Full` / `snag -Append` spacing is the supported case.
- **Custom continuation prompts.** Only `>> ` (PowerShell) and `More? ` (cmd) count. Another prompt string fails the multiline match and falls through to the partial path.
- **Trailing continuation of `snag` itself.** Only the last non-blank logical line is removed. `snag -Full` is one short line, and visual wrap is joined first. A backtick-continued `snag` invocation would leave the earlier `>>` lines in the output. Out of scope for the normal no-command form.
- **Trailing spaces on the history command.** Screen lines are `TrimEnd`'d before the suffix check, so a history command with trailing spaces can miss and take the partial path.
- **Wide glyphs.** `ReadConsoleOutputCharacterW` returns one code unit per cell. A double-width character can show up as a character plus a null cell (turned into a space). Accept it.
- **Alternate screen.** Output that a pager drew on the alternate buffer is not in the main buffer after the pager exits.
- **Add-Type is session-sticky.** The type check avoids the second-load throw. Editing the C# in the same session will not refresh the type until a new process starts.
- **Duplicated trim.** The cap, append, and status line live in both `snag.ps1` and `Copy-SnagPreviousOutput`. They can drift. That is accepted to avoid rewriting the run path.
- **`$LASTEXITCODE` is stale** on purpose. Synthesizing `[exit N]` would lie about a command this mode did not run.
- **Linux cannot prove the console path.** A passing parser test says nothing about handles, ConPTY, doskey's code page, or `Set-Clipboard`.

## Decision log

Settled product decisions, not open:

1. Bare `snag` with no command, in both PowerShell and cmd, copies the previous command's already-printed output from the console screen buffer. It must not re-run that command.
2. `snag -Last` stays the re-run-with-confirmation behavior.
3. `-Full` and `-Append` combine with bare `snag` (`snag -Full`, `snag -Append`, `snag -Full -Append`, either flag order).
4. Clipboard shape matches a normal snag: `> <command>` header, then the output, CRLF, same trimming (`SNAG_MAX_LINES`, default 200, head quarter + tail, omission marker). `-Full` / `SNAG_MAX_LINES=0` keeps everything captured.
5. Do not synthesize `[exit N]` for buffer copies. `$LASTEXITCODE` may be stale. An exit line already visible in the capture is just output.
6. If the console buffer cannot be read (stdout is not a console), print a short error and do not change the clipboard.
7. If the previous command's line is not in the readable buffer, still copy the readable text above the current `snag` line and warn that the copy may be partial. Still include a `> ` header. If the command text is known from history but not visible, use the history text.
8. Windows Terminal / VS Code / Cursor use ConPTY. The Win32 buffer from `ReadConsoleOutputCharacter` is typically the visible viewport, not that terminal's scrollback. Document this in the README. Classic conhost can include its scrollback buffer.
9. Locate the previous command from history, not from prompt-shape guessing. PowerShell: `Get-History -Count 1` (the in-flight `snag` call is not in history yet). cmd: `doskey /history`, resolved by `Resolve-SnagCmdHistory`. The in-flight line is usually last, but a consecutive duplicate is not stored, so the last line is dropped only when no earlier longer prompt-boundary match for the current invocation is already on screen.
10. Exclude the current `snag` input line. Trim leading and trailing blank lines the same way `snag.ps1` already does.
11. One implementation of buffer reading and region selection, used by both shells. The pure "given buffer lines + history text, return command header and output lines" logic is its own function, testable without a console. Win32 P/Invoke is a separate function.
12. Tests cover the pure selector. Pester only if `pwsh` or `powershell` can run it; otherwise a small script that exits non-zero on failure. Required cases: simple prompt + output; previous command not in the buffer (partial); command string also appearing inside the output (last match above the current line); multiline history command; wrapped console rows joined into logical lines; trailing/leading blank lines dropped; current `snag` line excluded; empty output; no history.
13. `snag -?` and unknown options still explain usage, including the new no-command form. No-args used to print usage; it now copies the previous output. The usage change is explicit in this plan and in the README.
14. No new dependencies. Windows PowerShell 5.1 and PowerShell 7 both matter. `Add-Type` must tolerate the type already existing.
15. This environment is Linux and cannot exercise a Windows console. Verification splits into pure parser tests here and a manual Windows pass.

Planner choices that follow from those decisions:

- The shared file is `snag-buffer.ps1`. `snag.ps1` dot-sources it, so `install.ps1` does not change. cmd runs it with `-File` and passes a history file, because a child PowerShell does not share doskey history.
- Tests are `tests/snag-previous-output.tests.ps1`, a plain assert script, not Pester. Pester is not installed here, and adding a module would be a new dependency. `pwsh` may be installed as a test host.
- The clipboard trim block is duplicated in `Copy-SnagPreviousOutput` rather than extracted from `snag.ps1`.
- cmd does not learn `-Full` / `-Append` for the run-a-command path.
- The header is history text, not the screen line, so the prompt is not part of the copy.
- First-segment match is an ordinal boundary suffix (start, whitespace, or `>`), and the search takes the bottom-most full segment sequence above the snag line.
