"""Micron OS system access for the file browser, editor, and terminal.

OS-level, no assistant involved. Jailed to the owner's home by default so a
web shell cannot wander the whole disk; the jail root is configurable but
defaults to $HOME. Path traversal is refused. This is the OS touching its own
machine on the owner's behalf -- the same trust boundary as any file manager.
"""

from __future__ import annotations
import os
from pathlib import Path

JAIL = Path(os.environ.get("MICRON_FILES_ROOT", str(Path.home()))).resolve()

def _safe(rel: str) -> Path:
    p = (JAIL / rel.lstrip("/")).resolve() if rel else JAIL
    p.relative_to(JAIL)                  # raises ValueError on escape
    return p

def list_dir(rel: str = "") -> dict:
    d = _safe(rel)
    if not d.is_dir():
        raise NotADirectoryError(rel)
    entries = []
    for child in sorted(d.iterdir(), key=lambda c: (not c.is_dir(), c.name.lower())):
        if child.name.startswith("."):
            continue
        try:
            entries.append({
                "name": child.name,
                "dir": child.is_dir(),
                "size": child.stat().st_size if child.is_file() else None,
            })
        except OSError:
            continue
    rel_display = str(d.relative_to(JAIL))
    return {"path": "" if rel_display == "." else rel_display, "entries": entries}

def read_file(rel: str, max_bytes: int = 2_000_000) -> dict:
    f = _safe(rel)
    if not f.is_file():
        raise FileNotFoundError(rel)
    raw = f.read_bytes()[:max_bytes]
    try:
        return {"path": rel, "text": raw.decode("utf-8"), "binary": False}
    except UnicodeDecodeError:
        return {"path": rel, "text": "", "binary": True}

def write_file(rel: str, text: str) -> dict:
    f = _safe(rel)
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(text)
    return {"path": rel, "bytes": len(text.encode("utf-8"))}
