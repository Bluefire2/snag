# Copies the previous command's already-printed console output. Does not re-run it.
# ReadConsoleOutputCharacterW sees the Win32 screen buffer: the viewport under ConPTY
# (Windows Terminal, VS Code, Cursor), and conhost scrollback up to the buffer height.
# Rows are read up to but not including the cursor row, so the echoed snag line is the
# last row captured. doskey collapses consecutive identical lines, so the in-flight
# cmd invocation is dropped only when the screen has no earlier longer prompt match.

function Get-SnagAnchorIndex {
    param([string[]]$LogicalLines)

    if ($null -eq $LogicalLines) { return -1 }
    for ($i = $LogicalLines.Count - 1; $i -ge 0; $i--) {
        $line = $LogicalLines[$i]
        if ($null -ne $line -and -not [string]::IsNullOrWhiteSpace($line)) { return $i }
    }
    return -1
}

# Ordinal suffix match: the line equals the segment, or ends with it and the character
# immediately before is whitespace or '>'. Not a regex; command text may contain . ( ) |
function Test-SnagBoundaryMatch {
    param([string]$Line, [string]$Segment)

    if ($null -eq $Line) { $Line = '' }
    if ($null -eq $Segment) { $Segment = '' }
    $trimmed = $Line.TrimEnd()
    if ($Segment.Length -eq 0) {
        if ($trimmed.Length -eq 0) { return $true }
        $before = $trimmed[$trimmed.Length - 1]
        return ([char]::IsWhiteSpace($before) -or $before -eq [char]'>')
    }
    if (-not $trimmed.EndsWith($Segment, [System.StringComparison]::Ordinal)) { return $false }
    if ($trimmed.Length -eq $Segment.Length) { return $true }
    $before = $trimmed[$trimmed.Length - $Segment.Length - 1]
    return ([char]::IsWhiteSpace($before) -or $before -eq [char]'>')
}

function Test-SnagContinuationMatch {
    param([string]$Line, [string]$Segment, [string]$Prefix)

    if ($null -eq $Line) { $Line = '' }
    if ($null -eq $Segment) { $Segment = '' }
    $trimmed = $Line.TrimEnd()
    # An empty segment is a bare continuation prompt. prefix + '' still has a trailing
    # space, which TrimEnd removes, so compare the trimmed prompt text directly.
    if ($Segment.Length -eq 0) {
        return ($trimmed.Length -eq 0 -or $trimmed -eq '>>' -or $trimmed -eq 'More?')
    }
    if ($trimmed.Equals($Segment, [System.StringComparison]::Ordinal)) { return $true }
    $withPrefix = $Prefix + $Segment
    return $trimmed.Equals($withPrefix, [System.StringComparison]::Ordinal)
}

# Indexes Start..EndInclusive, then drop leading and trailing '' only. Never built with
# PowerShell '..': 1..0 contains both ends, and 0..-1 is not empty.
function Get-SnagTrimmedSlice {
    param([string[]]$LogicalLines, [int]$Start, [int]$EndInclusive)

    $list = [System.Collections.Generic.List[string]]::new()
    if ($Start -le $EndInclusive -and $null -ne $LogicalLines) {
        for ($i = $Start; $i -le $EndInclusive; $i++) {
            $item = $LogicalLines[$i]
            if ($null -eq $item) { $item = '' }
            $list.Add([string]$item)
        }
    }
    while ($list.Count -gt 0 -and $list[0] -eq '') { $list.RemoveAt(0) }
    while ($list.Count -gt 0 -and $list[$list.Count - 1] -eq '') { $list.RemoveAt($list.Count - 1) }
    return ,$list.ToArray()
}

