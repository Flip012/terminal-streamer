# Terminal Streamer

Remote terminal access: A Windows/Linux API server that exposes terminal sessions (cmd, PowerShell, bash) via WebSocket, paired with a Flutter Android client for mobile access.

## Architecture

```
┌──────────────┐     WebSocket/REST      ┌──────────────────┐
│  Android App ├─────────────────────────►│  Python API      │
│  (Flutter)   │◄─────────────────────────┤  (FastAPI)       │
│              │    Terminal I/O Stream    │                  │
│  xterm.dart  │                          │  PTY Sessions    │
│  Multi-Tab   │                          │  cmd/ps/bash     │
└──────────────┘                          └──────────────────┘
```

## Server (Python/FastAPI)

### Requirements

- Python 3.10+
- Windows: `pywinpty` (auto-installed)
- Linux/macOS: Uses built-in `pty` module

### Setup

```bash
cd server
pip install -r requirements.txt
python main.py
```

On first start, an API key is auto-generated and printed to the console. It's also saved in `server/config.json`.

### Configuration

Edit `server/config.json`:

```json
{
  "host": "0.0.0.0",
  "port": 8765,
  "api_key": "your-api-key-here",
  "default_shell": ""
}
```

- `default_shell`: Leave empty for auto-detection (cmd.exe on Windows, $SHELL on Linux)

### API Endpoints

| Method   | Path                               | Description          |
|----------|-------------------------------------|----------------------|
| GET      | `/api/sessions`                     | List all sessions    |
| POST     | `/api/sessions`                     | Create new session   |
| DELETE   | `/api/sessions/{id}`                | Delete session       |
| POST     | `/api/sessions/{id}/resize`         | Resize terminal      |
| WS       | `/ws/terminal/{id}?api_key=...`     | Terminal I/O stream  |

All REST endpoints require `X-API-Key` header. WebSocket uses `api_key` query parameter.

### WebSocket Protocol

**Client → Server:**
```json
{"type": "input", "data": "ls -la\n"}
{"type": "resize", "cols": 120, "rows": 30}
```

**Server → Client:**
```json
{"type": "output", "data": "<base64-encoded bytes>"}
{"type": "exit"}
```

## Client (Flutter/Android)

### Requirements

- Flutter SDK 3.1+
- Android SDK

### Setup

```bash
cd client
flutter pub get
flutter run
```

### Features

- Connect to server with host/port/API key
- Create and manage multiple terminal sessions
- Full terminal emulator (ANSI/VT100 colors, cursor positioning)
- Quick-access buttons for Ctrl+C, Ctrl+D, Tab, Esc
- Auto-saves connection settings
- Dark theme optimized for terminal use
