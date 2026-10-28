#!/usr/bin/env python3
"""Live view for the iPad PencilKit canvas over USB.

Bridges the iPad app's TCP port (default 8080, reachable through usbmuxd)
to a browser page served on localhost (default 8090) via SSE.

No third-party dependencies: usbmuxd speaks a simple length-prefixed plist
protocol and the page uses EventSource.
"""

from __future__ import annotations

import argparse
import plistlib
import socket
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from queue import Empty, Queue

USBMUXD_SOCKET = "/var/run/usbmuxd"
CLIENT_NAME = "ipad-canvas-view"

clients: set[Queue[str]] = set()
clients_lock = threading.Lock()


def log(*args: object) -> None:
    print(*args, file=sys.stderr, flush=True)


# --------------------------------------------------------------------------
# usbmuxd protocol (length-prefixed plist)
# --------------------------------------------------------------------------


def mux_send(sock: socket.socket, payload: dict, tag: int) -> None:
    body = plistlib.dumps(payload, fmt=plistlib.FMT_XML)
    sock.sendall(struct.pack("<IIII", 16 + len(body), 1, 8, tag) + body)


def mux_recv(sock: socket.socket) -> dict:
    header = b""
    while len(header) < 16:
        chunk = sock.recv(16 - len(header))
        if not chunk:
            raise ConnectionError("usbmuxd closed the connection")
        header += chunk
    length, _version, _mtype, _tag = struct.unpack("<IIII", header)
    body = b""
    while len(body) < length - 16:
        chunk = sock.recv(length - 16 - len(body))
        if not chunk:
            raise ConnectionError("usbmuxd closed mid-message")
        body += chunk
    return plistlib.loads(body)


def mux_list_devices() -> list[dict]:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(10)
        sock.connect(USBMUXD_SOCKET)
        mux_send(
            sock,
            {
                "MessageType": "ListDevices",
                "ClientVersionString": CLIENT_NAME,
                "ProgName": CLIENT_NAME,
            },
            1,
        )
        reply = mux_recv(sock)
    return list(reply.get("DeviceList", []))


def mux_connect(device_id: int, port: int) -> socket.socket:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(10)
    sock.connect(USBMUXD_SOCKET)
    mux_send(
        sock,
        {
            "MessageType": "Connect",
            "ClientVersionString": CLIENT_NAME,
            "ProgName": CLIENT_NAME,
            "DeviceID": device_id,
            "PortNumber": socket.htons(port),
        },
        2,
    )
    reply = mux_recv(sock)
    if reply.get("MessageType") != "Result" or reply.get("Number") != 0:
        sock.close()
        raise ConnectionError(f"connect refused: {reply}")
    sock.settimeout(None)
    return sock


# --------------------------------------------------------------------------
# Fan-out to browsers
# --------------------------------------------------------------------------


def broadcast(line: str) -> None:
    with clients_lock:
        dead = []
        for queue in clients:
            try:
                queue.put_nowait(line)
            except Exception:
                dead.append(queue)
        for queue in dead:
            clients.discard(queue)


def pump_device(sock: socket.socket) -> None:
    log("device connected; streaming")
    buffer = b""
    while True:
        try:
            chunk = sock.recv(65536)
        except OSError as exc:
            log("device read error:", exc)
            break
        if not chunk:
            log("device closed the stream")
            break
        buffer += chunk
        while b"\n" in buffer:
            raw, buffer = buffer.split(b"\n", 1)
            raw = raw.strip()
            if raw:
                broadcast(raw.decode("utf-8", "replace"))


# --------------------------------------------------------------------------
# Web page
# --------------------------------------------------------------------------

