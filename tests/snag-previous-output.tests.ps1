# Pure parser tests for bare snag. No Pester, no console, no PS 7-only syntax.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'snag-buffer.ps1')

$failed = 0

function Assert-SnagCase {
    param(
        [string]$Name,
        $Result,
        [string]$CommandText,
        [string[]]$OutputLines,
        [bool]$Partial,
        [bool]$NoHistory
    )

    $ok = $true
    $why = ''
    if ($Result.CommandText -cne $CommandText) {
        $ok = $false
        $why = $why + " CommandText=[$($Result.CommandText)]"
    }
    if ($Result.Partial -ne $Partial) {
        $ok = $false
        $why = $why + " Partial=$($Result.Partial)"
    }
    if ($Result.NoHistory -ne $NoHistory) {
        $ok = $false
        $why = $why + " NoHistory=$($Result.NoHistory)"
    }

    $actual = @()
    if ($null -ne $Result.OutputLines) { $actual = @($Result.OutputLines) }
    if ($actual.Count -ne $OutputLines.Count) {
        $ok = $false
        $why = $why + " OutputCount=$($actual.Count) expected=$($OutputLines.Count)"
    } else {
        for ($i = 0; $i -lt $OutputLines.Count; $i++) {
            if ($actual[$i] -cne $OutputLines[$i]) {
                $ok = $false
                $why = $why + " line${i}=[$($actual[$i])]"
            }
        }
    }

    if ($ok) {
        Write-Host "ok $Name"
    } else {
        Write-Host "FAIL $Name$why"
        $script:failed++
    }
}

# 1. Simple prompt + output.
$r = Select-SnagPreviousOutput -LogicalLines @(
    'PS C:\repo> git status',
    'On branch main',
    'nothing to commit',
    'PS C:\repo> snag'
) -HistoryText 'git status' -Shell powershell
Assert-SnagCase -Name '1 simple prompt' -Result $r -CommandText 'git status' `
    -OutputLines @('On branch main', 'nothing to commit') -Partial $false -NoHistory $false

# 2. Previous command not in the buffer.
$r = Select-SnagPreviousOutput -LogicalLines @(
    'On branch main',
    'nothing to commit',
    'PS C:\repo> snag'
) -HistoryText 'git status' -Shell powershell
Assert-SnagCase -Name '2 command not in buffer' -Result $r -CommandText 'git status' `
    -OutputLines @('On branch main', 'nothing to commit') -Partial $true -NoHistory $false

# 3. Command string also appears in the output; take the last match above snag.
$r = Select-SnagPreviousOutput -LogicalLines @(
    'PS C:\repo> echo git status',
    'git status',
    'PS C:\repo> git status',
    'On branch main',
    'PS C:\repo> snag'
) -HistoryText 'git status' -Shell powershell
Assert-SnagCase -Name '3 last match above snag' -Result $r -CommandText 'git status' `
    -OutputLines @('On branch main') -Partial $false -NoHistory $false

# 4. Multiline history, PowerShell and cmd.
$psHist = 'foreach ($i in 1..2) {' + "`n" + '$i' + "`n" + '}'
$r = Select-SnagPreviousOutput -LogicalLines @(
    'PS C:\repo> foreach ($i in 1..2) {',
    '>> $i',
    '>> }',
    '1',
    '2',
    'PS C:\repo> snag'
) -HistoryText $psHist -Shell powershell
$cmdHist = 'echo one' + "`n" + 'two'
$rCmd = Select-SnagPreviousOutput -LogicalLines @(
    'C:\> echo one',
    'More? two',
    'one',
    'two',
    'C:\> snag'
) -HistoryText $cmdHist -Shell cmd
$case4Ok = $true
$case4Why = ''
if ($r.CommandText -cne $psHist -or $r.Partial -or $r.NoHistory) {
    $case4Ok = $false
    $case4Why = $case4Why + " ps CommandText=[$($r.CommandText)] Partial=$($r.Partial) NoHistory=$($r.NoHistory)"
}
$psOut = @()
if ($null -ne $r.OutputLines) { $psOut = @($r.OutputLines) }
if ($psOut.Count -ne 2 -or $psOut[0] -cne '1' -or $psOut[1] -cne '2') {
    $case4Ok = $false
    $case4Why = $case4Why + ' ps output mismatch'
}
if ($rCmd.CommandText -cne $cmdHist -or $rCmd.Partial -or $rCmd.NoHistory) {
    $case4Ok = $false
    $case4Why = $case4Why + " cmd CommandText=[$($rCmd.CommandText)] Partial=$($rCmd.Partial)"
}
$cmdOut = @()
if ($null -ne $rCmd.OutputLines) { $cmdOut = @($rCmd.OutputLines) }
if ($cmdOut.Count -ne 2 -or $cmdOut[0] -cne 'one' -or $cmdOut[1] -cne 'two') {
    $case4Ok = $false
    $case4Why = $case4Why + ' cmd output mismatch'
}
if ($case4Ok) {
    Write-Host 'ok 4 multiline history'
} else {
    Write-Host "FAIL 4 multiline history$case4Why"
    $failed++
}

