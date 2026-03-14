# Terminal Streamer

## Project Overview
Remote terminal streaming app: a Python FastAPI server manages PTY sessions, Flutter clients (Android/Web/Windows) connect via WebSocket to view and interact with terminals.

## Architecture

### Server (`server/`)
- **main.py**: FastAPI app with REST API for sessions, WebSocket for terminal I/O, web push notifications, question detection
- **terminal_manager.py**: PTY management (winpty on Windows, pty on Unix), pub/sub output model with asyncio queues, pyte virtual terminal for screen snapshots, session persistence, Claude Code auto-resume
- **config.py**: JSON config with auto-generated API keys and VAPID keys

### Flutter Client (`client/`)
- **screens/**: ConnectScreen → SessionsScreen → TerminalScreen
- **services/terminal_service.dart**: WebSocket connection with auto-reconnect, exponential backoff, heartbeat, QuestionDetector for push notifications
- **services/notification_service.dart**: flutter_local_notifications with deep-link navigation
- **models/**: ServerConfig (with toJson/fromJson), TerminalSessionInfo

### Web Client (`client-web/`)
- Single-page PWA with xterm.js, web push notifications via service worker

## Key Design Decisions
- **pyte virtual terminal**: Server tracks screen state; on reconnect sends clean ANSI snapshot instead of raw history (avoids garbled output at different terminal sizes)
- **Claude Code auto-resume**: Server detects `/resume <uuid>` from Claude Code status line, saves it, auto-executes `claude --resume <id>` after server restart
- **Session persistence**: sessions.json saves metadata + screen snapshot + output history every 30s and on shutdown
- **Bundled JetBrains Mono font**: Ensures consistent monospace rendering in Flutter web canvas renderer
- **Initial resize sync**: Client sends resize before server sends screen snapshot, ensuring correct dimensions

## Build & Run
```bash
# Server
./start_server.bat          # Creates venv, installs deps, starts server

# Flutter Client
./start_client.bat          # Detects devices, installs deps, runs
flutter build apk           # Builds Android APK (needs Developer Mode for symlinks)

# Output APK
client/build/app/outputs/flutter-apk/app-release.apk
```

## Dependencies
- Server: fastapi, uvicorn, pywinpty, pyte, pywebpush, py-vapid
- Client: xterm ^4.0.0, flutter_local_notifications, flutter_foreground_task, connectivity_plus, web_socket_channel

## Configuration
- Server config: `server/config.json` (auto-generated on first run)
- Claude Code status line: `~/.claude/settings.json` (shows resume ID)
- Windows Firewall: Port 8765 must be open for remote access

## Language
- User prefers German UI text in the client
- Code comments and commit messages in English