function Join-SnagConsoleRows {
    param([string[]]$Rows, [int]$Width)

    $lines = [System.Collections.Generic.List[string]]::new()
    $pending = ''
    if ($null -ne $Rows) {
        foreach ($row in $Rows) {
            if ($null -eq $row) { $row = '' }
            # A row of length Width whose last character is not a space is glued to the next row.
            $continues = $false
            if ($Width -gt 0 -and $row.Length -eq $Width -and $row[$row.Length - 1] -ne ' ') {
                $continues = $true
            }
            if ($continues) {
                $pending = $pending + $row
            } else {
                $lines.Add($pending + $row.TrimEnd(' '))
                $pending = ''
            }
        }
    }
    if ($pending.Length -gt 0) { $lines.Add($pending) }
    return ,$lines.ToArray()
}

# doskey stores the typed text (.\snag.cmd, snag -full, Snag). The batch file passes
# a canonical invocation (snag, snag -Full). Same call when the command name is snag.
function Get-SnagCmdInvocationKey {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    $t = $Line.Trim()
    $token = ''
    $rest = ''
    if ($t.StartsWith('"')) {
        $end = $t.IndexOf('"', 1)
        if ($end -lt 1) { return $null }
        $token = $t.Substring(1, $end - 1)
        $rest = $t.Substring($end + 1).TrimStart()
    } else {
        $sp = $t.IndexOf(' ')
        if ($sp -lt 0) {
            $token = $t
        } else {
            $token = $t.Substring(0, $sp)
            $rest = $t.Substring($sp + 1).TrimStart()
        }
    }
    $base = [System.IO.Path]::GetFileNameWithoutExtension([System.IO.Path]::GetFileName($token))
    if (-not [string]::Equals($base, 'snag', [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    if ($rest.Length -eq 0) { return 'snag' }
    return 'snag ' + $rest
}

function Resolve-SnagCmdHistory {
    param(
        [string[]]$HistoryLines,
        [string]$CurrentInvocation,
        [string[]]$LogicalLines
    )

    if ($null -eq $CurrentInvocation) { $CurrentInvocation = '' }
    $hist = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $HistoryLines) {
        foreach ($line in $HistoryLines) {
            if ($null -eq $line) { $hist.Add('') } else { $hist.Add([string]$line) }
        }
    }
    while ($hist.Count -gt 0 -and $hist[$hist.Count - 1].Length -eq 0) {
        $hist.RemoveAt($hist.Count - 1)
    }
    if ($hist.Count -eq 0) { return '' }

    $last = $hist[$hist.Count - 1]
    # Search the screen with $last: the boundary match is ordinal, and the screen
    # shows what was typed. Equality uses the command name, so .\snag.cmd matches snag.
    $typedKey = Get-SnagCmdInvocationKey $last
    $canonKey = Get-SnagCmdInvocationKey $CurrentInvocation
    $same = $false
    if ($null -ne $typedKey -and $null -ne $canonKey) {
        $same = [string]::Equals($typedKey, $canonKey, [System.StringComparison]::OrdinalIgnoreCase)
    } else {
        $same = [string]::Equals($last, $CurrentInvocation, [System.StringComparison]::OrdinalIgnoreCase)
    }
    if ($same) {
        # Consecutive duplicates are not stored. Keep last when an earlier line above the
        # anchor is a longer prompt-boundary match; otherwise last is the in-flight command.
        $longer = $false
        $anchor = Get-SnagAnchorIndex -LogicalLines $LogicalLines
        if ($anchor -gt 0) {
            for ($i = $anchor - 1; $i -ge 0; $i--) {
                $line = $LogicalLines[$i]
                if ($null -eq $line) { $line = '' }
                $trimmed = $line.TrimEnd()
                $isLonger = $trimmed.Length -gt $last.Length
                if ($isLonger -and (Test-SnagBoundaryMatch -Line $trimmed -Segment $last)) {
                    $longer = $true
                    break
                }
            }
        }
        if (-not $longer) {
            $hist.RemoveAt($hist.Count - 1)
            while ($hist.Count -gt 0 -and $hist[$hist.Count - 1].Length -eq 0) {
                $hist.RemoveAt($hist.Count - 1)
            }
            if ($hist.Count -eq 0) { return '' }
            return [string]$hist[$hist.Count - 1]
        }
    }
    return [string]$last
}

function Select-SnagPreviousOutput {
    param(
        [string[]]$LogicalLines,
        [string]$HistoryText,
        [ValidateSet('powershell', 'cmd')][string]$Shell
    )

    if ($null -eq $LogicalLines) { $LogicalLines = @() }
    $anchor = Get-SnagAnchorIndex -LogicalLines $LogicalLines

    $above = [string[]]::new(0)
    if ($anchor -gt 0) {
        $above = Get-SnagTrimmedSlice -LogicalLines $LogicalLines -Start 0 -EndInclusive ($anchor - 1)
    }

    if ([string]::IsNullOrEmpty($HistoryText)) {
        return [pscustomobject]@{
            CommandText = ''
            OutputLines = $above
            Partial     = $false
            NoHistory   = $true
        }
    }

    $history = $HistoryText
    if ($history.EndsWith("`r`n", [System.StringComparison]::Ordinal)) {
        $history = $history.Substring(0, $history.Length - 2)
    } elseif ($history.EndsWith("`n", [System.StringComparison]::Ordinal)) {
        $history = $history.Substring(0, $history.Length - 1)
    } elseif ($history.EndsWith("`r", [System.StringComparison]::Ordinal)) {
        $history = $history.Substring(0, $history.Length - 1)
    }
    $segments = [regex]::Split($history, "`r`n|`n|`r")
    $commandText = $segments -join "`n"

    $prefix = '>> '
    if ($Shell -eq 'cmd') { $prefix = 'More? ' }

    $matchStart = -1
    $segmentCount = $segments.Length
    if ($anchor -gt 0 -and $segmentCount -gt 0) {
        for ($start = $anchor - 1; $start -ge 0; $start--) {
            # Continuations have to stay strictly above the snag line.
            if (($start + $segmentCount - 1) -ge $anchor) { continue }
            if (-not (Test-SnagBoundaryMatch -Line $LogicalLines[$start] -Segment $segments[0])) { continue }
            $matched = $true
            for ($k = 1; $k -lt $segmentCount; $k++) {
                $contLine = $LogicalLines[$start + $k]
                if (-not (Test-SnagContinuationMatch -Line $contLine -Segment $segments[$k] -Prefix $prefix)) {
                    $matched = $false
                    break
                }
            }
            if ($matched) {
                $matchStart = $start
                break
            }
        }
    }

    if ($matchStart -lt 0) {
        return [pscustomobject]@{
            CommandText = $commandText
            OutputLines = $above
            Partial     = $true
            NoHistory   = $false
        }
    }

    $regionStart = $matchStart + $segmentCount
    # start + segmentCount >= anchor means the command sits on the line directly above snag.
    if ($regionStart -ge $anchor) {
        $output = [string[]]::new(0)
    } else {
        $output = Get-SnagTrimmedSlice -LogicalLines $LogicalLines -Start $regionStart -EndInclusive ($anchor - 1)
    }
    return [pscustomobject]@{
        CommandText = $commandText
        OutputLines = $output
        Partial     = $false
        NoHistory   = $false
    }
}

function Read-SnagConsoleBuffer {
    if (-not ('Snag.ConsoleNative' -as [type])) {
        # Add-Type cannot unload a type; a second add of the same name throws.
        $csharp = @'
using System;
using System.Runtime.InteropServices;

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

        // ExactSpelling skips the W-suffix probe, which would look up "WW" first.
        [DllImport("kernel32.dll", EntryPoint = "ReadConsoleOutputCharacterW",
            SetLastError = true, CharSet = CharSet.Unicode, ExactSpelling = true)]
        public static extern bool ReadConsoleOutputCharacter(
            IntPtr hConsoleOutput, [Out] char[] lpCharacter, int nLength,
            COORD dwReadCoord, out int lpNumberOfCharsRead);

        // Null cells become spaces and each row is padded to width, in C# so a tall
        // conhost scrollback is not a PowerShell loop per cell. Fills rows; returns
        // false if a read fails. An empty result (cursor on row 0) is success.
        public static bool ReadRows(IntPtr handle, int width, int cursorY, System.Collections.Generic.List<string> rows) {
            rows.Clear();
            if (width <= 0 || cursorY <= 0) return true;
            char[] buf = new char[width];
            for (int y = 0; y < cursorY; y++) {
                int nRead;
                COORD coord = new COORD();
                coord.X = 0;
                coord.Y = (short)y;
                if (!ReadConsoleOutputCharacter(handle, buf, width, coord, out nRead)) return false;
                int copy = nRead;
                if (copy > width) copy = width;
                if (copy < 0) copy = 0;
                char[] chars = new char[width];
                for (int c = 0; c < width; c++) chars[c] = ' ';
                for (int c = 0; c < copy; c++) {
                    char ch = buf[c];
                    chars[c] = ch == '\0' ? ' ' : ch;
                }
                rows.Add(new string(chars));
            }
            while (rows.Count > 0) {
                string tail = rows[rows.Count - 1];
                bool blank = true;
                for (int c = 0; c < tail.Length; c++) {
                    if (tail[c] != ' ') { blank = false; break; }
                }
                if (!blank) break;
                rows.RemoveAt(rows.Count - 1);
            }
            return true;
        }
    }
}
'@
        try {
            Add-Type -TypeDefinition $csharp
        } catch {
            if (-not ('Snag.ConsoleNative' -as [type])) { return $null }
        }
    }

    try {
        $handle = [Snag.ConsoleNative]::GetStdHandle(-11)
        $invalid = [IntPtr]::new(-1)
        if ($handle.Equals([IntPtr]::Zero) -or $handle.Equals($invalid)) { return $null }

        $info = New-Object Snag.ConsoleNative+CONSOLE_SCREEN_BUFFER_INFO
        $got = [Snag.ConsoleNative]::GetConsoleScreenBufferInfo($handle, [ref]$info)
        if (-not $got) { return $null }

        # srWindow is ignored: row 0 is the top of the Win32 buffer (the ConPTY viewport).
        $width = [int]$info.dwSize.X
        $cursorY = [int]$info.dwCursorPosition.Y
        if ($width -le 0) { return $null }

        $rows = [System.Collections.Generic.List[string]]::new()
        # cursorY of 0 reads nothing. ReadRows returns false only when a row read fails.
        $readOk = [Snag.ConsoleNative]::ReadRows($handle, $width, $cursorY, $rows)
        if (-not $readOk) { return $null }

        return [pscustomobject]@{
            Width = $width
            Rows  = $rows.ToArray()
        }
    } catch {
        return $null
    }
}

