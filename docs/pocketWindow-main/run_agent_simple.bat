@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem PocketWindow - Start Windows control agent (simple)

title PocketWindow - Control Agent (Simple)

set ROOT=%~dp0
cd /d "%ROOT%control-agent" || goto :die

set PY=
where python >nul 2>&1 && set PY=python
if not defined PY (
  where py >nul 2>&1 && set PY=py -3
)
if not defined PY (
  echo Python not found in PATH.
  echo Install Python 3.10+ and ensure "python" or "py" works.
  goto :die
)

if not exist .venv (
  echo Creating venv...
  %PY% -m venv .venv
  if errorlevel 1 goto :die
)

if not exist ".venv\Scripts\activate.bat" (
  echo Venv activation script not found: .venv\Scripts\activate.bat
  goto :die
)

call ".venv\Scripts\activate.bat"
if errorlevel 1 goto :die

echo Updating pip...
python -m pip install --upgrade pip
if errorlevel 1 goto :die

echo Installing dependencies...
if exist "requirements.simple.txt" (
  echo Using requirements.simple.txt
  python -m pip install -r requirements.simple.txt
) else (
  echo Using requirements.txt
  python -m pip install -r requirements.txt
)
if errorlevel 1 goto :die

set SERVER_HOST=localhost
set SERVER_PORT=58080

set WINDOW_FILTER=
set /p WINDOW_FILTER=Window keyword (optional, e.g. VSCode): 

if "%WINDOW_FILTER%"=="" (
  python "src\agent_simple.py" -s %SERVER_HOST% -p %SERVER_PORT%
) else (
  python "src\agent_simple.py" -s %SERVER_HOST% -p %SERVER_PORT% -w "%WINDOW_FILTER%"
)

echo.
echo Agent exited.
pause

endlocal
exit /b 0

:die
echo.
echo Failed to start agent.
pause
endlocal
exit /b 1
