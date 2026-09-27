# CopyCat: `snag` for PowerShell. Dot-source this from $PROFILE.
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

    $ErrorActionPreference = 'Continue'
    $lines = [System.Collections.Generic.List[string]]::new()
    try {
        & $sb 2>&1 |
            ForEach-Object {
                # PS 5.1 wraps native stderr lines in ErrorRecords; render them as the plain text.
                if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { $_ }
            } |
            Out-String -Stream |
            ForEach-Object { Write-Host $_; $lines.Add($_.TrimEnd()) }
    } catch {
        $msg = $_.ToString()
        Write-Host $msg -ForegroundColor Red
        $lines.Add($msg)
    }

    # Formatted output (tables) is padded with blank lines at both ends; drop them.
    while ($lines.Count -gt 0 -and $lines[0] -eq '') { $lines.RemoveAt(0) }
    while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }

    $text = "> $cmdText`r`n" + ($lines -join "`r`n")
    Set-Clipboard -Value $text
    Write-Host "[snag] copied $($lines.Count) lines" -ForegroundColor DarkGray
}