function Copy-SnagPreviousOutput {
    param(
        [int]$MaxLines,
        [switch]$Append,
        [switch]$FromCmd,
        [string]$HistoryFile,
        [string]$CurrentInvocation
    )

    # Before any Write-Host, so snag's own messages are not part of the capture.
    $read = Read-SnagConsoleBuffer
    if ($null -eq $read) {
        Write-Host "snag: stdout isn't a console, so the previous output can't be copied" -ForegroundColor Yellow
        return $false
    }

    $rows = @()
    if ($null -ne $read.Rows) { $rows = @($read.Rows) }
    $logical = Join-SnagConsoleRows -Rows $rows -Width ([int]$read.Width)

    $shellName = 'powershell'
    $historyText = ''
    if ($FromCmd) {
        $readable = $false
        if (-not [string]::IsNullOrEmpty($HistoryFile)) {
            $readable = Test-Path -LiteralPath $HistoryFile -ErrorAction SilentlyContinue
        }
        if (-not $readable) {
            Write-Host "snag: couldn't read cmd history" -ForegroundColor Yellow
            return $false
        }
        try {
            $enc = [System.Text.Encoding]::GetEncoding([Console]::OutputEncoding.CodePage)
            $historyLines = [System.IO.File]::ReadAllLines($HistoryFile, $enc)
        } catch {
            Write-Host "snag: couldn't read cmd history" -ForegroundColor Yellow
            return $false
        }
        if ($null -eq $CurrentInvocation) { $CurrentInvocation = '' }
        $historyText = Resolve-SnagCmdHistory -HistoryLines $historyLines -CurrentInvocation $CurrentInvocation -LogicalLines $logical
        $shellName = 'cmd'
    } else {
        $h = Get-History -Count 1
        if ($h -and $null -ne $h.CommandLine) { $historyText = [string]$h.CommandLine }
    }

    $selected = Select-SnagPreviousOutput -LogicalLines $logical -HistoryText $historyText -Shell $shellName

    if ($selected.NoHistory) {
        Write-Host 'snag: no previous command in history; copying the screen above this line' -ForegroundColor Yellow
    } elseif ($selected.Partial) {
        Write-Host "snag: the previous command isn't in the readable screen buffer; the copy may be partial" -ForegroundColor Yellow
    }

    $max = 200
    if ($PSBoundParameters.ContainsKey('MaxLines')) {
        $max = $MaxLines
    } elseif ($env:SNAG_MAX_LINES -match '^\s*\d+\s*$') {
        $max = [int]$env:SNAG_MAX_LINES
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $selected.OutputLines) {
        foreach ($ol in @($selected.OutputLines)) { $lines.Add([string]$ol) }
    }

    $total = $lines.Count
    $copied = "$total lines"
    if ($max -gt 0 -and $total -gt $max) {
        $head = [int][Math]::Floor($max / 4)
        $tail = $max - $head
        $kept = [System.Collections.Generic.List[string]]::new()
        $kept.AddRange($lines.GetRange(0, $head))
        $kept.Add(('... [{0:N0} lines omitted] ...' -f ($total - $max)))
        $kept.AddRange($lines.GetRange($total - $tail, $tail))
        $lines = $kept
        $copied = '{0} of {1:N0} lines (snag -Full for all)' -f $max, $total
    }

    $CommandText = $selected.CommandText
    if ($null -eq $CommandText) { $CommandText = '' }
    $header = $CommandText -replace "`r`n|`n|`r", "`r`n"
    $text = "> $header`r`n" + ($lines -join "`r`n")
    if ($Append) {
        $existing = $null
        try { $existing = Get-Clipboard -Raw -ErrorAction Stop } catch {}
        if ($existing) { $text = $existing.TrimEnd("`r", "`n") + "`r`n`r`n" + $text }
    }
    Set-Clipboard -Value $text
    Write-Host "[snag] copied $copied$(if ($Append) { ' (appended)' })" -ForegroundColor DarkGray
    return $true
}

