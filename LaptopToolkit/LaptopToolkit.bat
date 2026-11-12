@echo off
chcp 65001 >nul
cd /d "%~dp0"
if not exist "LaptopToolkit.ps1" (
    echo Файл LaptopToolkit.ps1 не найден рядом с этим .bat. Распакуйте архив целиком.
    pause
    exit /b 1
)
powershell.exe -NoProfile -Command "Get-ChildItem -LiteralPath '%~dp0' -Filter *.ps1 | Unblock-File" >nul 2>&1
start "LaptopToolkit" powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0LaptopToolkit.ps1"
