@echo off
echo ============================================
echo   Terminal Streamer - Flutter Client Setup
echo ============================================
echo.

cd /d "%~dp0client"

echo [1/3] Pruefe Flutter Installation...
where flutter >nul 2>&1 || (
    echo FEHLER: Flutter nicht gefunden. Bitte Flutter SDK installieren.
    pause
    exit /b 1
)
call flutter --version
echo.

echo [2/3] Installiere Abhaengigkeiten...
call flutter pub get
echo.

echo [3/3] Baue und starte App...
echo.
echo Verfuegbare Plattformen:
echo   1. Windows (Desktop)
echo   2. Android (angeschlossenes Geraet)
echo   3. Web (Chrome)
echo.
set /p PLATFORM="Plattform waehlen [1/2/3]: "

if "%PLATFORM%"=="2" (
    call flutter run -d android
) else if "%PLATFORM%"=="3" (
    call flutter run -d chrome
) else (
    call flutter run -d windows
)
pause
