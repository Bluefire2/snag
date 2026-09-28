# Windows console tests for bare snag. No Pester.
#
# Types into a separate conhost or Windows Terminal window, one command at a time,
# then reads the clipboard. The scenario is not a script running inside that window:
# a script there would not leave the screen buffer or history snag reads.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\snag-console.tests.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\snag-console.tests.ps1 -HostKind conhost
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\snag-console.tests.ps1 -Only ps-norepeat,cmd-path-basic
#
# cmd is started with /d so AutoRun (Clink, for example) does not change the prompt.
# PowerShell 7 and Windows Terminal are skipped when they are not installed.
# Expect a few minutes. Windows will open and close.
#
# Contract notes, from the implementation and a live Windows pass:
# - The copied command is the history entry immediately before snag. A Remove-Item
#   between Get-Content and snag is the previous command, so the header is Remove-Item.
# - snag -Last re-runs that same history entry. After a cancelled -Last, the next
#   -Last targets snag -Last. The y case is a fresh window whose previous command is echo.
# - PowerShell's > operator does not replace the process stdout handle, so an
#   interactive `snag > file` still sees a console. A powershell.exe whose stdout
#   is redirected does not.
# - .\snag.cmd, lowercase snag -append, and `.\snag.cmd cmd /c echo ...` are asserted
#   as the contract (copy the previous command, accept flag case, run the command).
#   Those three failed on the 2026-09-28 Windows pass.

param(
    [ValidateSet('all', 'conhost', 'wt')]
    [string]$HostKind = 'all',
    [string[]]$Only
)

$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $onlyArgs = @()
    if ($Only) {
        foreach ($item in @($Only)) { $onlyArgs += @('-Only', $item) }
    }
    $hostExe = (Get-Process -Id $PID).Path
    & $hostExe -STA -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -HostKind $HostKind @onlyArgs
    exit $LASTEXITCODE
}

if ($env:OS -ne 'Windows_NT') {
    Write-Host 'snag console tests require Windows'
    exit 2
}

$script:repo = Split-Path $PSScriptRoot -Parent
$script:failed = 0
$script:label = ''
$script:sessionBroken = $false
$script:caseFilter = New-Object System.Collections.Generic.List[string]
if ($PSBoundParameters.ContainsKey('Only')) {
    foreach ($item in @($Only)) {
        foreach ($part in ([string]$item -split ',')) {
            $name = $part.Trim()
            if ($name) { $script:caseFilter.Add($name) }
        }
    }
}
if ($script:caseFilter.Count -gt 0) { Write-Host ('cases: ' + ($script:caseFilter -join ', ')) }
$script:partial = "snag: the previous command isn't in the readable screen buffer; the copy may be partial"
$script:notConsole = "snag: stdout isn't a console, so the previous output can't be copied"
$script:ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
$script:psArgs = '-NoLogo -NoExit -NoProfile -ExecutionPolicy Bypass'
$script:cmdArgs = '/d'
$script:pwsh = $null
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwshCmd) { $script:pwsh = $pwshCmd.Source }
$script:who = (whoami).Trim()
$script:origClip = $null
try { $script:origClip = Get-Clipboard -Raw -ErrorAction Stop } catch {}

function B64([string]$s) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$s)) }
function UnB64([string]$s) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s)) }
function Esc([string]$s) {
    if ($null -eq $s) { return '<null>' }
    $t = ($s -replace "`r", '<CR>') -replace "`n", '<LF>'
    if ($t.Length -gt 1200) { return $t.Substring(0, 1200) + '...<truncated>' }
    return $t
}
function Want([string]$id) {
    if ($script:caseFilter.Count -eq 0) { return $true }
    return $script:caseFilter.Contains($id)
}
function Need {
    param([string[]]$Ids)
    foreach ($id in $Ids) { if (Want $id) { return $true } }
    return $false
}
function Use-HostKind([string]$kind) {
    return ($HostKind -eq 'all' -or $HostKind -eq $kind)
}
function Pass([string]$id) { Write-Host "ok $id [$script:label]" }
function Fail([string]$id, [string]$detail) {
    $script:failed++
    Write-Host "FAIL $id [$script:label]"
    if ($detail) { Write-Host $detail }
}
function Run-Case([string]$id, [scriptblock]$Body) {
    if (-not (Want $id)) { return }
    if ($script:sessionBroken) {
        Fail $id 'skipped: console did not return to a prompt'
        return
    }
    try { & $Body }
    catch {
        $script:sessionBroken = $true
        Fail $id $_.Exception.Message
        try { Wait-Prompt 3000 } catch {}
    }
}
function Skip-Case([string]$id, [string]$why) {
    if (-not (Want $id)) { return }
    Write-Host "skip $id [$script:label]: $why"
}

