# snag for PowerShell. Dot-source this from $PROFILE.
#
#   snag git status                         # plain command + args
#   snag { Get-Process | select -first 5 }  # scriptblock for pipelines / complex lines
#
# Output streams to the console as usual; when the command finishes, "> <command>" plus the full
# output (stdout and stderr) is put on the clipboard.

function snag {
    if ($args.Count -eq 0) {
        Write-Host 'usage: snag <command> [args...]   or   snag { <pipeline> }' -ForegroundColor Yellow
        return
    }

    if ($args.Count -eq 1 -and $args[0] -is [scriptblock]) {
        $sb = $args[0]
        $cmdText = $sb.ToString().Trim()
    } else {
        $cmdArgs = $args
        $sb = { $rest = @($cmdArgs | Select-Object -Skip 1); & $cmdArgs[0] @rest }
        $cmdText = ($args | ForEach-Object {
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

    $count = $lines.Count
    $status = ''
    if ($exitCode) {
        $lines.Add("[exit $exitCode]")
        $status = " (exit $exitCode)"
    }

    $text = "> $cmdText`r`n" + ($lines -join "`r`n")
    Set-Clipboard -Value $text
    Write-Host "[snag] copied $count lines$status" -ForegroundColor DarkGray
}
