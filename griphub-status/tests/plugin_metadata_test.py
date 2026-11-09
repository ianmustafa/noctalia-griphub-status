#!/usr/bin/env python3
"""Offline acceptance checks for the distributable plugin metadata."""
from pathlib import Path
import json
import tomllib

ROOT = Path(__file__).resolve().parent.parent
manifest = tomllib.loads((ROOT / "plugin.toml").read_text())
translations = json.loads((ROOT / "translations/en.json").read_text())
readme = (ROOT / "README.md").read_text()

assert manifest["id"] == "ianmustafa/griphub-status"
assert manifest["plugin_api"] == 24
for required_file in ("README.md", "thumbnail.webp", "translations/en.json"):
    assert (ROOT / required_file).is_file(), f"missing catalog file {required_file}"

assert manifest["widget"][0]["id"] == "bar"
assert manifest["widget"][0]["entry"] == "widget.luau"

assert "community" in manifest["description"].lower()

settings = {setting["key"]: setting for setting in manifest["setting"]}
token = settings["token"]
assert token["type"] == "string"
# `secret` requires plugin_api >= 47, which would exclude API 43 shells.
assert "secret" not in token
assert token["default"] == ""
assert settings["refresh_seconds"]["default"] == 30
assert (settings["refresh_seconds"]["min"], settings["refresh_seconds"]["max"]) == (1, 86400)
assert settings["precision"]["default"] == 1
assert (settings["precision"]["min"], settings["precision"]["max"]) == (0, 4)
assert settings["glyph"]["default"] == "lightning"

def has_translation(path):
    value = translations
    for segment in path.split("."):
        value = value[segment]
    return isinstance(value, str) and value

for setting in settings.values():
    assert has_translation(setting["label_key"])
    assert has_translation(setting["description_key"])

required_documentation = (
    "Settings → Plugins",
    "refresh",
    "precision",
    "glyph",
    "stale",
    "suspended",
    "Authentication failed",
    "Service unavailable",
    "https://griphubrouter.web.id/portal",
    "not official Noctalia",
    "submission",
)
for phrase in required_documentation:
    assert phrase.lower() in readme.lower(), f"README missing {phrase!r}"

print("plugin metadata acceptance passed")