function Send-Typer([string]$line, [int]$ms = 20000) {
    $script:typer.StandardInput.WriteLine($line)
    $task = $script:typer.StandardOutput.ReadLineAsync()
    if (-not $task.Wait($ms)) { throw "typer timeout: $line" }
    if ($null -eq $task.Result) { throw 'typer closed' }
    return [string]$task.Result
}
function Send-Line([string]$text) {
    $r = Send-Typer ('LINE ' + (B64 $text)) 15000
    if ($r -notlike 'OK*') { throw "LINE failed: $r" }
}
function Wait-Prompt([int]$ms = 25000) {
    $r = Send-Typer "WAIT prompt $ms" ($ms + 8000)
    if ($r -notlike 'OK*') { throw 'prompt did not return' }
}
function Wait-Text([string]$needle, [int]$ms = 15000) {
    $r = Send-Typer ("WAIT text $ms " + (B64 $needle)) ($ms + 8000)
    if ($r -notlike 'OK*') { throw "text not seen: $needle" }
}
function Wait-Cont {
    $r = Send-Typer 'WAIT cont 15000' 20000
    if ($r -notlike 'OK*') { throw 'continuation prompt did not appear' }
}
function Get-Screen {
    $r = Send-Typer 'SCREEN' 30000
    if ($r -notlike 'OK *') { throw "SCREEN failed: $r" }
    return (UnB64 $r.Substring(3))
}
function Get-Row {
    $r = Send-Typer 'ROW' 10000
    if ($r -notlike 'OK *') { throw "ROW failed: $r" }
    return (UnB64 $r.Substring(3))
}
function Get-Metrics {
    return (Send-Typer 'METRICS' 10000)
}
function Get-Clip {
    try { return Get-Clipboard -Raw -ErrorAction Stop } catch { return $null }
}
function Close-Console {
    try { Send-Typer 'CLOSE' 12000 | Out-Null } catch {}
}
function Open-Console([string]$Kind, [string]$PromptKind, [string]$Exe, [string]$Arguments, [int]$Cols, [int]$Win, [int]$Buf, [string]$Label) {
    $script:sessionBroken = $false
    $script:label = $Label
    $line = "LAUNCH $Kind $PromptKind $(B64 $script:repo) $Cols $Win $Buf $(B64 $Exe) $(B64 $Arguments)"
    $r = Send-Typer $line 30000
    if ($r -notlike 'OK*') { throw "launch failed: $r" }
    Write-Host "session $Label $r"
    Wait-Prompt 20000
}
function Enter-Ps {
    Send-Line '. .\snag.ps1'
    Wait-Prompt 20000
}
function Enter-Cmd {
    Send-Line ('set "PATH=' + $script:repo + ';%PATH%"')
    Wait-Prompt
}
function After-Command([string]$screen, [string]$typed) {
    $lines = @($screen -split "`n")
    $idx = -1
    for ($i = $lines.Length - 1; $i -ge 0; $i--) {
        $line = [string]$lines[$i]
        if (-not $line.EndsWith($typed)) { continue }
        if ($line.Length -eq $typed.Length) { $idx = $i; break }
        $before = $line[$line.Length - $typed.Length - 1]
        if ($before -eq '>' -or [char]::IsWhiteSpace($before)) { $idx = $i; break }
    }
    if ($idx -lt 0 -or $idx -ge ($lines.Length - 1)) { return @() }
    return @($lines[($idx + 1)..($lines.Length - 1)])
}
function Count-Eq([string]$screen, [string]$text) {
    return @($screen -split "`n" | Where-Object { $_ -ceq $text }).Count
}
function Clip-Text([string]$header, [string[]]$body) {
    return ("> $header`r`n" + ((@($body) | Where-Object { $null -ne $_ }) -join "`r`n"))
}
function Assert-Clip([string]$id, [string]$typed, [string]$expect, [string]$status, [bool]$forbidPartial) {
    $screen = Get-Screen
    $clip = Get-Clip
    $after = (After-Command $screen $typed) -join "`n"
    $problems = New-Object System.Collections.Generic.List[string]
    if ($clip -cne $expect) { $problems.Add('clipboard mismatch') }
    if ($status -and $after.IndexOf($status, [StringComparison]::Ordinal) -lt 0) {
        $problems.Add("missing status [$status]")
    }
    if ($forbidPartial -and $after.IndexOf($script:partial, [StringComparison]::Ordinal) -ge 0) {
        $problems.Add('unexpected partial warning')
    }
    if ($problems.Count -eq 0) { Pass $id }
    else {
        Fail $id (($problems -join '; ') + "`nCLIP $(Esc $clip)`nEXPECT $(Esc $expect)`nAFTER $after")
    }
}

function Build-Typer {
    $dir = Join-Path $env:TEMP 'snag-console-tests'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $fx = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
    if (-not (Test-Path (Join-Path $fx 'csc.exe'))) {
        $fx = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319'
    }
    $csc = Join-Path $fx 'csc.exe'
    $out = Join-Path $dir 'SnagConsoleTyper.exe'
    $src = Join-Path $PSScriptRoot 'SnagConsoleTyper.cs'
    & $csc /nologo /target:winexe "/r:$fx\System.Management.dll" "/out:$out" $src
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) { throw 'failed to compile SnagConsoleTyper.cs' }
    return $out
}
function Start-Typer([string]$exe) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $script:typer = [Diagnostics.Process]::Start($psi)
    $script:typer.StandardInput.AutoFlush = $true
    $pong = Send-Typer 'PING' 5000
    if ($pong -notlike 'OK*') { throw "typer ping failed: $pong" }
}
function Stop-Typer {
    if (-not $script:typer) { return }
    try { $script:typer.StandardInput.Close() } catch {}
    if (-not $script:typer.WaitForExit(3000)) {
        try { $script:typer.Kill() } catch {}
    }
}