# 5. Wrapped console rows.
$width = 20
function New-SnagTestRow {
    param([string]$Text, [int]$Width)
    return $Text + (' ' * ($Width - $Text.Length))
}
$rows = @(
    (New-SnagTestRow 'PS C:\> echo hello w' $width),
    (New-SnagTestRow 'orld' $width),
    (New-SnagTestRow 'hello world' $width),
    (New-SnagTestRow 'PS C:\> snag' $width)
)
$joined = Join-SnagConsoleRows -Rows $rows -Width $width
$r = Select-SnagPreviousOutput -LogicalLines $joined -HistoryText 'echo hello world' -Shell powershell
Assert-SnagCase -Name '5 wrapped rows' -Result $r -CommandText 'echo hello world' `
    -OutputLines @('hello world') -Partial $false -NoHistory $false

# 6. Leading and trailing blanks dropped; internal blanks kept.
$r = Select-SnagPreviousOutput -LogicalLines @(
    'PS> cmd',
    '',
    'out',
    '',
    'more',
    '',
    'PS> snag'
) -HistoryText 'cmd' -Shell powershell
Assert-SnagCase -Name '6 blank trim' -Result $r -CommandText 'cmd' `
    -OutputLines @('out', '', 'more') -Partial $false -NoHistory $false

# 7. Current snag line excluded.
$r = Select-SnagPreviousOutput -LogicalLines @(
    'PS> echo hi',
    'hi',
    'PS> snag -Full'
) -HistoryText 'echo hi' -Shell powershell
Assert-SnagCase -Name '7 snag line excluded' -Result $r -CommandText 'echo hi' `
    -OutputLines @('hi') -Partial $false -NoHistory $false

# 8. Empty output.
$r = Select-SnagPreviousOutput -LogicalLines @(
    'PS> cmd',
    'PS> snag'
) -HistoryText 'cmd' -Shell powershell
Assert-SnagCase -Name '8 empty output' -Result $r -CommandText 'cmd' `
    -OutputLines @() -Partial $false -NoHistory $false

# 9. No history.
$r = Select-SnagPreviousOutput -LogicalLines @(
    'some output',
    'PS> snag'
) -HistoryText '' -Shell powershell
Assert-SnagCase -Name '9 no history' -Result $r -CommandText '' `
    -OutputLines @('some output') -Partial $false -NoHistory $true

# 10. cmd history, current line recorded. In-flight snag is dropped.
$logical10 = @('C:\repo> dir', 'file.txt', 'C:\repo> snag')
$h10 = Resolve-SnagCmdHistory -HistoryLines @('dir', 'snag') -CurrentInvocation 'snag' -LogicalLines $logical10
if ($h10 -cne 'dir') {
    Write-Host "FAIL 10 cmd history recorded history=[$h10]"
    $failed++
} else {
    Write-Host 'ok 10 cmd history recorded'
}

# 11. cmd history, consecutive snag collapsed. Earlier longer prompt match keeps last.
$logical11 = @(
    'C:\repo> dir',
    'file.txt',
    'C:\repo> snag',
    '[snag] copied 1 lines',
    'C:\repo> snag'
)
$h11 = Resolve-SnagCmdHistory -HistoryLines @('dir', 'snag') -CurrentInvocation 'snag' -LogicalLines $logical11
$r = Select-SnagPreviousOutput -LogicalLines $logical11 -HistoryText $h11 -Shell cmd
if ($h11 -cne 'snag') {
    Write-Host "FAIL 11 cmd history collapsed history=[$h11]"
    $failed++
} else {
    Assert-SnagCase -Name '11 cmd history collapsed' -Result $r -CommandText 'snag' `
        -OutputLines @('[snag] copied 1 lines') -Partial $false -NoHistory $false
}

