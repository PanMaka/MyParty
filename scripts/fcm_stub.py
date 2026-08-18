#!/usr/bin/env python3
"""A stand-in for Google, so the delivery path can be tested without Firebase.

scripts/verify_notification_delivery.sh points the worker's GOOGLE_TOKEN_URL and
FCM_BASE_URL at this process. It serves the two endpoints FCM HTTP v1 delivery
actually touches, and it is deliberately NOT a mock of the worker's behaviour --
the worker still builds a real RS256 assertion with a real 2048-bit key, still
exchanges it, still sends a real HTTP request and still reads a real status code
back. What is faked is Google's answer, which is the one part a local stack
cannot supply.

The token prefixes below are how the script drives the branches that matter:

    dead-*      404 UNREGISTERED   -- must delete the device row
    flaky-*     503 twice, then OK -- must retry, not delete
    bogus-*     400 with a token-shaped error message
    anything    200

Only the last one happens with real tokens; the other three are the failure
paths, and they are the reason this file exists. Asserting that a notification
is delivered proves far less than asserting that a dead token is cleaned up and
a flaky one is not.

Usage:  python scripts/fcm_stub.py [PORT]
"""

import json
import sys
import threading
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8099

_lock = threading.Lock()
_sent = []                        # every accepted send, in order
_attempts = defaultdict(int)      # per-token call count, so flaky-* can recover
_tokens_issued = 0


class Handler(BaseHTTPRequestHandler):
    # Quiet: the worker's own structured logs are what the script reads, and one
    # line per request here would bury them.
    def log_message(self, fmt, *args):
        pass

    def _reply(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/_sent":
            with _lock:
                self._reply(200, {"sent": _sent, "tokens_issued": _tokens_issued})
            return
        if self.path == "/_health":
            self._reply(200, {"ok": True})
            return
        self._reply(404, {"error": "not found"})

    def do_POST(self):
        global _tokens_issued
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""

        # ---- OAuth2 token exchange -------------------------------------
        # The assertion's signature is not verified: this has no public key and
        # verifying it would only re-test WebCrypto. What matters is that the
        # worker got far enough to produce one, which a malformed key or a
        # broken PEM normalisation would have prevented.
        if self.path.startswith("/token"):
            with _lock:
                _tokens_issued += 1
            if b"assertion=" not in raw:
                self._reply(400, {"error": "invalid_request", "detail": "no assertion"})
                return
            self._reply(200, {"access_token": "stub-access-token",
                              "expires_in": 3600,
                              "token_type": "Bearer"})
            return

        # ---- messages:send ---------------------------------------------
        if self.path.endswith(":send"):
            if self.headers.get("Authorization") != "Bearer stub-access-token":
                self._reply(401, {"error": {"status": "UNAUTHENTICATED"}})
                return

            try:
                message = json.loads(raw)["message"]
            except Exception as exc:
                self._reply(400, {"error": {"status": "INVALID_ARGUMENT",
                                            "message": f"bad body: {exc}"}})
                return

            token = message.get("token", "")
            with _lock:
                _attempts[token] += 1
                seen = _attempts[token]

            if token.startswith("dead-"):
                self._reply(404, {"error": {"status": "NOT_FOUND",
                                            "message": "Requested entity was not found.",
                                            "details": [{"errorCode": "UNREGISTERED"}]}})
                return

            if token.startswith("bogus-"):
                self._reply(400, {"error": {"status": "INVALID_ARGUMENT",
                                            "message": "The registration token is not a valid FCM registration token"}})
                return

            if token.startswith("flaky-") and seen <= 2:
                self._reply(503, {"error": {"status": "UNAVAILABLE",
                                            "message": "The service is temporarily unavailable."}})
                return

            with _lock:
                _sent.append({"token": token,
                              "title": message.get("notification", {}).get("title"),
                              "body": message.get("notification", {}).get("body"),
                              "data": message.get("data", {})})
            self._reply(200, {"name": f"projects/stub/messages/{len(_sent)}"})
            return

        self._reply(404, {"error": "not found"})


if __name__ == "__main__":
    # 0.0.0.0, not localhost: the caller is the edge runtime inside Docker,
    # reaching the host through host.docker.internal.
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"fcm stub listening on {PORT}", flush=True)
    server.serve_forever()