function Invoke-Session {
    param([string[]]$Ids, [scriptblock]$Open, [scriptblock]$Body)
    if (-not (Need $Ids)) { return }
    try {
        & $Open
        & $Body
    }
    catch {
        if (-not $script:label) { $script:label = 'session' }
        Fail 'session' $_.Exception.Message
    }
    finally { Close-Console }
}

function Test-PsMain {
    Run-Case 'ps-norepeat' {
        Send-Line 'Set-Content -Path $env:TEMP\snag-once.txt -Value ran'
        Wait-Prompt
        Send-Line 'Get-Content $env:TEMP\snag-once.txt'
        Wait-Prompt
        Send-Line 'Remove-Item $env:TEMP\snag-once.txt'
        Wait-Prompt
        Send-Line 'snag'
        Wait-Prompt
        $screen = Get-Screen
        $clip = Get-Clip
        $expect = Clip-Text 'Remove-Item $env:TEMP\snag-once.txt' @()
        $problems = New-Object System.Collections.Generic.List[string]
        if ((Count-Eq $screen 'ran') -ne 1) { $problems.Add("ran count=$(Count-Eq $screen 'ran')") }
        $gc = @($screen -split "`n" | Where-Object { $_.Contains('Get-Content $env:TEMP\snag-once.txt') }).Count
        if ($gc -ne 1) { $problems.Add("Get-Content lines=$gc") }
        if ($screen.Contains('Cannot find path') -or $screen.Contains('does not exist')) { $problems.Add('missing-file error') }
        if ($clip -cne $expect) { $problems.Add('clipboard mismatch') }
        if ($clip -and $clip.Contains('[exit ')) { $problems.Add('invented [exit]') }
        $after = (After-Command $screen 'snag') -join "`n"
        if ($after.IndexOf('[snag] copied 0 lines', [StringComparison]::Ordinal) -lt 0) { $problems.Add("status missing in $after") }
        if ($after.IndexOf('usage:', [StringComparison]::Ordinal) -ge 0) { $problems.Add('bare snag printed usage') }
        if ($problems.Count -eq 0) { Pass 'ps-norepeat' }
        else { Fail 'ps-norepeat' (($problems -join '; ') + "`nCLIP $(Esc $clip)") }
    }
    foreach ($pair in @(
        @{ Id = 'ps-append'; Cmd = 'snag -Append'; Append = $true }
    )) {
        $item = $pair
        Run-Case $item.Id {
            Send-Line 'echo flag-marker'
            Wait-Prompt
            if ($item.Append) { Set-Clipboard -Value 'EXISTING' }
            Send-Line $item.Cmd
            Wait-Prompt
            $body = Clip-Text 'echo flag-marker' @('flag-marker')
            $expect = $body
            $status = '[snag] copied 1 lines'
            if ($item.Append) {
                $expect = "EXISTING`r`n`r`n" + $body
                $status = '[snag] copied 1 lines (appended)'
            }
            Assert-Clip $item.Id $item.Cmd $expect $status $true
        }
    }
    Run-Case 'ps-long' {
        if ($script:label -like '*ConPTY*') {
            Skip-Case 'ps-long' 'ConPTY viewport cannot hold 250 lines'
            return
        }
        $cmd = '1..250 | ForEach-Object { "line $_" }'
        Send-Line $cmd
        Wait-Prompt 90000
        Send-Line 'snag'
        Wait-Prompt 30000
        $body = New-Object System.Collections.Generic.List[string]
        foreach ($n in 1..250) { $body.Add("line $n") }
        $screen = Get-Screen
        $clip = Get-Clip
        $expect = Clip-Text $cmd @($body)
        $problems = New-Object System.Collections.Generic.List[string]
        if ($clip -cne $expect) { $problems.Add('clipboard mismatch') }
        if ($clip -and $clip.Contains('lines omitted')) { $problems.Add('omission marker') }
        $after = (After-Command $screen 'snag') -join "`n"
        if ($after.IndexOf('[snag] copied 250 lines', [StringComparison]::Ordinal) -lt 0) { $problems.Add('missing copied 250 lines') }
        if ($problems.Count -eq 0) { Pass 'ps-long' }
        else { Fail 'ps-long' (($problems -join '; ') + "`nCLIP $(Esc $clip)") }
    }
    Run-Case 'ps-no-exit' {
        Send-Line 'cmd /c exit 3'
        Wait-Prompt
        Send-Line 'snag'
        Wait-Prompt
        $clip = Get-Clip
        $expect = Clip-Text 'cmd /c exit 3' @()
        $problems = New-Object System.Collections.Generic.List[string]
        if ($clip -cne $expect) { $problems.Add('clipboard mismatch') }
        if ($clip -and $clip.Contains('[exit ')) { $problems.Add('invented [exit]') }
        if ($problems.Count -eq 0) { Pass 'ps-no-exit' }
        else { Fail 'ps-no-exit' ("CLIP $(Esc $clip)") }
    }
    Run-Case 'ps-run-exit' {
        Send-Line 'snag cmd /c exit 3'
        Wait-Prompt
        $clip = Get-Clip
        $screen = Get-Screen
        $lines = @($clip -split "`r`n")
        $problems = New-Object System.Collections.Generic.List[string]
        if ($lines.Count -lt 1 -or $lines[0] -cne '> cmd /c exit 3') { $problems.Add("header=[$($lines[0])]") }
        if ($lines[-1] -cne '[exit 3]') { $problems.Add("last=[$($lines[-1])]") }
        $after = (After-Command $screen 'snag cmd /c exit 3') -join "`n"
        if ($after.IndexOf('[snag] copied 0 lines (exit 3)', [StringComparison]::Ordinal) -lt 0) {
            $problems.Add("status: $after")
        }
        if ($problems.Count -eq 0) { Pass 'ps-run-exit' }
        else { Fail 'ps-run-exit' (($problems -join '; ') + "`nCLIP $(Esc $clip)") }
    }
    foreach ($c in @('snag -?', 'snag /?', 'snag -h', 'snag --help', 'snag -Bogus')) {
        $cmdText = $c
        $id = 'ps-help ' + $cmdText
        Run-Case $id {
            Set-Clipboard -Value 'CLIP-USAGE-PS'
            Send-Line $cmdText
            Wait-Prompt
            $clip = Get-Clip
            $after = (After-Command (Get-Screen) $cmdText) -join "`n"
            $problems = New-Object System.Collections.Generic.List[string]
            if ($clip -cne 'CLIP-USAGE-PS') { $problems.Add('clipboard changed') }
            if ($after.IndexOf('usage:', [StringComparison]::Ordinal) -lt 0) { $problems.Add('usage not printed') }
            if ($cmdText -eq 'snag -Bogus' -and $after.IndexOf("unknown option '-Bogus'", [StringComparison]::Ordinal) -lt 0) {
                $problems.Add('missing unknown option')
            }
            if ($problems.Count -eq 0) { Pass $id }
            else { Fail $id (($problems -join '; ') + "`nAFTER $after") }
        }
    }
    Run-Case 'ps-bare' {
        Send-Line 'echo bare-marker'
        Wait-Prompt
        Send-Line 'snag'
        Wait-Prompt
        $screen = Get-Screen
        $after = (After-Command $screen 'snag') -join "`n"
        $clip = Get-Clip
        $expect = Clip-Text 'echo bare-marker' @('bare-marker')
        $problems = New-Object System.Collections.Generic.List[string]
        if ($clip -cne $expect) { $problems.Add('clipboard mismatch') }
        if ($after.IndexOf('usage:', [StringComparison]::Ordinal) -ge 0) { $problems.Add('bare snag printed usage') }
        if ($after.IndexOf('[snag] copied 1 lines', [StringComparison]::Ordinal) -lt 0) { $problems.Add('did not copy') }
        if ($problems.Count -eq 0) { Pass 'ps-bare' }
        else {
            $tail = @($screen -split "`n" | Select-Object -Last 8) -join "`n"
            Fail 'ps-bare' (($problems -join '; ') + "`nCLIP len=$($clip.Length) $(Esc $clip)`nEXPECT $(Esc $expect)`nAFTER $after`nTAIL $tail")
        }
    }
    Run-Case 'ps-redirect-operator' {
        $path = Join-Path $env:TEMP 'snag-console-operator.txt'
        Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        Send-Line 'echo redirect-marker'
        Wait-Prompt
        Send-Line 'snag > $env:TEMP\snag-console-operator.txt'
        Wait-Prompt
        $clip = Get-Clip
        $screen = Get-Screen
        $expect = Clip-Text 'echo redirect-marker' @('redirect-marker')
        $fileLen = 0
        if (Test-Path -LiteralPath $path) { $fileLen = (Get-Item -LiteralPath $path).Length }
        $problems = New-Object System.Collections.Generic.List[string]
        if ($clip -cne $expect) { $problems.Add('clipboard mismatch') }
        if ($screen.IndexOf($script:notConsole, [StringComparison]::Ordinal) -ge 0) { $problems.Add('interactive > reported a non-console') }
        if ($fileLen -ne 0) { $problems.Add("file length=$fileLen") }
        if ($problems.Count -eq 0) { Pass 'ps-redirect-operator' }
        else { Fail 'ps-redirect-operator' (($problems -join '; ') + "`nCLIP $(Esc $clip)") }
    }
    Run-Case 'ps-multiline' {
        Send-Line 'foreach ($i in 1..2) {'
        Wait-Cont
        Send-Line '$i'
        Wait-Cont
        Send-Line '}'
        Wait-Prompt
        Send-Line 'snag'
        Wait-Prompt
        $clip = Get-Clip
        $expect = "> foreach (`$i in 1..2) {`r`n`$i`r`n}`r`n1`r`n2"
        $problems = New-Object System.Collections.Generic.List[string]
        if ($clip -cne $expect) { $problems.Add('clipboard mismatch') }
        if ($clip -and $clip.Contains('>>')) { $problems.Add('header contains >>') }
        $after = (After-Command (Get-Screen) 'snag') -join "`n"
        if ($after.IndexOf($script:partial, [StringComparison]::Ordinal) -ge 0) { $problems.Add('partial warning') }
        if ($problems.Count -eq 0) { Pass 'ps-multiline' }
        else { Fail 'ps-multiline' ("CLIP $(Esc $clip)`nEXPECT $(Esc $expect)") }
    }
}

