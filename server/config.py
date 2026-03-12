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
}


def load_config() -> dict:
    config = DEFAULT_CONFIG.copy()
    if CONFIG_FILE.exists():
        with open(CONFIG_FILE, "r") as f:
            config.update(json.load(f))
    if not config["api_key"]:
        config["api_key"] = secrets.token_urlsafe(32)
        save_config(config)
    return config


def save_config(config: dict):
    with open(CONFIG_FILE, "w") as f:
        json.dump(config, f, indent=2)


def get_default_shell() -> str:
    config = load_config()
    if config["default_shell"]:
        return config["default_shell"]
    if os.name == "nt":
        return os.environ.get("COMSPEC", "cmd.exe")
    return os.environ.get("SHELL", "/bin/bash")
