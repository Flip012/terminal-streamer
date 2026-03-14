import asyncio
import base64
import json
import os
import re
import sys
import uuid
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import pyte

# Regex to detect Claude Code resume ID from the status line ("/resume <uuid>")
_CLAUDE_RESUME_RE = re.compile(r"/resume\s+([0-9a-f-]{36})")

if sys.platform == "win32":
    import winpty
else:
    import pty
    import fcntl
    import struct
    import termios
    import signal


# ANSI color name → SGR foreground code
_FG_COLORS = {
    "black": "30", "red": "31", "green": "32", "brown": "33",
    "blue": "34", "magenta": "35", "cyan": "36", "white": "37",
    "default": None,
}
_BG_COLORS = {
    "black": "40", "red": "41", "green": "42", "brown": "43",
    "blue": "44", "magenta": "45", "cyan": "46", "white": "47",
    "default": None,
}


def _screen_to_ansi(screen: pyte.Screen) -> bytes:
    """Convert pyte screen buffer to ANSI-escaped bytes for the client."""
    lines = []
    for y in range(screen.lines):
        parts = []
        prev_attrs = None
        for x in range(screen.columns):
            char = screen.buffer[y][x]
            attrs = (char.fg, char.bg, char.bold, char.underscore, char.reverse)
            if attrs != prev_attrs:
                codes = ["0"]  # reset
                if char.bold:
                    codes.append("1")
                if char.underscore:
                    codes.append("4")
                if char.reverse:
                    codes.append("7")
                fg = char.fg
                if fg and fg != "default":
                    if fg in _FG_COLORS and _FG_COLORS[fg]:
                        codes.append(_FG_COLORS[fg])
                    elif isinstance(fg, str) and len(fg) == 6:
                        # 24-bit color hex
                        try:
                            r, g, b = int(fg[0:2], 16), int(fg[2:4], 16), int(fg[4:6], 16)
                            codes.append(f"38;2;{r};{g};{b}")
                        except ValueError:
                            pass
                bg = char.bg
                if bg and bg != "default":
                    if bg in _BG_COLORS and _BG_COLORS[bg]:
                        codes.append(_BG_COLORS[bg])
                    elif isinstance(bg, str) and len(bg) == 6:
                        try:
                            r, g, b = int(bg[0:2], 16), int(bg[2:4], 16), int(bg[4:6], 16)
                            codes.append(f"48;2;{r};{g};{b}")
                        except ValueError:
                            pass
                parts.append(f"\x1b[{';'.join(codes)}m")
                prev_attrs = attrs
            parts.append(char.data)
        # Strip trailing whitespace but keep the line
        line = "".join(parts).rstrip()
        lines.append(line)

    # Remove trailing empty lines
    while lines and not lines[-1].strip() and not lines[-1]:
        lines.pop()

    result = "\r\n".join(lines) + "\x1b[0m"

    # Add cursor position
    cursor_y = screen.cursor.y + 1
    cursor_x = screen.cursor.x + 1
    result += f"\x1b[{cursor_y};{cursor_x}H"

    return result.encode("utf-8")


@dataclass
class TerminalSession:
    id: str
    shell: str
    created_at: float
    cols: int = 120
    rows: int = 30
    title: str = ""
    _process: object = field(default=None, repr=False)
    _master_fd: Optional[int] = field(default=None, repr=False)
    _pid: Optional[int] = field(default=None, repr=False)
    _alive: bool = field(default=True, repr=False)
    _output_history: bytes = field(default=b"", repr=False)
    _subscribers: list[asyncio.Queue] = field(default_factory=list, repr=False)
    _reader_task: Optional[asyncio.Task] = field(default=None, repr=False)
    _history_limit: int = 100 * 1024  # 100 KB history
    _pyte_screen: object = field(default=None, repr=False)
    _pyte_stream: object = field(default=None, repr=False)
    _restored: bool = field(default=False, repr=False)
    _claude_resume_id: Optional[str] = field(default=None, repr=False)
    _auto_resume_sent: bool = field(default=False, repr=False)

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "shell": self.shell,
            "created_at": self.created_at,
            "cols": self.cols,
            "rows": self.rows,
            "title": self.title or self.shell,
            "alive": self._alive,
            "restored": self._restored,
            "claude_resume_id": self._claude_resume_id,
        }


