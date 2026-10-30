@echo off
rem Dubbelklik om je playlists bij te werken. Zie LEESMIJ / README.md.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PlaylistFlac.ps1" %*
pause
