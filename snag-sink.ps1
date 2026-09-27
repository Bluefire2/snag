# CopyCat stdin tee, used by snag.cmd: echo each line as it arrives, then copy everything to the
# clipboard headed by "> <command line>" (read from the file snag.cmd wrote to $env:SNAG_ARGFILE).

$lines = [System.Collections.Generic.List[string]]::new()
while ($null -ne ($line = [Console]::In.ReadLine())) {
    [Console]::Out.WriteLine($line)
    $lines.Add($line)
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

$text = "> $cmdText`r`n" + ($lines -join "`r`n")
Set-Clipboard -Value $text
Write-Host "[snag] copied $($lines.Count) lines" -ForegroundColor DarkGray
