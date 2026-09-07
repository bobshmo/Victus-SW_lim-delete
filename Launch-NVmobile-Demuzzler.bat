@echo off
set SCRIPT=%~dp0NVmobile-Demuzzler.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"\"%SCRIPT%\"\"'"
