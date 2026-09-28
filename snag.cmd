@echo off
rem snag for cmd.exe. Runs the command, streams its output, copies it to the clipboard.
rem With no command, copies the previous command's output already on screen (does not re-run).
setlocal DisableDelayedExpansion

if "%~1"=="/?" goto :snag_usage
if "%~1"=="-?" goto :snag_usage
if "%~1"=="--help" goto :snag_usage
if "%~1"=="-Last" goto :snag_usage

if "%~1"=="" goto :snag_buffer_plain
if "%~1"=="-Full" if "%~2"=="" goto :snag_buffer_full
if "%~1"=="-Append" if "%~2"=="" goto :snag_buffer_append
if "%~1"=="-Full" if "%~2"=="-Append" if "%~3"=="" goto :snag_buffer_full_append
if "%~1"=="-Append" if "%~2"=="-Full" if "%~3"=="" goto :snag_buffer_append_full

rem Substring test is outside any parenthesized block: the block would be parsed
rem before SNAG_ONE is set, and with delayed expansion still off. Stay off so
rem the run path does not expand ! inside a real command.
if "%~2"=="" set "SNAG_ONE=%~1"
if "%~2"=="" if "%SNAG_ONE:~0,1%"=="-" goto :snag_unknown
if "%~2"=="" if "%SNAG_ONE:~0,1%"=="/" goto :snag_unknown
goto :snag_run

:snag_unknown
echo snag: unknown option '%~1'
goto :snag_usage

:snag_usage
echo usage: snag [-Full] [-Append]
echo        snag ^<command^> [args...]
echo Bare snag copies the previous command's output already on screen.
echo -Last is PowerShell only; it re-runs the previous command.
exit /b 1

:snag_buffer_plain
set "SNAG_INVOC=snag"
set "SNAG_FULL=0"
set "SNAG_APP=0"
goto :snag_buffer

:snag_buffer_full
set "SNAG_INVOC=snag -Full"
set "SNAG_FULL=1"
set "SNAG_APP=0"
goto :snag_buffer

:snag_buffer_append
set "SNAG_INVOC=snag -Append"
set "SNAG_FULL=0"
set "SNAG_APP=1"
goto :snag_buffer

:snag_buffer_full_append
set "SNAG_INVOC=snag -Full -Append"
set "SNAG_FULL=1"
set "SNAG_APP=1"
goto :snag_buffer

:snag_buffer_append_full
set "SNAG_INVOC=snag -Append -Full"
set "SNAG_FULL=1"
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
set "SNAG_F="
set "SNAG_A="
if "%SNAG_FULL%"=="1" set "SNAG_F=-Full"
if "%SNAG_APP%"=="1" set "SNAG_A=-Append"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0snag-buffer.ps1" -FromCmd -HistoryFile "%SNAG_HIST%" -CurrentInvocation "%SNAG_INVOC%" %SNAG_F% %SNAG_A%
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

%* 2>&1 | powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0snag-sink.ps1"
