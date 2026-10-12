#!/usr/bin/env python3
"""Lokálny server pre živý náhľad a ovládanie iPhonu v prehliadači.

Servíruje viewer/index.html a preposiela ťuknutia, potiahnutia, tlačidlá a text
do WebDriverAgentu na iPhone (cez presmerovaný port 8100). Samotný obraz si
prehliadač berie priamo z MJPEG streamu WebDriverAgentu (port 9100).

Počúva iba na 127.0.0.1 a odmieta požiadavky z iných webových stránok.
Používa len štandardnú knižnicu Pythonu.
"""

import argparse
import json
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

INDEX_HTML = Path(__file__).with_name("index.html")
MAX_BODY = 64 * 1024
BUTTONS = {"home", "lock", "unlock", "volumeUp", "volumeDown"}


class WdaError(Exception):
    """WebDriverAgent je nedostupný alebo vrátil chybu."""


class SessionGone(WdaError):
    """WDA session zanikla (napr. ju nahradil mobile-mcp) – treba vytvoriť novú."""


class Wda:
    def __init__(self, base_url):
        self.base = base_url.rstrip("/")
        self._sid = None
        self._lock = threading.Lock()

    def _request(self, method, path, body=None, timeout=30):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(
            self.base + path,
            data=data,
            method=method,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                payload = resp.read()
        except urllib.error.HTTPError as e:
            text = e.read().decode(errors="replace")
            if e.code == 404 and "session" in text.lower():
                raise SessionGone(text) from e
            raise WdaError(f"WebDriverAgent vrátil HTTP {e.code}: {text[:300]}") from e
        except (urllib.error.URLError, OSError) as e:
            raise WdaError(f"WebDriverAgent nie je dostupný ({e}). Beží ./scripts/start.sh?") from e
        return json.loads(payload or b"{}")

    def status(self):
        return self._request("GET", "/status", timeout=3)

    def _new_session(self):
        resp = self._request("POST", "/session", {"capabilities": {"alwaysMatch": {"platformName": "iOS"}}})
        sid = resp.get("sessionId") or (resp.get("value") or {}).get("sessionId")
        if not sid:
            raise WdaError(f"WebDriverAgent nevytvoril session: {resp}")
        try:  # plynulejší a ostrejší obraz než predvolených 10 fps / kvalita 25
            self._request(
                "POST",
                f"/session/{sid}/appium/settings",
                {"settings": {"mjpegServerFramerate": 20, "mjpegServerScreenshotQuality": 50}},
            )
        except WdaError:
            pass
        return sid

    def _session_call(self, method, path, body=None):
        for _ in range(2):
            if self._sid is None:
                self._sid = self._new_session()
            try:
                return self._request(method, f"/session/{self._sid}{path}", body)
            except SessionGone:
                self._sid = None
        raise WdaError("WebDriverAgent session sa nedá obnoviť.")

    def _to_points(self, rx, ry):
        size = self._session_call("GET", "/window/size")["value"]
        return round(rx * size["width"]), round(ry * size["height"])

    def _gesture(self, steps):
        self._session_call(
            "POST",
            "/actions",
            {"actions": [{"type": "pointer", "id": "finger1", "parameters": {"pointerType": "touch"}, "actions": steps}]},
        )

    def tap(self, rx, ry, hold_ms=100):
        with self._lock:
            x, y = self._to_points(rx, ry)
            self._gesture([
                {"type": "pointerMove", "duration": 0, "x": x, "y": y},
                {"type": "pointerDown", "button": 0},
                {"type": "pause", "duration": hold_ms},
                {"type": "pointerUp", "button": 0},
            ])

    def swipe(self, rx1, ry1, rx2, ry2, duration_ms):
        with self._lock:
            x1, y1 = self._to_points(rx1, ry1)
            x2, y2 = self._to_points(rx2, ry2)
            self._gesture([
                {"type": "pointerMove", "duration": 0, "x": x1, "y": y1},
                {"type": "pointerDown", "button": 0},
                {"type": "pointerMove", "duration": duration_ms, "x": x2, "y": y2},
                {"type": "pointerUp", "button": 0},
            ])

    def button(self, name):
        with self._lock:
            if name == "home":
                self._request("POST", "/wda/homescreen")
            elif name in ("lock", "unlock"):
                self._request("POST", f"/wda/{name}")
            else:
                self._session_call("POST", "/wda/pressButton", {"name": name})

    def type_text(self, text):
        with self._lock:
            self._session_call("POST", "/wda/keys", {"value": [text]})


def _ratio(body, key):
    value = body.get(key)
    if not isinstance(value, (int, float)) or isinstance(value, bool) or not 0 <= value <= 1:
        raise ValueError(f"'{key}' musí byť číslo od 0 do 1")
    return float(value)


def make_handler(wda, mjpeg_url, port):
    allowed_hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}

    class Handler(BaseHTTPRequestHandler):
        server_version = "iphone-viewer"

        def log_message(self, fmt, *args):  # tichý log, chyby vypisujeme sami
            pass

        def _send(self, code, payload, content_type="application/json; charset=utf-8"):
            body = payload if isinstance(payload, bytes) else json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _trusted(self):
            # Ochrana pred DNS rebindingom a požiadavkami z cudzích stránok.
            if self.headers.get("Host") not in allowed_hosts:
                return False
            origin = self.headers.get("Origin")
            return origin is None or origin.removeprefix("http://") in allowed_hosts

        def do_GET(self):
            if not self._trusted():
                return self._send(403, {"error": "forbidden"})
            if self.path == "/":
                return self._send(200, INDEX_HTML.read_bytes(), "text/html; charset=utf-8")
            if self.path == "/api/config":
                return self._send(200, {"mjpegUrl": mjpeg_url})
            if self.path == "/api/status":
                try:
                    wda.status()
                    return self._send(200, {"ok": True})
                except WdaError as e:
                    return self._send(200, {"ok": False, "error": str(e)})
            return self._send(404, {"error": "not found"})

        def do_POST(self):
            if not self._trusted():
                return self._send(403, {"error": "forbidden"})
            if not (self.headers.get("Content-Type") or "").startswith("application/json"):
                return self._send(415, {"error": "očakávam application/json"})
            try:
                length = int(self.headers.get("Content-Length") or 0)
                if length > MAX_BODY:
                    raise ValueError("príliš veľká požiadavka")
                body = json.loads(self.rfile.read(length) or b"{}")
                if not isinstance(body, dict):
                    raise ValueError("telo musí byť JSON objekt")

                if self.path == "/api/tap":
                    wda.tap(_ratio(body, "x"), _ratio(body, "y"))
                elif self.path == "/api/longpress":
                    wda.tap(_ratio(body, "x"), _ratio(body, "y"), hold_ms=800)
                elif self.path == "/api/swipe":
                    duration = body.get("durationMs", 300)
                    if not isinstance(duration, (int, float)) or isinstance(duration, bool):
                        raise ValueError("'durationMs' musí byť číslo")
                    wda.swipe(
                        _ratio(body, "x1"), _ratio(body, "y1"),
                        _ratio(body, "x2"), _ratio(body, "y2"),
                        int(min(max(duration, 50), 2000)),
                    )
                elif self.path == "/api/button":
                    name = body.get("name")
                    if name not in BUTTONS:
                        raise ValueError(f"neznáme tlačidlo, povolené: {sorted(BUTTONS)}")
                    wda.button(name)
                elif self.path == "/api/type":
                    text = body.get("text")
                    if not isinstance(text, str) or not text:
                        raise ValueError("'text' musí byť neprázdny reťazec")
                    wda.type_text(text)
                else:
                    return self._send(404, {"error": "not found"})
            except ValueError as e:
                return self._send(400, {"error": str(e)})
            except WdaError as e:
                return self._send(502, {"error": str(e)})
            return self._send(200, {"ok": True})

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8200)
    parser.add_argument("--wda-url", default="http://127.0.0.1:8100")
    parser.add_argument("--mjpeg-url", default="http://127.0.0.1:9100")
    args = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(Wda(args.wda_url), args.mjpeg_url, args.port))
    print(f"Náhľad iPhonu beží na http://127.0.0.1:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
