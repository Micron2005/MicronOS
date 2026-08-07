#!/usr/bin/env python3
"""Micron OS server: shell, apps, settings, lock. A complete OS surface
with NO assistant required. If one is installed (Alfred is the reference),
it is hosted in-process and the assistant surfaces light up.

    python3 run_server.py --config configs/desktop.toml --port 8710

Wraps the same Alfred core that run_core.py drives, behind a small HTTP API,
and serves the Micron OS shell at http://localhost:8710. The REPL keeps
working; this is an additional interface, not a replacement.

Standard library only, on purpose: the shell server is part of the OS's
spine, and the spine should not acquire dependencies. The HTTP server runs
in threads; Alfred lives on one asyncio loop; requests bridge across with
run_coroutine_threadsafe. Conversations are serialized with a lock because
there is one Alfred — two simultaneous conversations would interleave his
memory writes.

Endpoints:
    GET  /                    the shell
    POST /api/chat            {"message": str, "project_id": str|null}
    GET  /api/status          machines, projects, undelivered notices
    GET  /api/health          liveness for systemd
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# Micron OS is a complete operating system WITHOUT any assistant installed.
# An assistant is a PROGRAM the owner installs: any module implementing
# assistant_api.AssistantProvider, named in configs/micron.toml. The OS
# hosts whoever that says -- Alfred is merely the reference implementation.
import os as _os, sys as _sys
try:
    import tomllib as _toml
except ImportError:      # py<3.11
    _toml = None
from pathlib import Path as _P

def _load_provider_factory():
    module = _os.environ.get("MICRON_ASSISTANT_MODULE")
    path = _os.environ.get("MICRON_ASSISTANT_PATH")
    cfg_file = _P(__file__).parent / "configs" / "micron.toml"
    if (not module) and _toml and cfg_file.exists():
        try:
            data = _toml.loads(cfg_file.read_text())
            module = (data.get("assistant") or {}).get("module")
            path = path or (data.get("assistant") or {}).get("path")
        except Exception:
            module = None
    if not module:
        return None, None
    if path:
        pp = str(_P(path).expanduser())
        if pp not in _sys.path:
            _sys.path.insert(0, pp)
    try:
        import importlib
        mod = importlib.import_module(module)
        return getattr(mod, "create_provider"), module
    except Exception as exc:
        print(f"assistant module {module!r} not loadable: {exc}")
        return None, None

_PROVIDER_FACTORY, _PROVIDER_MODULE = _load_provider_factory()
ASSISTANT = _PROVIDER_FACTORY is not None

import micron_lock as shell_lock

log = logging.getLogger("alfred.server")
SHELL = Path(__file__).parent / "shell" / "index.html"
LOGIN_HTML = (Path(__file__).parent / "shell" / "login.html").read_text() \
    if (Path(__file__).parent / "shell" / "login.html").exists() else "<h1>Micron OS locked</h1>"
APPS_DIR = Path(__file__).parent / "apps"
APPDATA_DIR = Path("~/.alfred/appdata").expanduser()
INBOX_DIR = Path("~/.alfred/inbox").expanduser()
MAX_UPLOAD_BYTES = 200 * 1024 * 1024
MAX_APPDATA_BYTES = 5 * 1024 * 1024
MIME_BY_EXT = {".html": "text/html; charset=utf-8", ".js": "text/javascript",
               ".css": "text/css", ".json": "application/json",
               ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg"}
WALLPAPER = Path("~/.alfred/wallpaper.img").expanduser()
WALLPAPER_MIME = Path("~/.alfred/wallpaper.mime").expanduser()
MAX_WALLPAPER_BYTES = 15 * 1024 * 1024

# Chat can legitimately take minutes on CPU inference; systemd and browsers
# both need to know this is expected, not a hang.
CHAT_TIMEOUT_S = 600


class Bridge:
    """Threads (HTTP) to loop (assistant) adapter. Knows only the Assistant
    Interface; contains not one line of any particular assistant."""

    def __init__(self, provider, loop: asyncio.AbstractEventLoop) -> None:
        self.provider = provider          # None: Micron OS standalone
        self.loop = loop
        self.default_project = None

    # legacy alias used by a few endpoints
    @property
    def alfred(self):
        return self.provider

    def _run(self, coro, timeout):
        return asyncio.run_coroutine_threadsafe(coro, self.loop).result(timeout=timeout)

    def chat(self, message: str, project_id: str | None,
             attachments: list[str] | None = None) -> str:
        if self.provider is None:
            raise RuntimeError("no assistant installed")
        return self._run(self.provider.chat(message, project_id, attachments),
                         timeout=600)

    def speech_available(self) -> set[str]:
        if self.provider is None:
            return set()
        try:
            return self._run(self.provider.speech_capabilities(), timeout=10)
        except Exception:
            return set()

    def transcribe(self, audio: bytes, fmt: str) -> str:
        if self.provider is None:
            raise ImportError("no assistant installed")
        return self._run(self.provider.transcribe(audio, fmt), timeout=120)

    def synthesize(self, text: str) -> bytes:
        if self.provider is None:
            raise RuntimeError("no assistant installed")
        return self._run(self.provider.synthesize(text), timeout=90)

    def approve_action(self, action_id: int):
        return self._run(self.provider.approve_action(action_id), timeout=300)

    def decline_action(self, action_id: int):
        return self._run(self.provider.decline_action(action_id), timeout=30)

    def status(self) -> dict:
        base = {"assistant": self.provider is not None,
                "assistant_name": getattr(self.provider, "name", None),
                "pending_actions": [], "nodes": [], "workers": [],
                "projects": [], "notices": [], "default_project": None}
        if self.provider is None:
            return base
        try:
            extra = self._run(self.provider.status(), timeout=15)
            base.update(extra or {})
        except Exception as exc:
            base["status_error"] = str(exc)
        return base

        future = asyncio.run_coroutine_threadsafe(_gather(), self.loop)
        return future.result(timeout=15)


def make_handler(bridge: Bridge):
    class Handler(BaseHTTPRequestHandler):
        server_version = "MicronOS/0.1"

        def _send(self, code: int, body: bytes, ctype: str) -> None:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _json(self, code: int, payload: dict) -> None:
            self._send(code, json.dumps(payload).encode(), "application/json")

        def _authed(self) -> bool:
            return shell_lock.token_valid(shell_lock.cookie_from(self.headers))

        def do_GET(self) -> None:  # noqa: N802 (stdlib naming)
            if self.path == "/api/health":
                self._json(200, {"ok": True, "locked": shell_lock.is_set()})
                return
            if shell_lock.is_set() and not self._authed():
                if self.path in {"/", "/index.html"}:
                    self._send(200, LOGIN_HTML.encode(), "text/html; charset=utf-8")
                else:
                    self._json(401, {"error": "locked"})
                return
            if self.path in {"/", "/index.html"}:
                if SHELL.exists():
                    self._send(200, SHELL.read_bytes(), "text/html; charset=utf-8")
                else:
                    self._send(200, b"Micron OS shell missing; API is up.", "text/plain")
            elif self.path == "/api/status":
                try:
                    self._json(200, bridge.status())
                except Exception as exc:
                    self._json(500, {"error": str(exc)})
            elif self.path == "/api/apps":
                # An app is a folder in apps/ with an app.json. That is the
                # entire registry — no database, no build step. Delete the
                # folder and the app has never existed.
                apps = []
                if APPS_DIR.is_dir():
                    for d in sorted(APPS_DIR.iterdir()):
                        manifest = d / "app.json"
                        if d.is_dir() and manifest.exists():
                            try:
                                meta = json.loads(manifest.read_text())
                                meta["id"] = d.name
                                apps.append(meta)
                            except Exception:
                                continue
                self._json(200, {"apps": apps})
            elif self.path.startswith("/apps/"):
                # Static serving, jailed to the apps directory.
                raw = self.path.split("?")[0].removeprefix("/apps/")
                rel = raw.rstrip("/") or ""
                target = (APPS_DIR / rel).resolve()
                if target.is_dir():
                    target = target / "index.html"
                try:
                    target.relative_to(APPS_DIR.resolve())  # traversal jail
                except ValueError:
                    self._json(404, {"error": "no such app"})
                    return
                if not target.is_file():
                    self._json(404, {"error": "no such app file"})
                    return
                mime = MIME_BY_EXT.get(target.suffix.lower(), "application/octet-stream")
                self._send(200, target.read_bytes(), mime)
            elif self.path.startswith("/api/appdata/"):
                app_id = self.path.split("?")[0].removeprefix("/api/appdata/").strip("/")
                store = (APPDATA_DIR / f"{app_id}.json").resolve()
                if not app_id or "/" in app_id or not str(store).startswith(str(APPDATA_DIR.resolve())):
                    self._json(400, {"error": "bad app id"})
                    return
                if store.exists():
                    self._send(200, store.read_bytes(), "application/json")
                else:
                    self._json(200, {})
            elif self.path.startswith("/wallpaper"):
                if WALLPAPER.exists():
                    mime = (WALLPAPER_MIME.read_text().strip()
                            if WALLPAPER_MIME.exists() else "image/jpeg")
                    self._send(200, WALLPAPER.read_bytes(), mime)
                else:
                    self._json(404, {"error": "no wallpaper set"})
            elif self.path == "/api/health":
                self._json(200, {"ok": True})
            else:
                self._json(404, {"error": "no such path"})

        def do_POST(self) -> None:  # noqa: N802
            import re as _re
            if self.path == "/api/login":
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    body = json.loads(self.rfile.read(length) or b"{}")
                    if shell_lock.verify(body.get("password", "")):
                        token = shell_lock.issue_token()
                        self.send_response(200)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Set-Cookie",
                            f"mos_session={token}; HttpOnly; SameSite=Strict; Path=/")
                        out = json.dumps({"ok": True}).encode()
                        self.send_header("Content-Length", str(len(out)))
                        self.end_headers(); self.wfile.write(out)
                    else:
                        self._json(401, {"error": "wrong password"})
                except Exception as exc:
                    self._json(500, {"error": str(exc)})
                return
            if self.path == "/api/logout":
                self.send_response(200)
                self.send_header("Set-Cookie",
                    "mos_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0")
                self.send_header("Content-Length", "0"); self.end_headers()
                return
            if self.path == "/api/setlock":
                if shell_lock.is_set() and not self._authed():
                    self._json(401, {"error": "locked"}); return
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    body = json.loads(self.rfile.read(length) or b"{}")
                    pw = body.get("password", "")
                    if pw == "":
                        shell_lock.clear_password()
                        self._json(200, {"ok": True, "locked": False})
                    else:
                        shell_lock.set_password(pw)
                        self._json(200, {"ok": True, "locked": True})
                except ValueError as exc:
                    self._json(400, {"error": str(exc)})
                except Exception as exc:
                    self._json(500, {"error": str(exc)})
                return
            if shell_lock.is_set() and not self._authed():
                self._json(401, {"error": "locked"}); return
            if self.path == "/api/upload":
                # Raw bytes + X-Filename header: no multipart parsing.
                # Files land in the inbox; chat only accepts attachment
                # paths from inside that inbox.
                try:
                    import re as _re2, time as _time
                    length = int(self.headers.get("Content-Length", "0"))
                    if length <= 0 or length > MAX_UPLOAD_BYTES:
                        self._json(400, {"error": "file must be under 200MB"})
                        return
                    name = _re2.sub(r"[^A-Za-z0-9._-]", "_",
                                    self.headers.get("X-Filename", "upload.bin"))[-80:]
                    INBOX_DIR.mkdir(parents=True, exist_ok=True)
                    dest = INBOX_DIR / f"{int(_time.time())}_{name}"
                    with open(dest, "wb") as fh:
                        remaining = length
                        while remaining > 0:
                            chunk = self.rfile.read(min(1 << 20, remaining))
                            if not chunk:
                                break
                            fh.write(chunk); remaining -= len(chunk)
                    self._json(200, {"path": str(dest), "name": name})
                except Exception as exc:
                    self._json(500, {"error": str(exc)})
                return
            if self.path == "/api/tts":
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    body = json.loads(self.rfile.read(length) or b"{}")
                    text = (body.get("text") or "").strip()[:2500]
                    if not text:
                        self._json(400, {"error": "no text"}); return
                    self._send(200, bridge.synthesize(text), "audio/wav")
                except RuntimeError as exc:
                    self._json(503, {"error": str(exc),
                        "hint": "install piper on the core, or bring the Pi online "
                                "with speech.synthesize"})
                except Exception as exc:
                    self._json(500, {"error": str(exc)})
                return
            if self.path == "/api/stt":
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if length <= 0 or length > 30 * 1024 * 1024:
                        self._json(400, {"error": "audio must be under 30MB"}); return
                    fmt = "webm" if "webm" in self.headers.get("Content-Type", "") else "ogg"
                    text = bridge.transcribe(self.rfile.read(length), fmt)
                    self._json(200, {"text": text})
                except ImportError:
                    self._json(503, {"error": "no ears anywhere in the household",
                        "hint": "install faster-whisper on the core, or bring the "
                                "Pi online with speech.transcribe"})
                except Exception as exc:
                    self._json(500, {"error": str(exc)})
                return
            m = _re.match(r"^/api/actions/(\d+)/(approve|decline)$", self.path)
            if m:
                action_id, verb = int(m.group(1)), m.group(2)
                try:
                    if verb == "approve":
                        future = asyncio.run_coroutine_threadsafe(
                            bridge.provider.approve_action(action_id), bridge.loop)
                        self._json(200, {"result": future.result(timeout=CHAT_TIMEOUT_S)})
                    else:
                        self._json(200, {"result": bridge.decline_action(action_id)})
                except Exception as exc:
                    self._json(500, {"error": str(exc)})
                return
            if self.path.startswith("/api/appdata/"):
                app_id = self.path.removeprefix("/api/appdata/").strip("/")
                if not app_id or "/" in app_id:
                    self._json(400, {"error": "bad app id"})
                    return
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if length > MAX_APPDATA_BYTES:
                        self._json(400, {"error": "app data over 5MB"})
                        return
                    body = self.rfile.read(length)
                    json.loads(body)  # must be valid JSON; apps store state, not blobs
                    APPDATA_DIR.mkdir(parents=True, exist_ok=True)
                    (APPDATA_DIR / f"{app_id}.json").write_bytes(body)
                    self._json(200, {"ok": True})
                except json.JSONDecodeError:
                    self._json(400, {"error": "app data must be JSON"})
                except Exception as exc:
                    self._json(500, {"error": str(exc)})
                return
            if self.path == "/api/wallpaper":
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if length <= 0 or length > MAX_WALLPAPER_BYTES:
                        self._json(400, {"error": "wallpaper must be under 15MB"})
                        return
                    mime = self.headers.get("Content-Type", "image/jpeg")
                    if not mime.startswith("image/"):
                        self._json(400, {"error": "wallpaper must be an image"})
                        return
                    WALLPAPER.parent.mkdir(parents=True, exist_ok=True)
                    WALLPAPER.write_bytes(self.rfile.read(length))
                    WALLPAPER_MIME.write_text(mime)
                    self._json(200, {"ok": True})
                except Exception as exc:
                    self._json(500, {"error": str(exc)})
                return
            if self.path == "/api/power":
                # Session & power from the OS's own face. shutdown/restart go
                # through the scoped-sudo systemctl the harden role grants;
                # logout/lock stay in userspace. loginctl is preferred (works
                # in the cage session), systemctl is the fallback.
                import json as _j, subprocess as _sp, shutil as _sh, os as _os
                length = int(self.headers.get("Content-Length", "0"))
                body = _j.loads(self.rfile.read(length) or b"{}")
                act = body.get("action")
                try:
                    if act == "shutdown":
                        _sp.Popen(["sudo", "-n", "systemctl", "poweroff"])
                    elif act == "restart":
                        _sp.Popen(["sudo", "-n", "systemctl", "reboot"])
                    elif act == "logout":
                        # end the graphical session
                        if _sh.which("loginctl"):
                            _sp.Popen(["loginctl", "terminate-user", _os.environ.get("USER","")])
                        else:
                            _sp.Popen(["pkill", "-KILL", "-u", _os.environ.get("USER","")])
                    else:
                        self._json(400, {"error": "unknown power action"}); return
                    self._json(200, {"ok": True})
                except Exception as exc:
                    self._json(500, {"error": str(exc),
                        "hint": "shutdown/restart need the sudo role: "
                                "./deploy/install-micronos.sh sudo"})
                return
            if self.path == "/api/assistant/open":
                # Open the assistant in a real terminal. The OS knows only
                # the configured module's home; it launches the standard
                # entrypoint there. A real GUI comes later, deliberately.
                if bridge.provider is None:
                    self._json(503, {"error": "no assistant installed",
                        "hint": "install one, e.g. Alfred, then open it"}); return
                import shutil as _sh, subprocess as _sp, os as _os
                home = _os.environ.get("MICRON_ASSISTANT_PATH") or str(Path.home() / "Alfred")
                runner = Path(home) / "run_core.py"
                term = next((t for t in ("gnome-terminal","konsole","xterm","x-terminal-emulator")
                             if _sh.which(t)), None)
                if not runner.exists():
                    self._json(500, {"error": "assistant entrypoint not found",
                        "hint": f"expected {runner}"}); return
                if not term:
                    self._json(500, {"error": "no terminal emulator found",
                        "hint": f"open a terminal and run: python3 {runner}"}); return
                try:
                    if term == "gnome-terminal":
                        _sp.Popen([term, "--", "python3", str(runner)])
                    else:
                        _sp.Popen([term, "-e", f"python3 {runner}"])
                    self._json(200, {"ok": True})
                except Exception as exc:
                    self._json(500, {"error": str(exc),
                        "hint": f"open a terminal and run: python3 {runner}"})
                return
            if self.path != "/api/chat":
                self._json(404, {"error": "no such path"})
                return
            if bridge.provider is None:
                self._json(503, {"error": "no assistant installed",
                    "hint": "install one; Alfred: github.com/Micron2005/Alfred"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                payload = json.loads(self.rfile.read(length) or b"{}")
                message = (payload.get("message") or "").strip()
                if not message:
                    self._json(400, {"error": "message is empty"})
                    return
                attachments = []
                for raw in (payload.get("attachments") or [])[:4]:
                    resolved = Path(str(raw)).resolve()
                    try:
                        resolved.relative_to(INBOX_DIR.resolve())
                        if resolved.is_file():
                            attachments.append(str(resolved))
                    except ValueError:
                        pass  # only inbox files may be attached
                reply = bridge.chat(message, payload.get("project_id"),
                                    attachments or None)
                self._json(200, {"reply": reply})
            except Exception as exc:
                log.exception("chat failed")
                self._json(500, {"error": str(exc)})

        def log_message(self, fmt: str, *args) -> None:
            log.debug("http: " + fmt, *args)

    return Handler


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="configs/desktop.toml")
    ap.add_argument("--port", type=int, default=8710)
    ap.add_argument("--host", default="127.0.0.1",
                    help="0.0.0.0 to reach the shell from other machines")
    ap.add_argument("--project", default=None, help="default project id for the shell")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(name)-16s %(levelname)-7s %(message)s"
    )

    if ASSISTANT:
        provider = _PROVIDER_FACTORY(asyncio.get_running_loop())
        await provider.start()
        bridge = Bridge(provider, asyncio.get_running_loop())
        bridge.default_project = args.project or getattr(provider, "default_project", None)
        log.info("assistant present: %s (%s)", getattr(provider, "name", "?"), _PROVIDER_MODULE)
    else:
        provider = None
        bridge = Bridge(None, asyncio.get_running_loop())
        log.info("no assistant installed; Micron OS running standalone")

    background = []   # providers own their background tasks now

    httpd = ThreadingHTTPServer((args.host, args.port), make_handler(bridge))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    log.info("Micron OS shell at http://%s:%d", args.host, args.port)

    try:
        await asyncio.Event().wait()  # run until systemd or Ctrl-C says stop
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    finally:
        httpd.shutdown()
        for task in background:
            task.cancel()
        if provider is not None:
            await provider.stop()


if __name__ == "__main__":
    asyncio.run(main())
