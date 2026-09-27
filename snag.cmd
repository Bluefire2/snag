@echo off
rem snag for cmd.exe. Runs the command, streams its output, copies it to the clipboard.
setlocal DisableDelayedExpansion
if [%1]==[] (
    echo usage: snag ^<command^> [args...]
    exit /b 1
)

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

%* 2>&1 | powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0snag-sink.ps1"
