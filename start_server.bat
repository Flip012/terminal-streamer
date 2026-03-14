@echo off
echo ============================================
echo   Terminal Streamer - Server Setup
echo ============================================
echo.

cd /d "%~dp0server"

if not exist "venv" (
    echo [1/3] Erstelle virtuelle Umgebung...
    python -m venv venv
    if errorlevel 1 (
        echo FEHLER: Python nicht gefunden. Bitte Python 3.10+ installieren.
        pause
        exit /b 1
    )
) else (
    echo [1/3] Virtuelle Umgebung bereits vorhanden.
)

echo [2/3] Installiere Abhaengigkeiten...
call venv\Scripts\activate.bat
pip install -r requirements.txt --quiet
if errorlevel 1 (
    echo FEHLER: Abhaengigkeiten konnten nicht installiert werden.
    pause
    exit /b 1
)

echo [3/3] Starte Server...
echo.
python main.py
pause