# 12. Canonical invocation differs in case from the doskey line. Drop the in-flight line.
$logical12 = @('C:\repo> dir', 'file.txt', 'C:\repo> snag -full')
$h12 = Resolve-SnagCmdHistory -HistoryLines @('dir', 'snag -full') -CurrentInvocation 'snag -Full' -LogicalLines $logical12
$r = Select-SnagPreviousOutput -LogicalLines $logical12 -HistoryText $h12 -Shell cmd
if ($h12 -cne 'dir') {
    Write-Host "FAIL 12 cmd history flag case history=[$h12]"
    $failed++
} else {
    Assert-SnagCase -Name '12 cmd history flag case' -Result $r -CommandText 'dir' `
        -OutputLines @('file.txt') -Partial $false -NoHistory $false
}

# 13. Command token case differs, and the second Snag was not stored. Search with the doskey text.
$logical13 = @(
    'C:\repo> dir',
    'file.txt',
    'C:\repo> Snag',
    '[snag] copied 1 lines',
    'C:\repo> Snag'
)
$h13 = Resolve-SnagCmdHistory -HistoryLines @('dir', 'Snag') -CurrentInvocation 'snag' -LogicalLines $logical13
$r = Select-SnagPreviousOutput -LogicalLines $logical13 -HistoryText $h13 -Shell cmd
if ($h13 -cne 'Snag') {
    Write-Host "FAIL 13 cmd history token case history=[$h13]"
    $failed++
} else {
    Assert-SnagCase -Name '13 cmd history token case' -Result $r -CommandText 'Snag' `
        -OutputLines @('[snag] copied 1 lines') -Partial $false -NoHistory $false
}

# 14. doskey recorded .\snag.cmd. That is the in-flight call, not the previous command.
$logical14 = @('C:\repo> echo cmd-marker', 'cmd-marker', 'C:\repo> .\snag.cmd')
$h14 = Resolve-SnagCmdHistory -HistoryLines @('echo cmd-marker', '.\snag.cmd') -CurrentInvocation 'snag' -LogicalLines $logical14
$r = Select-SnagPreviousOutput -LogicalLines $logical14 -HistoryText $h14 -Shell cmd
if ($h14 -cne 'echo cmd-marker') {
    Write-Host "FAIL 14 cmd dot invocation history=[$h14]"
    $failed++
} else {
    Assert-SnagCase -Name '14 cmd dot invocation' -Result $r -CommandText 'echo cmd-marker' `
        -OutputLines @('cmd-marker') -Partial $false -NoHistory $false
}

# 15. .\snag.cmd -Full is the same call as the canonical snag -Full.
$logical15 = @('C:\repo> echo flag-marker', 'flag-marker', 'C:\repo> .\snag.cmd -Full')
$h15 = Resolve-SnagCmdHistory -HistoryLines @('echo flag-marker', '.\snag.cmd -Full') -CurrentInvocation 'snag -Full' -LogicalLines $logical15
if ($h15 -cne 'echo flag-marker') {
    Write-Host "FAIL 15 cmd dot full history=[$h15]"
    $failed++
} else {
    Write-Host 'ok 15 cmd dot full'
}

if ($failed -gt 0) { exit 1 }
exit 0