class TerminalManager:
    def __init__(self):
        self.sessions: dict[str, TerminalSession] = {}

    def create_session(
        self, shell: str, cols: int = 120, rows: int = 30, title: str = ""
    ) -> TerminalSession:
        session_id = str(uuid.uuid4())
        session = TerminalSession(
            id=session_id,
            shell=shell,
            created_at=time.time(),
            cols=cols,
            rows=rows,
            title=title,
        )

        # Virtual terminal for tracking screen state
        session._pyte_screen = pyte.Screen(cols, rows)
        session._pyte_stream = pyte.ByteStream(session._pyte_screen)

        if sys.platform == "win32":
            self._start_winpty(session)
        else:
            self._start_unix_pty(session)

        self.sessions[session_id] = session

        # Start background reader
        session._reader_task = asyncio.create_task(self._read_loop(session_id))

        return session

    async def _read_loop(self, session_id: str):
        """Continuously read from PTY and broadcast to subscribers."""
        session = self.sessions.get(session_id)
        if not session:
            return

        while session._alive:
            try:
                data = await self._read_from_pty(session)
                if data is None:
                    session._alive = False
                    break

                if data:
                    # Update raw history for question detection
                    session._output_history += data
                    if len(session._output_history) > session._history_limit:
                        trimmed = session._output_history[-session._history_limit:]
                        i = 0
                        while i < len(trimmed) and (trimmed[i] & 0xC0) == 0x80:
                            i += 1
                        session._output_history = trimmed[i:]

                    # Feed into pyte virtual terminal
                    try:
                        session._pyte_stream.feed(data)
                    except Exception:
                        pass

                    # Detect Claude Code resume ID in output
                    try:
                        text = data.decode("utf-8", errors="ignore")
                        match = _CLAUDE_RESUME_RE.search(text)
                        if match:
                            session._claude_resume_id = match.group(1)
                    except Exception:
                        pass

                    # Broadcast to subscribers
                    for queue in session._subscribers:
                        await queue.put(data)
                else:
                    await asyncio.sleep(0.02)
            except Exception:
                session._alive = False
                break

        # Notify all subscribers that session ended
        for queue in session._subscribers:
            await queue.put(None)

    async def _read_from_pty(self, session: TerminalSession) -> Optional[bytes]:
        """Low-level PTY read."""
        try:
            if sys.platform == "win32":
                proc = session._process
                if not proc.isalive():
                    return None
                data = await asyncio.get_event_loop().run_in_executor(
                    None, lambda: proc.read(4096)
                )
                # winpty returns a string (already decoded)
                return data.encode("utf-8") if isinstance(data, str) else data
            else:
                try:
                    data = os.read(session._master_fd, 4096)
                    return data
                except BlockingIOError:
                    return b""
                except OSError:
                    return None
        except Exception:
            return None

    def get_screen_snapshot(self, session_id: str) -> Optional[bytes]:
        """Get the current screen content as ANSI-formatted bytes via pyte."""
        session = self.sessions.get(session_id)
        if not session or not session._pyte_screen:
            return None
        try:
            return _screen_to_ansi(session._pyte_screen)
        except Exception:
            return None

    def subscribe(self, session_id: str) -> Optional[tuple[asyncio.Queue, bytes]]:
        """Subscribe to terminal output. Returns (queue, raw_history)."""
        session = self.sessions.get(session_id)
        if not session or not session._alive:
            return None

        queue = asyncio.Queue()
        session._subscribers.append(queue)
        return queue, session._output_history

    def unsubscribe(self, session_id: str, queue: asyncio.Queue):
        """Unsubscribe from terminal output."""
        session = self.sessions.get(session_id)
        if session:
            try:
                session._subscribers.remove(queue)
            except ValueError:
                pass

    async def _auto_resume_claude(self, session_id: str, resume_id: str):
        """Wait for the shell to be ready, then send 'claude --resume <id>'."""
        # Give the shell a moment to start and show its prompt
        await asyncio.sleep(1.5)
        session = self.sessions.get(session_id)
        if not session or not session._alive:
            return
        cmd = f"claude --resume {resume_id}\n"
        self.write_input(session_id, cmd)

    def _start_winpty(self, session: TerminalSession):
        os.environ.setdefault("TERM", "xterm-256color")
        proc = winpty.PtyProcess.spawn(
            session.shell,
            dimensions=(session.rows, session.cols),
        )
        session._process = proc

    def _start_unix_pty(self, session: TerminalSession):
        pid, master_fd = pty.fork()
        if pid == 0:
            # Child process
            os.execvp(session.shell, [session.shell])
        else:
            # Parent process
            session._master_fd = master_fd
            session._pid = pid
            # Set terminal size
            winsize = struct.pack("HHHH", session.rows, session.cols, 0, 0)
            fcntl.ioctl(master_fd, termios.TIOCSWINSZ, winsize)
            # Set non-blocking
            flags = fcntl.fcntl(master_fd, fcntl.F_GETFL)
            fcntl.fcntl(master_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)


    def write_input(self, session_id: str, data: str) -> bool:
        session = self.sessions.get(session_id)
        if not session or not session._alive:
            return False

        try:
            if sys.platform == "win32":
                session._process.write(data)
            else:
                os.write(session._master_fd, data.encode("utf-8"))
            return True
        except Exception:
            session._alive = False
            return False

    def resize(self, session_id: str, cols: int, rows: int) -> bool:
        session = self.sessions.get(session_id)
        if not session or not session._alive:
            return False

        session.cols = cols
        session.rows = rows

        # Resize pyte virtual terminal
        if session._pyte_screen:
            session._pyte_screen.resize(rows, cols)

        try:
            if sys.platform == "win32":
                session._process.setwinsize(rows, cols)
            else:
                winsize = struct.pack("HHHH", rows, cols, 0, 0)
                fcntl.ioctl(session._master_fd, termios.TIOCSWINSZ, winsize)
                # Notify process of resize
                os.kill(session._pid, signal.SIGWINCH)
            return True
        except Exception:
            return False

    def destroy_session(self, session_id: str) -> bool:
        session = self.sessions.pop(session_id, None)
        if not session:
            return False

        session._alive = False
        if session._reader_task:
            session._reader_task.cancel()

        try:
            if sys.platform == "win32":
                if session._process and session._process.isalive():
                    session._process.terminate()
            else:
                if session._master_fd is not None:
                    os.close(session._master_fd)
                if session._pid is not None:
                    try:
                        os.kill(session._pid, signal.SIGTERM)
                        os.waitpid(session._pid, os.WNOHANG)
                    except (ProcessLookupError, ChildProcessError):
                        pass
        except Exception:
            pass
        return True

    def list_sessions(self) -> list[dict]:
        # Check alive status for unix sessions
        if sys.platform != "win32":
            for session in self.sessions.values():
                if session._pid is not None and session._alive:
                    try:
                        pid, status = os.waitpid(session._pid, os.WNOHANG)
                        if pid != 0:
                            session._alive = False
                    except ChildProcessError:
                        session._alive = False
        return [s.to_dict() for s in self.sessions.values()]

    def destroy_all(self):
        for session_id in list(self.sessions.keys()):
            self.destroy_session(session_id)

    def save_sessions(self, filepath: Path):
        """Save all active sessions to disk for persistence across restarts."""
        sessions_data = []
        for session in self.sessions.values():
            if not session._alive:
                continue
            snapshot = b""
            if session._pyte_screen:
                try:
                    snapshot = _screen_to_ansi(session._pyte_screen)
                except Exception:
                    pass
            sessions_data.append({
                "id": session.id,
                "shell": session.shell,
                "title": session.title,
                "cols": session.cols,
                "rows": session.rows,
                "created_at": session.created_at,
                "screen_snapshot_b64": base64.b64encode(snapshot).decode("ascii"),
                "output_history_b64": base64.b64encode(session._output_history).decode("ascii"),
                "claude_resume_id": session._claude_resume_id,
            })

        data = {
            "version": 1,
            "saved_at": time.time(),
            "sessions": sessions_data,
        }

        # Atomic write: write to temp file, then rename
        tmp = filepath.with_suffix(".tmp")
        try:
            with open(tmp, "w") as f:
                json.dump(data, f, indent=2)
            tmp.replace(filepath)
        except Exception as e:
            print(f"Warning: Failed to save sessions: {e}")

    def restore_sessions(self, filepath: Path):
        """Restore sessions from disk, creating new PTY processes."""
        if not filepath.exists():
            return

        try:
            with open(filepath, "r") as f:
                data = json.load(f)
        except (json.JSONDecodeError, OSError) as e:
            print(f"Warning: Failed to read sessions file: {e}")
            return

        # Delete file after reading to avoid re-restoring on next crash
        try:
            filepath.unlink()
        except OSError:
            pass

        for entry in data.get("sessions", []):
            try:
                session = TerminalSession(
                    id=entry["id"],
                    shell=entry["shell"],
                    created_at=entry.get("created_at", time.time()),
                    cols=entry.get("cols", 120),
                    rows=entry.get("rows", 30),
                    title=entry.get("title", ""),
                    _restored=True,
                )

                # Initialize pyte screen
                session._pyte_screen = pyte.Screen(session.cols, session.rows)
                session._pyte_stream = pyte.ByteStream(session._pyte_screen)

                # Restore screen snapshot for non-Claude sessions so the
                # user sees previous output. Claude sessions skip this
                # since auto-resume provides fresh content.
                claude_resume_id = entry.get("claude_resume_id")
                if not claude_resume_id:
                    snapshot_b64 = entry.get("screen_snapshot_b64", "")
                    if snapshot_b64:
                        try:
                            session._pyte_stream.feed(base64.b64decode(snapshot_b64))
                        except Exception:
                            pass

                # Restore output history only for question detection buffer
                history_b64 = entry.get("output_history_b64", "")
                if history_b64:
                    try:
                        session._output_history = base64.b64decode(history_b64)
                    except Exception:
                        pass

                # Restore Claude Code resume ID
                session._claude_resume_id = entry.get("claude_resume_id")

                # Restoration marker — only in history, not in pyte
                # (feeding it into pyte would shift the cursor position)
                marker = b"\r\n\x1b[33m--- Session restored ---\x1b[0m\r\n"
                if session._claude_resume_id:
                    marker += f"\x1b[33mAuto-resuming Claude Code session {session._claude_resume_id[:8]}...\x1b[0m\r\n".encode()
                session._output_history += marker

                # Start a fresh PTY process
                if sys.platform == "win32":
                    self._start_winpty(session)
                else:
                    self._start_unix_pty(session)

                self.sessions[session.id] = session
                session._reader_task = asyncio.create_task(self._read_loop(session.id))

                # Auto-resume Claude Code if we have a resume ID
                if session._claude_resume_id:
                    session._auto_resume_sent = True
                    asyncio.create_task(
                        self._auto_resume_claude(session.id, session._claude_resume_id)
                    )

            except Exception as e:
                print(f"Warning: Failed to restore session {entry.get('id', '?')}: {e}")