function Test-PsLast {
    Run-Case 'ps-last-n' {
        Send-Line 'echo last-marker'
        Wait-Prompt
        Set-Clipboard -Value 'CLIP-BEFORE-LAST'
        Send-Line 'snag -Last'
        Wait-Text "re-run 'echo last-marker'"
        Send-Line 'n'
        Wait-Prompt
        $screen = Get-Screen
        $clip = Get-Clip
        $after = (After-Command $screen 'snag -Last') -join "`n"
        $problems = New-Object System.Collections.Generic.List[string]
        if ($after.IndexOf('snag: cancelled', [StringComparison]::Ordinal) -lt 0) { $problems.Add('missing cancelled') }
        if ($clip -cne 'CLIP-BEFORE-LAST') { $problems.Add('clipboard changed') }
        if ((Count-Eq $screen 'last-marker') -ne 1) { $problems.Add('command ran') }
        if ($problems.Count -eq 0) { Pass 'ps-last-n' }
        else { Fail 'ps-last-n' (($problems -join '; ') + "`nAFTER $after") }
    }
    Run-Case 'ps-last-after-cancel' {
        Set-Clipboard -Value 'CLIP-AFTER-CANCEL'
        Send-Line 'snag -Last'
        Wait-Text 're-run'
        $row = Get-Row
        Send-Line 'n'
        Wait-Prompt
        $clip = Get-Clip
        $problems = New-Object System.Collections.Generic.List[string]
        if ($row.IndexOf("re-run 'snag -Last'", [StringComparison]::Ordinal) -lt 0) { $problems.Add("prompt=[$row]") }
        if ($clip -cne 'CLIP-AFTER-CANCEL') { $problems.Add('clipboard changed') }
        if ($problems.Count -eq 0) { Pass 'ps-last-after-cancel' }
        else { Fail 'ps-last-after-cancel' ($problems -join '; ') }
    }
}

