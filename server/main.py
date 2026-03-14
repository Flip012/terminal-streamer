import asyncio
import base64
import json
import re
import signal
import sys
import time

from contextlib import asynccontextmanager
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from fastapi.security import APIKeyHeader
from pydantic import BaseModel
from typing import Optional
from pathlib import Path
from pywebpush import webpush, WebPushException

from config import load_config, get_default_shell
from terminal_manager import TerminalManager

config = load_config()
manager = TerminalManager()


@asynccontextmanager
async def lifespan(app: FastAPI):
    print(f"\n{'='*50}")
    print(f"  Terminal Streamer API")
    print(f"  Host: {config['host']}:{config['port']}")
    print(f"  API Key: {config['api_key']}")
    print(f"  Default Shell: {get_default_shell()}")
    print(f"{'='*50}\n")
    yield
    manager.destroy_all()


app = FastAPI(title="Terminal Streamer API", version="1.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)

# In-memory push subscription store: {endpoint: subscription_info}
push_subscriptions: dict[str, dict] = {}

# Track terminal output state per session for question detection
session_output_state: dict[str, dict] = {}
QUESTION_IDLE_SECONDS = 3  # seconds of silence before checking for question
OUTPUT_BUFFER_MAX = 4096  # max bytes to buffer for pattern matching

# Regex to strip ANSI escape sequences
ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]|\x1b\].*?\x07|\x1b[()][AB012]|\x1b\[[\?]?[0-9;]*[hlm]")


def strip_ansi(text: str) -> str:
    return ANSI_ESCAPE_RE.sub("", text)


def detect_question(raw_text: str) -> Optional[str]:
    """Detect if terminal output contains a Claude Code question waiting for input.

    Returns extracted question text or None.
    """
    text = strip_ansi(raw_text)
    lines = [l.strip() for l in text.strip().splitlines() if l.strip()]
    if not lines:
        return None

    # Check last ~15 lines for question patterns
    tail = lines[-15:]

    # Claude Code permission prompts (tool approval)
    # e.g. "Allow Read /path?" or "Allow mcp__tool?"
    for line in reversed(tail):
        if re.search(r"\bAllow\b.*\?", line, re.IGNORECASE):
            return line

    # AskUserQuestion: numbered/bulleted options after a question
    # Look for a line ending with ? followed by option lines
    for i, line in enumerate(tail):
        if line.endswith("?"):
            # Check if followed by option-like lines (numbered, bulleted, or radio)
            remaining = tail[i + 1:]
            option_count = sum(
                1 for r in remaining
                if re.match(r"^(\d+[\.\)]\s|[-•●◉◯►▸]\s|>\s|\(\s*\)\s|\(\s*[xX•]\s*\)\s)", r)
            )
            if option_count >= 2:
                return line
            # Even without options, a question at the end of output is relevant
            if i >= len(tail) - 3:
                return line

    # Generic question at the very end (last 3 lines)
    for line in reversed(tail[-3:]):
        if line.endswith("?") and len(line) > 10:
            return line

    # y/n, yes/no, j/n (German) prompts
    for line in reversed(tail[-3:]):
        if re.search(
            r"\(y/n\)|\(Y/n\)|\(y/N\)|\[y/N\]|\[Y/n\]"
            r"|\(yes/no\)|\(Yes/No\)"
            r"|\(j/n\)|\(J/n\)|\(j/N\)|\[j/N\]|\[J/n\]",
            line,
            re.IGNORECASE,
        ):
            return line

    # "Press Enter/key to continue" prompts
    for line in reversed(tail[-3:]):
        if re.search(
            r"Press .+ to continue|Drücke .+ um fortzufahren"
            r"|Press Enter|Hit Enter",
            line,
            re.IGNORECASE,
        ):
            return line

    # "Enter/Provide X:" or "Confirm X:" input prompts (line ends with :)
    for line in reversed(tail[-3:]):
        if re.search(
            r"^(Enter|Provide|Confirm|Select|Choose|Eingabe|Bitte)\b.+:\s*$",
            line,
            re.IGNORECASE,
        ):
            return line

    return None


async def verify_api_key(api_key: Optional[str] = Depends(api_key_header)):
    if api_key != config["api_key"]:
        raise HTTPException(status_code=403, detail="Invalid API key")


def verify_ws_api_key(api_key: str) -> bool:
    return api_key == config["api_key"]


# --- REST endpoints for session management ---


class CreateSessionRequest(BaseModel):
    shell: Optional[str] = None
    cols: int = 120
    rows: int = 30
    title: str = ""


class ResizeRequest(BaseModel):
    cols: int
    rows: int


@app.get("/api/sessions", dependencies=[Depends(verify_api_key)])
async def list_sessions():
    return {"sessions": manager.list_sessions()}


@app.post("/api/sessions", dependencies=[Depends(verify_api_key)])
async def create_session(req: CreateSessionRequest):
    shell = req.shell or get_default_shell()
    session = manager.create_session(
        shell=shell, cols=req.cols, rows=req.rows, title=req.title
    )
    return {"session": session.to_dict()}


@app.delete("/api/sessions/{session_id}", dependencies=[Depends(verify_api_key)])
async def delete_session(session_id: str):
    if manager.destroy_session(session_id):
        return {"status": "ok"}
    raise HTTPException(status_code=404, detail="Session not found")


@app.post("/api/sessions/{session_id}/resize", dependencies=[Depends(verify_api_key)])
async def resize_session(session_id: str, req: ResizeRequest):
    if manager.resize(session_id, req.cols, req.rows):
        return {"status": "ok"}
    raise HTTPException(status_code=404, detail="Session not found")


# --- Push notification endpoints ---


class PushSubscriptionRequest(BaseModel):
    subscription: dict


@app.get("/api/push/vapid-public-key", dependencies=[Depends(verify_api_key)])
async def get_vapid_public_key():
    return {"publicKey": config["vapid_public_key"]}


@app.post("/api/push/subscribe", dependencies=[Depends(verify_api_key)])
async def push_subscribe(req: PushSubscriptionRequest):
    endpoint = req.subscription.get("endpoint", "")
    if not endpoint:
        raise HTTPException(status_code=400, detail="Missing endpoint")
    push_subscriptions[endpoint] = req.subscription
    return {"status": "ok"}


@app.post("/api/push/unsubscribe", dependencies=[Depends(verify_api_key)])
async def push_unsubscribe(req: PushSubscriptionRequest):
    endpoint = req.subscription.get("endpoint", "")
    push_subscriptions.pop(endpoint, None)
    return {"status": "ok"}


def send_push_notification(title: str, body: str, tag: str = "terminal"):
    """Send push notification to all subscribed clients."""
    dead_endpoints = []
    for endpoint, sub_info in push_subscriptions.items():
        try:
            webpush(
                subscription_info=sub_info,
                data=json.dumps({"title": title, "body": body, "tag": tag}),
                vapid_private_key=config["vapid_private_key"],
                vapid_claims={"sub": config["vapid_contact"]},
            )
        except WebPushException as e:
            if e.response and e.response.status_code in (404, 410):
                dead_endpoints.append(endpoint)
        except Exception:
            pass
    for ep in dead_endpoints:
        push_subscriptions.pop(ep, None)


# --- Serve web client ---

CLIENT_WEB_DIR = Path(__file__).parent.parent / "client-web"

app.mount("/web", StaticFiles(directory=str(CLIENT_WEB_DIR), html=True), name="client-web")


# --- WebSocket endpoint for terminal I/O ---


@app.websocket("/ws/terminal/{session_id}")
async def terminal_websocket(websocket: WebSocket, session_id: str):
    # Authenticate via query parameter
    api_key = websocket.query_params.get("api_key", "")
    if not verify_ws_api_key(api_key):
        await websocket.close(code=4003, reason="Invalid API key")
        return

    if session_id not in manager.sessions:
        await websocket.close(code=4004, reason="Session not found")
        return

    await websocket.accept()

    async def read_terminal():
        """Read terminal output and send to client."""
        subscription = manager.subscribe(session_id)
        if not subscription:
            try:
                await websocket.send_json({"type": "exit"})
            except Exception:
                pass
            return

        queue, history = subscription
        state = {"buffer": "", "last_output_time": time.time(), "notified": False}

        try:
            # Send history first so the client sees the "current picture"
            if history:
                await websocket.send_json({
                    "type": "output",
                    "data": base64.b64encode(history).decode("ascii"),
                })
                # Buffer history for question detection
                text = history.decode("utf-8", errors="replace")
                state["buffer"] = text[-OUTPUT_BUFFER_MAX:]

            while True:
                try:
                    data = await asyncio.wait_for(queue.get(), timeout=0.5)
                except asyncio.TimeoutError:
                    # Check for questions during idle periods
                    idle = time.time() - state["last_output_time"]
                    if (
                        idle >= QUESTION_IDLE_SECONDS
                        and not state["notified"]
                        and push_subscriptions
                        and state["buffer"]
                    ):
                        question = detect_question(state["buffer"])
                        if question:
                            state["notified"] = True
                            send_push_notification(
                                "Claude Code wartet",
                                question[:150],
                                tag=f"question-{session_id}",
                            )
                    continue

                if data is None:  # Session ended
                    await websocket.send_json({"type": "exit"})
                    if push_subscriptions:
                        send_push_notification(
                            "Session beendet",
                            f"Terminal-Session {session_id[:8]}... wurde beendet.",
                            tag=f"exit-{session_id}",
                        )
                    break

                if data:
                    state["last_output_time"] = time.time()
                    state["notified"] = False

                    # Buffer recent output for question detection
                    text = data.decode("utf-8", errors="replace")
                    state["buffer"] = (state["buffer"] + text)[-OUTPUT_BUFFER_MAX:]

                    # Send as base64 to preserve binary data
                    await websocket.send_json({
                        "type": "output",
                        "data": base64.b64encode(data).decode("ascii"),
                    })
        except Exception:
            pass
        finally:
            manager.unsubscribe(session_id, queue)

    async def write_terminal():
        """Read client input and write to terminal."""
        try:
            while True:
                message = await websocket.receive_json()
                msg_type = message.get("type", "")

                if msg_type == "input":
                    data = message.get("data", "")
                    manager.write_input(session_id, data)
                elif msg_type == "resize":
                    cols = message.get("cols", 120)
                    rows = message.get("rows", 30)
                    manager.resize(session_id, cols, rows)
        except WebSocketDisconnect:
            pass

    reader = asyncio.create_task(read_terminal())
    writer = asyncio.create_task(write_terminal())

    try:
        done, pending = await asyncio.wait(
            [reader, writer], return_when=asyncio.FIRST_COMPLETED
        )
        for task in pending:
            task.cancel()
    except Exception:
        reader.cancel()
        writer.cancel()



def main():
    import uvicorn

    uvicorn.run(
        "main:app",
        host=config["host"],
        port=config["port"],
        reload=False,
    )


if __name__ == "__main__":
    main()
