# snag stdin tee, used by snag.cmd: echo each line as it arrives, then copy everything to the
# clipboard headed by "> <command line>" (read from the file snag.cmd wrote to $env:SNAG_ARGFILE).

# ANSI escapes are stripped from the clipboard copy only (see snag.ps1).
$ansi = '\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])'

$lines = [System.Collections.Generic.List[string]]::new()
while ($null -ne ($line = [Console]::In.ReadLine())) {
    [Console]::Out.WriteLine($line)
    $lines.Add(($line -replace $ansi, '').TrimEnd())
}

$cmdText = ''
if ($env:SNAG_ARGFILE -and (Test-Path -LiteralPath $env:SNAG_ARGFILE)) {
    # cmd wrote the echoed line, e.g. "C:\dir>(rem #<args># ) ", in the console code page.
    $enc = [System.Text.Encoding]::GetEncoding([Console]::OutputEncoding.CodePage)
    foreach ($l in [System.IO.File]::ReadAllLines($env:SNAG_ARGFILE, $enc)) {
        if ($l -match 'rem #(.*)#') { $cmdText = $Matches[1].Trim(); break }
    }
    Remove-Item -LiteralPath $env:SNAG_ARGFILE -ErrorAction SilentlyContinue
}

# Long output keeps its first quarter and the rest from the end (see snag.ps1).
$maxLines = 200
if ($env:SNAG_MAX_LINES -match '^\s*\d+\s*$') { $maxLines = [int]$env:SNAG_MAX_LINES }
$total = $lines.Count
$copied = "$total lines"
if ($maxLines -gt 0 -and $total -gt $maxLines) {
    $head = [int][Math]::Floor($maxLines / 4)
    $tail = $maxLines - $head
    $kept = [System.Collections.Generic.List[string]]::new()
    $kept.AddRange($lines.GetRange(0, $head))
    $kept.Add(('... [{0:N0} lines omitted] ...' -f ($total - $maxLines)))
    $kept.AddRange($lines.GetRange($total - $tail, $tail))
    $lines = $kept
    $copied = '{0} of {1:N0} lines (set SNAG_MAX_LINES=0 for all)' -f $maxLines, $total
}

$text = "> $cmdText`r`n" + ($lines -join "`r`n")
Set-Clipboard -Value $text
Write-Host "[snag] copied $copied" -ForegroundColor DarkGray