function Test-PsLastYes {
    Run-Case 'ps-last-y' {
        Send-Line 'echo last-marker'
        Wait-Prompt
        Send-Line 'snag -Last'
        Wait-Text "re-run 'echo last-marker'"
        Send-Line 'y'
        Wait-Prompt
        $clip = Get-Clip
        $expect = Clip-Text 'echo last-marker' @('last-marker')
        $problems = New-Object System.Collections.Generic.List[string]
        if ($clip -cne $expect) { $problems.Add('clipboard mismatch') }
        if ($clip -and $clip.Contains('[exit ')) { $problems.Add('unexpected [exit]') }
        if ($problems.Count -eq 0) { Pass 'ps-last-y' }
        else { Fail 'ps-last-y' ("CLIP $(Esc $clip)`nEXPECT $(Esc $expect)") }
    }
}

function Test-PsTwice([bool]$WithEcho) {
    $id = 'ps-twice'
    if (-not $WithEcho) { $id = 'ps-twice-second' }
    Run-Case $id {
        if ($WithEcho) {
            Send-Line 'echo first-snag'
            Wait-Prompt
        }
        Send-Line 'snag'
        Wait-Prompt
        Send-Line 'snag'
        Wait-Prompt
        $screen = Get-Screen
        $clip = Get-Clip
        $problems = New-Object System.Collections.Generic.List[string]
        if ($screen.Contains('Cannot add type') -or $screen.Contains('already exists')) { $problems.Add('Add-Type error') }
        $lines = @($clip -split "`r`n")
        if ($lines.Count -lt 1 -or $lines[0] -cne '> snag') { $problems.Add("header=[$($lines[0])]") }
        if ($WithEcho) {
            $expect = Clip-Text 'snag' @('[snag] copied 1 lines')
            if ($clip -cne $expect) { $problems.Add('clipboard mismatch') }
        }
        if ($problems.Count -eq 0) { Pass $id }
        else { Fail $id (($problems -join '; ') + "`nCLIP $(Esc $clip)") }
    }
}

