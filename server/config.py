import os
import json
import secrets
from pathlib import Path

CONFIG_FILE = Path(__file__).parent / "config.json"

DEFAULT_CONFIG = {
    "host": "0.0.0.0",
    "port": 8765,
    "api_key": "",
    "default_shell": "",  # empty = auto-detect
    "vapid_private_key": "",
    "vapid_public_key": "",
    "vapid_contact": "mailto:admin@terminal-streamer.local",
}


def load_config() -> dict:
    config = DEFAULT_CONFIG.copy()
    if CONFIG_FILE.exists():
        with open(CONFIG_FILE, "r") as f:
            config.update(json.load(f))
    if not config["api_key"]:
        config["api_key"] = secrets.token_urlsafe(32)
        save_config(config)
    if not config["vapid_private_key"]:
        import base64
        from py_vapid import Vapid
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
        vapid = Vapid()
        vapid.generate_keys()
        config["vapid_private_key"] = vapid.private_pem().decode("utf-8")
        raw_pub = vapid.public_key.public_bytes(
            encoding=Encoding.X962,
            format=PublicFormat.UncompressedPoint,
        )
        config["vapid_public_key"] = base64.urlsafe_b64encode(raw_pub).decode("utf-8").rstrip("=")
        save_config(config)
    return config


def save_config(config: dict):
    with open(CONFIG_FILE, "w") as f:
        json.dump(config, f, indent=2)


def get_default_shell(config: dict | None = None) -> str:
    if config is None:
        config = load_config()
    if config["default_shell"]:
        return config["default_shell"]
    if os.name == "nt":
        return os.environ.get("COMSPEC", "cmd.exe")
    return os.environ.get("SHELL", "/bin/bash")
