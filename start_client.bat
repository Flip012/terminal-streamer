@echo off
echo ============================================
echo   Terminal Streamer - Flutter Client Setup
echo ============================================
echo.

cd /d "%~dp0client"

echo [1/3] Pruefe Flutter Installation...
flutter --version >nul 2>&1
if errorlevel 1 (
    echo FEHLER: Flutter nicht gefunden. Bitte Flutter SDK installieren.
    pause
    exit /b 1
)

echo [2/3] Installiere Abhaengigkeiten...
call flutter pub get
if errorlevel 1 (
    echo FEHLER: Flutter-Abhaengigkeiten konnten nicht installiert werden.
    pause
    exit /b 1
)

echo [3/3] Baue und starte App...
echo.
echo Verfuegbare Plattformen:
echo   1. Windows (Desktop)
echo   2. Android (angeschlossenes Geraet)
echo   3. Web (Chrome)
echo.
set /p PLATFORM="Plattform waehlen [1/2/3]: "

if "%PLATFORM%"=="1" (
    flutter run -d windows
) else if "%PLATFORM%"=="2" (
    flutter run -d android
) else if "%PLATFORM%"=="3" (
    flutter run -d chrome
) else (
    echo Ungueltige Auswahl, starte Windows...
    flutter run -d windows
)
pause