function Test-PsViewport([bool]$ExpectPartial) {
    Run-Case 'ps-viewport' {
        $metrics = Get-Metrics
        Send-Line 'cls'
        Wait-Prompt
        $cmd = '1..80 | ForEach-Object { "scroll $_" }'
        Send-Line $cmd
        Wait-Prompt 60000
        Send-Line 'snag'
        Wait-Prompt 20000
        $clip = Get-Clip
        $screen = Get-Screen
        $lines = @($clip -split "`r`n")
        $scrolls = @($lines | Where-Object { $_ -match '^scroll \d+$' })
        $after = (After-Command $screen 'snag') -join "`n"
        $warned = $after.IndexOf($script:partial, [StringComparison]::Ordinal) -ge 0
        $problems = New-Object System.Collections.Generic.List[string]
        if ($lines.Count -lt 1 -or $lines[0] -cne ("> $cmd")) { $problems.Add("header=[$($lines[0])]") }
        if ($clip -and $clip.Contains('lines omitted')) { $problems.Add('output was trimmed') }
        $has1 = @($scrolls | Where-Object { $_ -ceq 'scroll 1' }).Count -gt 0
        $has80 = @($scrolls | Where-Object { $_ -ceq 'scroll 80' }).Count -gt 0
        if ($ExpectPartial) {
            if (-not $warned) { $problems.Add('missing partial warning') }
            if ($has1) { $problems.Add('scroll 1 still copied') }
            if (-not $has80) { $problems.Add('tail missing scroll 80') }
            if ($scrolls.Count -ge 80) { $problems.Add("copied $($scrolls.Count) lines") }
        }
        else {
            if ($warned) { $problems.Add('unexpected partial warning') }
            if (-not $has1 -or -not $has80 -or $scrolls.Count -ne 80) {
                $problems.Add("scrolls=$($scrolls.Count) has1=$has1 has80=$has80")
            }
        }
        if ($problems.Count -eq 0) { Pass 'ps-viewport' }
        else { Fail 'ps-viewport' (($problems -join '; ') + "`n$metrics`nCLIP $(Esc $clip)") }
    }
}

