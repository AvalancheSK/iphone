"""Testy servera náhľadu proti falošnému WebDriverAgentu.

Spustenie:  python3 -m unittest discover -s tests
"""

import http.client
import json
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "viewer"))
import server  # noqa: E402


class FakeWda:
    """Minimálny WebDriverAgent: 390×844 bodov, zaznamenáva požiadavky."""

    def __init__(self):
        self.requests = []
        self.sessions = 0
        self.valid_sid = None
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _reply(self, code, payload):
                body = json.dumps(payload).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _handle(self, method):
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length)) if length else None
                fake.requests.append((method, self.path, body))
                if self.path == "/status":
                    return self._reply(200, {"value": {"ready": True}})
                if method == "POST" and self.path == "/session":
                    fake.sessions += 1
                    fake.valid_sid = f"sid{fake.sessions}"
                    return self._reply(200, {"sessionId": fake.valid_sid, "value": {"sessionId": fake.valid_sid}})
                if self.path.startswith("/session/"):
                    sid = self.path.split("/")[2]
                    if sid != fake.valid_sid:
                        return self._reply(404, {"value": {"error": "invalid session id"}})
                    if self.path.endswith("/window/size"):
                        return self._reply(200, {"value": {"width": 390, "height": 844}})
                return self._reply(200, {"value": None})

            def do_GET(self):
                self._handle("GET")

            def do_POST(self):
                self._handle("POST")

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.httpd.server_port}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def calls(self, path_suffix):
        return [r for r in self.requests if r[1].endswith(path_suffix)]


class ViewerTest(unittest.TestCase):
    def setUp(self):
        self.wda = FakeWda()
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), BaseHTTPRequestHandler)
        self.port = self.httpd.server_port
        self.httpd.RequestHandlerClass = server.make_handler(
            server.Wda(self.wda.url), "http://127.0.0.1:9100", self.port
        )
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.wda.httpd.shutdown()
        self.wda.httpd.server_close()

    def request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        hdrs = {"Content-Type": "application/json"}
        hdrs.update(headers or {})
        conn.request(method, path, None if body is None else json.dumps(body), hdrs)
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        return resp.status, data

    def test_tap_maps_relative_coordinates_to_points(self):
        status, _ = self.request("POST", "/api/tap", {"x": 0.5, "y": 0.25})
        self.assertEqual(status, 200)
        (_, _, body), = self.wda.calls("/actions")
        steps = body["actions"][0]["actions"]
        self.assertEqual((steps[0]["x"], steps[0]["y"]), (195, 211))
        self.assertEqual(steps[1]["type"], "pointerDown")
        self.assertEqual(steps[3]["type"], "pointerUp")

    def test_session_is_reused_and_recreated_when_gone(self):
        self.request("POST", "/api/tap", {"x": 0.1, "y": 0.1})
        self.request("POST", "/api/tap", {"x": 0.2, "y": 0.2})
        self.assertEqual(self.wda.sessions, 1)
        self.wda.valid_sid = "taken-over-by-mobile-mcp"
        status, _ = self.request("POST", "/api/tap", {"x": 0.3, "y": 0.3})
        self.assertEqual(status, 200)
        self.assertEqual(self.wda.sessions, 2)

    def test_swipe_uses_duration(self):
        status, _ = self.request("POST", "/api/swipe", {"x1": 0.5, "y1": 0.8, "x2": 0.5, "y2": 0.2, "durationMs": 5000})
        self.assertEqual(status, 200)
        (_, _, body), = self.wda.calls("/actions")
        move = body["actions"][0]["actions"][2]
        self.assertEqual(move["duration"], 2000)
        self.assertEqual((move["x"], move["y"]), (195, 169))

    def test_buttons_and_typing(self):
        self.assertEqual(self.request("POST", "/api/button", {"name": "home"})[0], 200)
        self.assertEqual(len(self.wda.calls("/wda/homescreen")), 1)
        self.assertEqual(self.request("POST", "/api/button", {"name": "volumeUp"})[0], 200)
        self.assertEqual(self.wda.calls("/wda/pressButton")[0][2], {"name": "volumeUp"})
        self.assertEqual(self.request("POST", "/api/type", {"text": "Ahoj"})[0], 200)
        self.assertEqual(self.wda.calls("/wda/keys")[0][2], {"value": ["Ahoj"]})

    def test_rejects_invalid_input(self):
        self.assertEqual(self.request("POST", "/api/tap", {"x": 2, "y": 0.5})[0], 400)
        self.assertEqual(self.request("POST", "/api/tap", {"x": True, "y": 0.5})[0], 400)
        self.assertEqual(self.request("POST", "/api/button", {"name": "power"})[0], 400)
        self.assertEqual(self.request("POST", "/api/type", {"text": ""})[0], 400)
        self.assertEqual(self.wda.calls("/actions"), [])

    def test_blocks_requests_from_other_sites(self):
        self.assertEqual(self.request("POST", "/api/tap", {"x": 0.5, "y": 0.5}, {"Origin": "https://evil.example"})[0], 403)
        self.assertEqual(self.request("POST", "/api/tap", {"x": 0.5, "y": 0.5}, {"Host": "evil.example"})[0], 403)
        self.assertEqual(self.request("POST", "/api/tap", {"x": 0.5, "y": 0.5}, {"Content-Type": "text/plain"})[0], 415)
        self.assertEqual(self.wda.calls("/actions"), [])

    def test_same_origin_request_is_allowed(self):
        origin = f"http://127.0.0.1:{self.port}"
        self.assertEqual(self.request("POST", "/api/tap", {"x": 0.5, "y": 0.5}, {"Origin": origin})[0], 200)

    def test_index_config_and_status(self):
        status, body = self.request("GET", "/")
        self.assertEqual(status, 200)
        self.assertIn(b"<img id=\"screen\"", body)
        self.assertEqual(json.loads(self.request("GET", "/api/config")[1]), {"mjpegUrl": "http://127.0.0.1:9100"})
        self.assertEqual(json.loads(self.request("GET", "/api/status")[1]), {"ok": True})

    def test_reports_unreachable_wda(self):
        self.wda.httpd.shutdown()
        self.wda.httpd.server_close()
        self.assertFalse(json.loads(self.request("GET", "/api/status")[1])["ok"])
        status, body = self.request("POST", "/api/tap", {"x": 0.5, "y": 0.5})
        self.assertEqual(status, 502)
        self.assertIn("nie je dostupný", json.loads(body)["error"])


if __name__ == "__main__":
    unittest.main()
