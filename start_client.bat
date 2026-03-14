@echo off
setlocal enabledelayedexpansion
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

echo [3/3] Erkenne verfuegbare Geraete...
echo.

set DEVICE_COUNT=0
for /f "usebackq delims=" %%L in (`call flutter devices --machine 2^>nul ^| python -c "import sys,json; devices=json.load(sys.stdin); [print(d['id']+'|'+d['name']+' ('+d['sdk']+')') for d in devices if d.get('isSupported')]"`) do (
    set /a DEVICE_COUNT+=1
    set "DEVICE_ID_!DEVICE_COUNT!=%%L"
    for /f "tokens=1,2 delims=|" %%A in ("%%L") do (
        echo   !DEVICE_COUNT!. %%B
        set "DEVICE_!DEVICE_COUNT!=%%A"
    )
)

if !DEVICE_COUNT!==0 (
    echo Keine Geraete gefunden. Bitte 'flutter doctor' ausfuehren.
    pause
    exit /b 1
)

echo.
set /p CHOICE="Geraet waehlen [1-!DEVICE_COUNT!]: "

set "SELECTED=!DEVICE_%CHOICE%!"
if "!SELECTED!"=="" (
    echo Ungueltige Auswahl.
    pause
    exit /b 1
)

echo.
echo Starte auf: !SELECTED!
call flutter run -d !SELECTED!
pause
