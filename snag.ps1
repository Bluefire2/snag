# snag for PowerShell. Dot-source this from $PROFILE.
#
#   snag git status                         # plain command + args
#   snag { Get-Process | select -first 5 }  # scriptblock for pipelines / complex lines
#   snag -Full git log                      # don't trim long output
#   snag -Last                              # re-run the previous history entry, after confirming
#   snag -Append git diff                   # add to the clipboard instead of replacing it
#
# Output streams to the console as usual; when the command finishes, "> <command>" plus the full
# output (stdout and stderr) is put on the clipboard. Output over $env:SNAG_MAX_LINES lines (default
# 200, 0 = no limit) keeps only its first quarter and the rest from the end, where errors usually are.

function snag {
    $maxLines = 200
    if ($env:SNAG_MAX_LINES -match '^\s*\d+\s*$') { $maxLines = [int]$env:SNAG_MAX_LINES }
    $last = $false
    $appendClip = $false

    # snag's own options come first; the first argument not starting with '-' begins the command.
    $skip = 0
    while ($skip -lt $args.Count -and $args[$skip] -is [string] -and $args[$skip] -like '-*') {
        switch ($args[$skip]) {
            '-Full' { $maxLines = 0 }
            '-Last' { $last = $true }
            '-Append' { $appendClip = $true }
            default {
                Write-Host "snag: unknown option '$($args[$skip])'" -ForegroundColor Yellow
                return
            }
        }
        $skip++
    }
    $cmdArgs = @($args | Select-Object -Skip $skip)

    if ($last) {
        if ($cmdArgs.Count -gt 0) {
            Write-Host 'snag: -Last takes no command' -ForegroundColor Yellow
            return
        }
        # The current `snag -Last` call isn't in history yet while it's still running, so this is
        # the command entered right before it.
        $h = Get-History -Count 1
        if (-not $h) {
            Write-Host 'snag: no previous command in history' -ForegroundColor Yellow
            return
        }
        $cmdText = $h.CommandLine
        $resp = Read-Host "snag: re-run '$cmdText'? [y/N]"
        if ($resp -notmatch '^[Yy]') {
            Write-Host 'snag: cancelled' -ForegroundColor Yellow
            return
        }
        $sb = [scriptblock]::Create($cmdText)
    } elseif ($cmdArgs.Count -eq 0) {
        Write-Host 'usage: snag [-Full] [-Append] <command> [args...]   or   snag [-Full] [-Append] { <pipeline> }   or   snag -Last' -ForegroundColor Yellow
        return
    } elseif ($cmdArgs.Count -eq 1 -and $cmdArgs[0] -is [scriptblock]) {
        $sb = $cmdArgs[0]
        $cmdText = $sb.ToString().Trim()
    } else {
        $sb = { $rest = @($cmdArgs | Select-Object -Skip 1); & $cmdArgs[0] @rest }
        $cmdText = ($cmdArgs | ForEach-Object {
            $s = "$_"
            if ($s -match '\s' -or $s -eq '') { '"' + $s + '"' } else { $s }
        }) -join ' '
    }

    # ANSI escapes (CSI colors/cursor moves, OSC titles/links) are stripped from the clipboard copy
    # only; the console still gets the raw text.
    $ansi = '\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])'

    $ErrorActionPreference = 'Continue'
    $lines = [System.Collections.Generic.List[string]]::new()

    # Clear $LASTEXITCODE so we can tell whether a native command ran (and put back the old value
    # if only cmdlets ran, so `snag` doesn't clobber it).
    $prevExit = $global:LASTEXITCODE
    $global:LASTEXITCODE = $null
    try {
        & $sb 2>&1 |
            ForEach-Object {
                # PS 5.1 wraps native stderr lines in ErrorRecords; render them as the plain text.
                if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { $_ }
            } |
            Out-String -Stream |
            ForEach-Object { Write-Host $_; $lines.Add(($_ -replace $ansi, '').TrimEnd()) }
    } catch {
        $msg = $_.ToString()
        Write-Host $msg -ForegroundColor Red
        $lines.Add($msg)
    }
    $exitCode = $global:LASTEXITCODE
    if ($null -eq $exitCode) { $global:LASTEXITCODE = $prevExit }

    # Formatted output (tables) is padded with blank lines at both ends; drop them.
    while ($lines.Count -gt 0 -and $lines[0] -eq '') { $lines.RemoveAt(0) }
    while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }

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
        $copied = '{0} of {1:N0} lines (snag -Full for all)' -f $maxLines, $total
    }

    $status = ''
    if ($exitCode) {
        $lines.Add("[exit $exitCode]")
        $status = " (exit $exitCode)"
    }

    $text = "> $cmdText`r`n" + ($lines -join "`r`n")
    if ($appendClip) {
        $existing = $null
        try { $existing = Get-Clipboard -Raw -ErrorAction Stop } catch {}
        if ($existing) { $text = $existing.TrimEnd("`r", "`n") + "`r`n`r`n" + $text }
    }
    Set-Clipboard -Value $text
    Write-Host "[snag] copied $copied$status$(if ($appendClip) { ' (appended)' })" -ForegroundColor DarkGray
}
