@echo off
setlocal EnableExtensions

rem PocketWindow - Start signaling server (LAN)

set ROOT=%~dp0
cd /d "%ROOT%server" || exit /b 1

if not exist node_modules (
  echo Installing server dependencies...
  npm install || exit /b 1
)

echo Starting signaling server...
echo WebSocket: ws://localhost:58080/ws
echo REST:      http://localhost:58080/api/health
echo.

set PORT=58080

npm start

endlocal