# -File entry for snag.cmd. Not used when snag.ps1 or the tests dot-source this file:
# exit would close an interactive session. This footer does not delete -HistoryFile.
if ($MyInvocation.InvocationName -ne '.') {
    $fromCmd = $false
    $historyFile = ''
    $currentInvocation = ''
    $full = $false
    $appendFlag = $false
    $bad = $false
    $i = 0
    while ($i -lt $args.Count) {
        $a = [string]$args[$i]
        if ($a -eq '-FromCmd') {
            $fromCmd = $true
            $i++
        } elseif ($a -eq '-HistoryFile') {
            $i++
            if ($i -ge $args.Count) { $bad = $true; break }
            $historyFile = [string]$args[$i]
            $i++
        } elseif ($a -eq '-CurrentInvocation') {
            $i++
            if ($i -ge $args.Count) { $bad = $true; break }
            $currentInvocation = [string]$args[$i]
            $i++
        } elseif ($a -eq '-Full') {
            $full = $true
            $i++
        } elseif ($a -eq '-Append') {
            $appendFlag = $true
            $i++
        } else {
            $bad = $true
            break
        }
    }

    if ($bad -or -not $fromCmd) { exit 1 }

    $ok = $false
    try {
        $splat = @{
            FromCmd           = $true
            HistoryFile       = $historyFile
            CurrentInvocation = $currentInvocation
            Append            = $appendFlag
        }
        if ($full) { $splat['MaxLines'] = 0 }
        $ok = Copy-SnagPreviousOutput @splat
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Yellow
        exit 1
    }
    if (-not $ok) { exit 1 }
    exit 0
}
