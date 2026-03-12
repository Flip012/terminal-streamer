import asyncio
import os
import sys
import uuid
import time
from dataclasses import dataclass, field
from typing import Optional

if sys.platform == "win32":
    import winpty
else:
    import pty
    import fcntl
    import struct
    import termios
    import signal


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

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "shell": self.shell,
            "created_at": self.created_at,
            "cols": self.cols,
            "rows": self.rows,
            "title": self.title or self.shell,
            "alive": self._alive,
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

        if sys.platform == "win32":
            self._start_winpty(session)
        else:
            self._start_unix_pty(session)

        self.sessions[session_id] = session
        return session

    def _start_winpty(self, session: TerminalSession):
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

    async def read_output(self, session_id: str) -> Optional[bytes]:
        session = self.sessions.get(session_id)
        if not session or not session._alive:
            return None

        try:
            if sys.platform == "win32":
                proc = session._process
                if not proc.isalive():
                    session._alive = False
                    return None
                data = await asyncio.get_event_loop().run_in_executor(
                    None, lambda: proc.read(4096)
                )
                return data.encode("utf-8") if isinstance(data, str) else data
            else:
                try:
                    data = os.read(session._master_fd, 4096)
                    return data
                except BlockingIOError:
                    return b""
                except OSError:
                    session._alive = False
                    return None
        except Exception:
            session._alive = False
            return None

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
