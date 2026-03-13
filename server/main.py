import asyncio
import base64
import json
import signal
import sys
import time

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
app = FastAPI(title="Terminal Streamer API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)
manager = TerminalManager()

# In-memory push subscription store: {endpoint: subscription_info}
push_subscriptions: dict[str, dict] = {}

# Track last output time per session for idle detection
last_output_time: dict[str, float] = {}
IDLE_THRESHOLD_SECONDS = 5  # notify if output after this many seconds of silence


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
        while True:
            session = manager.sessions.get(session_id)
            if not session or not session._alive:
                try:
                    await websocket.send_json({"type": "exit"})
                except Exception:
                    pass
                if push_subscriptions:
                    send_push_notification(
                        "Session beendet",
                        f"Terminal-Session {session_id[:8]}... wurde beendet.",
                        tag=f"exit-{session_id}",
                    )
                last_output_time.pop(session_id, None)
                break

            data = await manager.read_output(session_id)
            if data is None:
                try:
                    await websocket.send_json({"type": "exit"})
                except Exception:
                    pass
                last_output_time.pop(session_id, None)
                break
            if data:
                now = time.time()
                prev = last_output_time.get(session_id, now)
                idle_duration = now - prev
                last_output_time[session_id] = now

                # Send push if output arrives after idle period
                if idle_duration >= IDLE_THRESHOLD_SECONDS and push_subscriptions:
                    preview = data[:200].decode("utf-8", errors="replace").strip()
                    send_push_notification(
                        "Neue Terminal-Ausgabe",
                        preview[:120],
                        tag=f"output-{session_id}",
                    )

                # Send as base64 to preserve binary data
                await websocket.send_json({
                    "type": "output",
                    "data": base64.b64encode(data).decode("ascii"),
                })
            else:
                await asyncio.sleep(0.02)

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


@app.on_event("startup")
async def startup():
    print(f"\n{'='*50}")
    print(f"  Terminal Streamer API")
    print(f"  Host: {config['host']}:{config['port']}")
    print(f"  API Key: {config['api_key']}")
    print(f"  Default Shell: {get_default_shell()}")
    print(f"{'='*50}\n")


@app.on_event("shutdown")
async def shutdown():
    manager.destroy_all()


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
