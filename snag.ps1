# snag for PowerShell. Dot-source this from $PROFILE.
#
#   snag                                    # copy the previous command's output already on screen
#   snag git status                         # plain command + args
#   snag { Get-Process | select -first 5 }  # scriptblock for pipelines / complex lines
#   snag -Append git diff                   # add to the clipboard instead of replacing it
#
# Output streams to the console as usual; when the command finishes, "> <command>" plus the full
# output (stdout and stderr) is put on the clipboard.

# Bare snag copies the screen buffer. Dot-sourced: an exit in that file would close this session.
. "$PSScriptRoot\snag-buffer.ps1"

function snag {
    $appendClip = $false
    $usage = "usage: snag [-Append]`n" +
        "       snag [-Append] <command> [args...]`n" +
        "       snag [-Append] { <pipeline> }`n" +
        "Bare snag copies the previous command's output already on screen."

    # The option loop only accepts '-*', so a leading /? would otherwise be run as a command.
    if ($args.Count -ge 1 -and $args[0] -is [string] -and $args[0] -eq '/?') {
        Write-Host $usage -ForegroundColor Yellow
        return
    }

    # snag's own options come first; the first argument not starting with '-' begins the command.
    $skip = 0
    while ($skip -lt $args.Count -and $args[$skip] -is [string] -and $args[$skip] -like '-*') {
        switch ($args[$skip]) {
            '-Append' { $appendClip = $true }
            '-?' { Write-Host $usage -ForegroundColor Yellow; return }
            '-h' { Write-Host $usage -ForegroundColor Yellow; return }
            '--help' { Write-Host $usage -ForegroundColor Yellow; return }
            default {
                Write-Host "snag: unknown option '$($args[$skip])'" -ForegroundColor Yellow
                Write-Host $usage -ForegroundColor Yellow
                return
            }
        }
        $skip++
    }
    $cmdArgs = @($args | Select-Object -Skip $skip)

    if ($cmdArgs.Count -eq 0) {
        # Already on screen. Do not re-run, and do not exit (this file is dot-sourced).
        $null = Copy-SnagPreviousOutput -Append:$appendClip
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
    Write-Host "[snag] copied $total lines$status$(if ($appendClip) { ' (appended)' })" -ForegroundColor DarkGray
}