function Test-CmdMain {
    Run-Case 'cmd-path-basic' {
        Send-Line 'echo cmd-marker'
        Wait-Prompt
        Send-Line 'snag'
        Wait-Prompt 25000
        Assert-Clip 'cmd-path-basic' 'snag' (Clip-Text 'echo cmd-marker' @('cmd-marker')) '[snag] copied 1 lines' $true
    }
    Run-Case 'cmd-dot-basic' {
        Send-Line 'echo cmd-marker'
        Wait-Prompt
        Send-Line '.\snag.cmd'
        Wait-Prompt 25000
        Assert-Clip 'cmd-dot-basic' '.\snag.cmd' (Clip-Text 'echo cmd-marker' @('cmd-marker')) '[snag] copied 1 lines' $true
    }
    foreach ($pair in @(
        @{ Id = 'cmd-append'; Cmd = 'snag -Append'; Append = $true }
    )) {
        $item = $pair
        Run-Case $item.Id {
            Send-Line 'echo flag-marker'
            Wait-Prompt
            if ($item.Append) { Set-Clipboard -Value 'EXISTING' }
            Send-Line $item.Cmd
            Wait-Prompt 25000
            $body = Clip-Text 'echo flag-marker' @('flag-marker')
            $expect = $body
            $status = '[snag] copied 1 lines'
            if ($item.Append) {
                $expect = "EXISTING`r`n`r`n" + $body
                $status = '[snag] copied 1 lines (appended)'
            }
            Assert-Clip $item.Id $item.Cmd $expect $status $true
        }
    }
    Run-Case 'cmd-dot-append' {
        Send-Line 'echo flag-marker'
        Wait-Prompt
        Set-Clipboard -Value 'EXISTING'
        Send-Line '.\snag.cmd -append'
        Wait-Prompt 25000
        $body = Clip-Text 'echo flag-marker' @('flag-marker')
        Assert-Clip 'cmd-dot-append' '.\snag.cmd -append' ("EXISTING`r`n`r`n" + $body) '[snag] copied 1 lines (appended)' $true
    }
    Run-Case 'cmd-flag-case' {
        Send-Line 'echo case-marker'
        Wait-Prompt
        Set-Clipboard -Value 'EXISTING'
        Send-Line 'snag -append'
        Wait-Prompt 25000
        $body = Clip-Text 'echo case-marker' @('case-marker')
        Assert-Clip 'cmd-flag-case' 'snag -append' ("EXISTING`r`n`r`n" + $body) '[snag] copied 1 lines (appended)' $true
    }
    Run-Case 'cmd-last' {
        Send-Line 'echo should-not-rerun'
        Wait-Prompt
        $before = Count-Eq (Get-Screen) 'should-not-rerun'
        Send-Line '.\snag.cmd -Last'
        Wait-Prompt
        $screen = Get-Screen
        $after = (After-Command $screen '.\snag.cmd -Last') -join "`n"
        $problems = New-Object System.Collections.Generic.List[string]
        if ($after.IndexOf('usage:', [StringComparison]::Ordinal) -lt 0) { $problems.Add('usage not printed') }
        if ($after.IndexOf('PowerShell only', [StringComparison]::Ordinal) -lt 0) { $problems.Add('missing PowerShell-only note') }
        if ($after.IndexOf("re-run '", [StringComparison]::Ordinal) -ge 0) { $problems.Add('tried to re-run') }
        if ((Count-Eq $screen 'should-not-rerun') -ne $before) { $problems.Add('echo ran again') }
        if ($problems.Count -eq 0) { Pass 'cmd-last' }
        else { Fail 'cmd-last' (($problems -join '; ') + "`nAFTER $after") }
    }
    Run-Case 'cmd-token-case' {
        Send-Line 'echo token-marker'
        Wait-Prompt
        Send-Line 'Snag'
        Wait-Prompt 25000
        Assert-Clip 'cmd-token-case' 'Snag' (Clip-Text 'echo token-marker' @('token-marker')) '[snag] copied 1 lines' $true
    }
    foreach ($c in @('snag -?', 'snag /?', 'snag -Bogus')) {
        $cmdText = $c
        $id = 'cmd-help ' + $cmdText
        Run-Case $id {
            Set-Clipboard -Value 'CLIP-USAGE-CMD'
            Send-Line $cmdText
            Wait-Prompt
            $clip = Get-Clip
            $after = (After-Command (Get-Screen) $cmdText) -join "`n"
            $problems = New-Object System.Collections.Generic.List[string]
            if ($clip -cne 'CLIP-USAGE-CMD') { $problems.Add('clipboard changed') }
            if ($after.IndexOf('usage:', [StringComparison]::Ordinal) -lt 0) { $problems.Add('usage not printed') }
            if ($cmdText -eq 'snag -Bogus' -and $after.IndexOf('unknown option -Bogus', [StringComparison]::Ordinal) -lt 0) {
                $problems.Add('missing unknown option')
            }
            if ($problems.Count -eq 0) { Pass $id }
            else { Fail $id (($problems -join '; ') + "`nAFTER $after") }
        }
    }
    Run-Case 'cmd-whoami' {
        Set-Clipboard -Value 'CLIP-WHOAMI'
        Send-Line '.\snag.cmd "-x&whoami"'
        Wait-Prompt
        $clip = Get-Clip
        $after = (After-Command (Get-Screen) '.\snag.cmd "-x&whoami"') -join "`n"
        $lines = @($after -split "`n")
        $problems = New-Object System.Collections.Generic.List[string]
        if ($clip -cne 'CLIP-WHOAMI') { $problems.Add('clipboard changed') }
        if ($after.IndexOf('unknown option -x&whoami', [StringComparison]::Ordinal) -lt 0) { $problems.Add('missing unknown option') }
        if ($after.IndexOf('usage:', [StringComparison]::Ordinal) -lt 0) { $problems.Add('usage not printed') }
        if (@($lines | Where-Object { $_ -ceq $script:who }).Count -gt 0) { $problems.Add('whoami ran') }
        if ($problems.Count -eq 0) { Pass 'cmd-whoami' }
        else { Fail 'cmd-whoami' (($problems -join '; ') + "`nAFTER $after") }
    }
    Run-Case 'cmd-redirect' {
        $path = Join-Path $env:TEMP 'snag-console-out.txt'
        Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        Set-Clipboard -Value 'CLIP-REDIR-CMD'
        Send-Line '.\snag.cmd > %TEMP%\snag-console-out.txt'
        Wait-Prompt 25000
        $clip = Get-Clip
        $text = ''
        if (Test-Path -LiteralPath $path) {
            $bytes = [IO.File]::ReadAllBytes($path)
            $text = [Text.Encoding]::GetEncoding(437).GetString($bytes)
        }
        $problems = New-Object System.Collections.Generic.List[string]
        if ($clip -cne 'CLIP-REDIR-CMD') { $problems.Add('clipboard changed') }
        if ($text.IndexOf($script:notConsole, [StringComparison]::Ordinal) -lt 0) { $problems.Add("file missing error [$text]") }
        if ($problems.Count -eq 0) { Pass 'cmd-redirect' }
        else { Fail 'cmd-redirect' ($problems -join '; ') }
    }
    Run-Case 'cmd-run' {
        Send-Line '.\snag.cmd cmd /c echo run-path'
        Wait-Prompt 25000
        Assert-Clip 'cmd-run' '.\snag.cmd cmd /c echo run-path' (Clip-Text 'cmd /c echo run-path' @('run-path')) '[snag] copied 1 lines' $true
    }
    Run-Case 'cmd-full-run' {
        Send-Line 'echo not-buffer'
        Wait-Prompt
        Send-Line '.\snag.cmd -Full echo hi'
        Wait-Prompt 25000
        $clip = Get-Clip
        $screen = Get-Screen
        $after = (After-Command $screen '.\snag.cmd -Full echo hi') -join "`n"
        $lines = @($clip -split "`r`n")
        $problems = New-Object System.Collections.Generic.List[string]
        if ($lines.Count -lt 1 -or $lines[0] -cne '> -Full echo hi') { $problems.Add("header=[$($lines[0])]") }
        $blob = $after + "`n" + [string]$clip
        if ($blob.IndexOf('not recognized', [StringComparison]::OrdinalIgnoreCase) -lt 0) { $problems.Add('did not try to run -Full') }
        if ($after.IndexOf($script:partial, [StringComparison]::Ordinal) -ge 0) { $problems.Add('buffer mode') }
        if ($clip -ceq (Clip-Text 'echo not-buffer' @('not-buffer'))) { $problems.Add('copied the previous echo') }
        if ($problems.Count -eq 0) { Pass 'cmd-full-run' }
        else { Fail 'cmd-full-run' (($problems -join '; ') + "`nCLIP $(Esc $clip)`nAFTER $after") }
    }
}

