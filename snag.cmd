@echo off
rem snag for cmd.exe. Runs the command, streams its output, copies it to the clipboard.
rem With no command, copies the previous command's output already on screen (does not re-run).
setlocal DisableDelayedExpansion

if /I "%~1"=="/?" goto :snag_usage
if /I "%~1"=="-?" goto :snag_usage
if /I "%~1"=="--help" goto :snag_usage
rem -Last is not a command. Say so before usage; do not claim PowerShell re-runs it.
if /I "%~1"=="-Last" set "SNAG_ONE=%~1"
if /I "%~1"=="-Last" goto :snag_unknown

if "%~1"=="" goto :snag_buffer_plain
if /I "%~1"=="-Append" if "%~2"=="" goto :snag_buffer_append

rem A real command has a second argument. Jump before the substring test: cmd
rem expands %SNAG_ONE:~0,1% even when the first if is false, and that modifier
rem is a syntax error while SNAG_ONE is still unset.
if not "%~2"=="" goto :snag_run
rem Substring test is outside any parenthesized block: the block would be parsed
rem before SNAG_ONE is set, and with delayed expansion still off. Stay off so
rem the run path does not expand ! inside a real command.
set "SNAG_ONE=%~1"
if "%SNAG_ONE:~0,1%"=="-" goto :snag_unknown
if "%SNAG_ONE:~0,1%"=="/" goto :snag_unknown
goto :snag_run

:snag_unknown
rem Delayed expansion so the value is not reparsed for & | < >. End it before
rem usage so the run path, which is never reached from here, stays expansion-off.
setlocal EnableDelayedExpansion
echo snag: unknown option !SNAG_ONE!
endlocal
goto :snag_usage

:snag_usage
echo usage: snag [-Append]
echo        snag ^<command^> [args...]
echo Bare snag copies the previous command's output already on screen.
exit /b 1

:snag_buffer_plain
set "SNAG_INVOC=snag"
set "SNAG_APP=0"
goto :snag_buffer

:snag_buffer_append
set "SNAG_INVOC=snag -Append"
set "SNAG_APP=1"
goto :snag_buffer

:snag_buffer
set "SNAG_HIST=%TEMP%\snag-hist-%RANDOM%%RANDOM%.txt"
doskey /history > "%SNAG_HIST%"
if errorlevel 1 (
    echo snag: couldn't read cmd history
    del "%SNAG_HIST%" 2>nul
    exit /b 1
)
set "SNAG_A="
if "%SNAG_APP%"=="1" set "SNAG_A=-Append"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0snag-buffer.ps1" -FromCmd -HistoryFile "%SNAG_HIST%" -CurrentInvocation "%SNAG_INVOC%" %SNAG_A%
set "SNAG_EC=%ERRORLEVEL%"
del "%SNAG_HIST%"
exit /b %SNAG_EC%

:snag_run
rem Capture the raw command line for the clipboard header. `set "X=%*"` breaks on quoted & or |,
rem so instead let cmd echo a REM line containing %* (echoed after expansion, never executed).
set "SNAG_ARGFILE=%TEMP%\snag-args-%RANDOM%%RANDOM%.txt"
(
    echo on
    for %%a in (1) do (
        rem #%*#
    )
) > "%SNAG_ARGFILE%"
@echo off

rem `call` so a command that starts with '-' is not parsed as a switch on this line.
rem Without it, `-Full echo hi 2>&1 | ...` aborts cmd with no message.
call %* 2>&1 | powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0snag-sink.ps1"
