# One-time setup for snag. Safe to re-run.
#   powershell -ExecutionPolicy Bypass -File install.ps1

$dir = $PSScriptRoot

# Warn about an existing, unrelated `snag` command.
$existing = Get-Command snag -All -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandType -ne 'Function' -and $_.Source -and (Split-Path $_.Source) -ne $dir }
foreach ($e in $existing) {
    Write-Warning "Another 'snag' exists at $($e.Source). In cmd, whichever comes first on PATH wins."
}

# 1. Put the folder on the user PATH (for cmd.exe -> snag.cmd).
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$entries = @($userPath -split ';' | Where-Object { $_ })
if ($entries -notcontains $dir) {
    [Environment]::SetEnvironmentVariable('Path', (($entries + $dir) -join ';'), 'User')
    Write-Host "Added $dir to user PATH."
} else {
    Write-Host "$dir already on user PATH."
}

# 2. Dot-source snag.ps1 from the PowerShell profile (for the `snag` function).
$line = ". `"$dir\snag.ps1`""
if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}
if (-not (Select-String -Path $PROFILE -SimpleMatch $line -Quiet)) {
    Add-Content -Path $PROFILE -Value "`r`n# snag`r`n$line" -Encoding UTF8
    Write-Host "Added snag to $PROFILE."
} else {
    Write-Host "snag already in $PROFILE."
}

# 3. The profile only loads if the execution policy allows local scripts.
$policy = Get-ExecutionPolicy
if ($policy -in 'Restricted', 'AllSigned') {
    Write-Warning "Execution policy is '$policy', so `$PROFILE won't load. Fix with:  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
}

Write-Host 'Done. Open a new terminal to use `snag`.'