function Test-RedirectedHost {
    $script:label = '5.1 redirected stdout'
    Run-Case 'ps-redirect-host' {
        Set-Clipboard -Value 'CLIP-REDIR-HOST'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:ps51
        $psi.Arguments = "-NoProfile -Command `"Set-Location '$script:repo'; . .\snag.ps1; snag`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        $clip = Get-Clip
        $blob = $out + "`n" + $err
        $problems = New-Object System.Collections.Generic.List[string]
        if ($clip -cne 'CLIP-REDIR-HOST') { $problems.Add("clipboard changed [$(Esc $clip)]") }
        if ($blob.IndexOf($script:notConsole, [StringComparison]::Ordinal) -lt 0) { $problems.Add("error missing [$blob]") }
        if ($problems.Count -eq 0) { Pass 'ps-redirect-host' }
        else { Fail 'ps-redirect-host' ($problems -join '; ') }
    }
}

function Open-Ps([string]$Kind, [string]$Exe, [string]$Label, [int]$Cols, [int]$Win, [int]$Buf) {
    Open-Console $Kind 'ps' $Exe $script:psArgs $Cols $Win $Buf $Label
    Enter-Ps
}
function Open-Cmd([string]$Kind, [string]$Label, [int]$Cols, [int]$Win, [int]$Buf) {
    Open-Console $Kind 'cmd' $script:cmdExe $script:cmdArgs $Cols $Win $Buf $Label
    Enter-Cmd
}

$mainIds = @(
    'ps-norepeat', 'ps-append',
    'ps-long', 'ps-no-exit', 'ps-run-exit',
    'ps-help snag -?', 'ps-help snag /?', 'ps-help snag -h', 'ps-help snag --help', 'ps-help snag -Bogus',
    'ps-bare', 'ps-redirect-operator', 'ps-multiline'
)
$cmdIds = @(
    'cmd-path-basic', 'cmd-dot-basic', 'cmd-append',
    'cmd-dot-append', 'cmd-flag-case', 'cmd-last', 'cmd-token-case',
    'cmd-help snag -?', 'cmd-help snag /?', 'cmd-help snag -Bogus', 'cmd-whoami', 'cmd-redirect',
    'cmd-run', 'cmd-full-run'
)

$typerExe = Build-Typer
Start-Typer $typerExe
try {
    Test-RedirectedHost

    if (Use-HostKind 'conhost') {
        Invoke-Session $mainIds { Open-Ps 'conhost' $script:ps51 '5.1 conhost' 140 36 1500 } { Test-PsMain }
        Invoke-Session @('ps-last-n', 'ps-last-after-cancel') { Open-Ps 'conhost' $script:ps51 '5.1 conhost' 140 30 400 } { Test-PsLast }
        Invoke-Session @('ps-last-y') { Open-Ps 'conhost' $script:ps51 '5.1 conhost' 140 30 400 } { Test-PsLastYes }
        Invoke-Session @('ps-twice') { Open-Ps 'conhost' $script:ps51 '5.1 conhost' 140 30 400 } { Test-PsTwice $true }
        Invoke-Session @('ps-twice-second') { Open-Ps 'conhost' $script:ps51 '5.1 conhost' 140 30 400 } { Test-PsTwice $false }
        Invoke-Session @('ps-viewport') { Open-Ps 'conhost' $script:ps51 '5.1 conhost' 140 30 800 } { Test-PsViewport $false }
        Invoke-Session $cmdIds { Open-Cmd 'conhost' 'cmd conhost' 140 36 800 } { Test-CmdMain }

        if ($script:pwsh) {
            Invoke-Session $mainIds { Open-Ps 'conhost' $script:pwsh '7 conhost' 140 36 1500 } { Test-PsMain }
            Invoke-Session @('ps-last-y') { Open-Ps 'conhost' $script:pwsh '7 conhost' 140 30 400 } { Test-PsLastYes }
            Invoke-Session @('ps-twice') { Open-Ps 'conhost' $script:pwsh '7 conhost' 140 30 400 } { Test-PsTwice $true }
        }
        else { Write-Host 'skip pwsh: not installed' }
    }

    if (Use-HostKind 'wt') {
        Invoke-Session $mainIds { Open-Ps 'wt' $script:ps51 '5.1 ConPTY' 140 45 45 } { Test-PsMain }
        Invoke-Session @('ps-last-n', 'ps-last-after-cancel') { Open-Ps 'wt' $script:ps51 '5.1 ConPTY' 140 40 40 } { Test-PsLast }
        Invoke-Session @('ps-last-y') { Open-Ps 'wt' $script:ps51 '5.1 ConPTY' 140 40 40 } { Test-PsLastYes }
        Invoke-Session @('ps-viewport') { Open-Ps 'wt' $script:ps51 '5.1 ConPTY' 120 20 20 } { Test-PsViewport $true }
        Invoke-Session @('ps-twice') { Open-Ps 'wt' $script:ps51 '5.1 ConPTY' 140 40 40 } { Test-PsTwice $true }
        Invoke-Session $cmdIds { Open-Cmd 'wt' 'cmd ConPTY' 140 45 45 } { Test-CmdMain }
    }
}
finally {
    Close-Console
    Stop-Typer
    if ($null -ne $script:origClip) { Set-Clipboard -Value $script:origClip }
}

if ($script:failed -gt 0) {
    Write-Host "$($script:failed) failed"
    exit 1
}
Write-Host 'ok'
exit 0
