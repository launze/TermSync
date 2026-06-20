@echo off
setlocal
set "ROOT=%~dp0.."
set "KEY=%ROOT%\.ssh\root_ed25519"
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\.tmp\deploy-termsync.ps1" %*