PAGE = """<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>iPad canvas</title>
<style>
  html,body{margin:0;height:100%;background:#f2f2f2;overflow:hidden}
  #stage{position:absolute;inset:0;display:flex;align-items:center;justify-content:center}
  canvas{background:#fff;box-shadow:0 2px 14px rgba(0,0,0,.12);touch-action:none}
  #hud{position:fixed;left:8px;bottom:8px;font:12px/1.4 ui-monospace,monospace;color:#888}
</style>
</head>
<body>
<div id="stage"><canvas id="c"></canvas></div>
<div id="hud">waiting…</div>
<script>
const cv = document.getElementById('c');
const ctx = cv.getContext('2d');
const hud = document.getElementById('hud');
let strokes = [];
let W = 1024, H = 1366;
let dirty = true;

function fit() {
  const pad = 0;
  const availW = innerWidth - pad * 2;
  const availH = innerHeight - pad * 2;
  const scale = Math.min(availW / W, availH / H);
  cv.width = Math.round(W * scale);
  cv.height = Math.round(H * scale);
  cv.style.width = cv.width + 'px';
  cv.style.height = cv.height + 'px';
  dirty = true;
}

function drawStroke(s, k) {
  if (!s || !s.pts || !s.pts.length) return;
  const pts = s.pts;
  ctx.strokeStyle = s.color || '#000';
  ctx.lineWidth = Math.max(1, (s.width || 4) * k);
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  if (pts.length === 1) {
    ctx.fillStyle = s.color || '#000';
    ctx.beginPath();
    ctx.arc(pts[0][0] * k, pts[0][1] * k, Math.max(0.8, (s.width || 4) * k / 2), 0, Math.PI * 2);
    ctx.fill();
    return;
  }
  ctx.beginPath();
  ctx.moveTo(pts[0][0] * k, pts[0][1] * k);
  for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0] * k, pts[i][1] * k);
  ctx.stroke();
}

function render() {
  if (!dirty) return;
  dirty = false;
  const k = cv.width / W;
  ctx.fillStyle = '#fff';
  ctx.fillRect(0, 0, cv.width, cv.height);
  for (const s of strokes) drawStroke(s, k);
}

function loop() { render(); requestAnimationFrame(loop); }

const es = new EventSource('/events');
es.onopen = () => { hud.textContent = 'connected'; };
es.onerror = () => { hud.textContent = 'reconnecting…'; };
es.onmessage = (e) => {
  let m;
  try { m = JSON.parse(e.data); } catch { return; }
  if (m.type === 'hello') {
    W = m.w || W; H = m.h || H;
    hud.textContent = `canvas ${W}×${H}`;
    fit();
  } else if (m.type === 'reset') {
    strokes = []; dirty = true;
  } else if (m.type === 'stroke' || m.type === 'update') {
    if (typeof m.index === 'number' && m.index >= 0) strokes[m.index] = m;
    else strokes.push(m);
    dirty = true;
  }
};

fit();
addEventListener('resize', fit);
loop();
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: object) -> None:  # quieter
        pass

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/":
            body = PAGE.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path != "/events":
            self.send_error(404)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        queue: Queue[str] = Queue()
        with clients_lock:
            clients.add(queue)
        try:
            self.wfile.write(b": connected\n\n")
            self.wfile.flush()
            while True:
                try:
                    line = queue.get(timeout=10)
                except Empty:
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
                    continue
                self.wfile.write(b"data: " + line.encode("utf-8") + b"\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            with clients_lock:
                clients.discard(queue)


def wait_for_device(device_id: int | None, port: int) -> tuple[int, socket.socket]:
    while True:
        try:
            devices = mux_list_devices()
        except Exception as exc:
            log("cannot talk to usbmuxd:", exc)
            time.sleep(2)
            continue
        if not devices:
            log("no device attached, waiting…")
            time.sleep(2)
            continue
        chosen = None
        for d in devices:
            if device_id is None or d.get("DeviceID") == device_id:
                chosen = d
                break
        if chosen is None:
            log(f"device {device_id} not found, waiting…")
            time.sleep(2)
            continue
        dev_id = int(chosen["DeviceID"])
        try:
            sock = mux_connect(dev_id, port)
        except Exception as exc:
            log(f"port {port} not open yet ({exc}), retrying in 2s")
            time.sleep(2)
            continue
        return dev_id, sock


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device-port", type=int, default=8080)
    parser.add_argument("--web-port", type=int, default=8090)
    parser.add_argument("--device-id", type=int, default=None)
    args = parser.parse_args()

    web = ThreadingHTTPServer(("127.0.0.1", args.web_port), Handler)
    threading.Thread(target=web.serve_forever, daemon=True).start()
    log(f"open http://127.0.0.1:{args.web_port}/ in a browser")

    dev_id, sock = wait_for_device(args.device_id, args.device_port)
    log(f"attached to device {dev_id} port {args.device_port}")
    try:
        pump_device(sock)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
