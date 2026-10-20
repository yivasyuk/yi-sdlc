@echo off
rem Sets where Claude's questions are asked (desktop window or terminal) without going through a Claude
rem session: the hook reads the mode on every question, so a running session picks the change up at its next
rem one. Usage: notification-mode [desktop^|terminal^|toggle^|status]  (no argument: status)
setlocal
set "mode=%~1"
if "%mode%"=="" set "mode=status"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\hooks\ask-dialog.ps1" -Mode "%mode%" -DataDir "%USERPROFILE%\.claude\plugins\data\yi-sdlc-yi-plugins"
