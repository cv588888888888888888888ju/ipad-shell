#!/usr/bin/env python3
"""iPad canvas -> Excalidraw, over USB.

Reuses the usbmuxd bridge from live_view.py but renders the incoming stroke
feed into an Excalidraw scene instead of a hand-rolled canvas.

iPad side is unchanged: NDJSON on TCP :8080 with hello / reset / stroke /
update messages (plus optional background images).
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from queue import Empty, Queue

sys.path.insert(0, __file__.rsplit("/", 1)[0])

import live_view  # noqa: E402  (usbmuxd helpers + fan-out)

PAGE = r"""<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>iPad → Excalidraw</title>
<style>
  html,body,#root{margin:0;width:100%;height:100%;overflow:hidden}
  #hud{position:fixed;right:12px;bottom:12px;z-index:9999;font:12px/1.4 ui-monospace,monospace;
       color:#666;background:rgba(255,255,255,.85);padding:4px 8px;border-radius:6px}
</style>
</head>
<body>
<div id="root"></div>
<div id="hud">loading excalidraw…</div>
<script src="https://unpkg.com/react@18.3.1/umd/react.production.min.js"></script>
<script src="https://unpkg.com/react-dom@18.3.1/umd/react-dom.production.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/@excalidraw/excalidraw@0.17.6/dist/excalidraw.production.min.js"></script>
<script>
(function () {
  var hud = document.getElementById('hud');
  if (!window.ExcalidrawLib || !window.React || !window.ReactDOM) {
    hud.textContent = 'failed to load excalidraw bundle';
    return;
  }
  var Excalidraw = window.ExcalidrawLib.Excalidraw;
  var React = window.React;

  var api = null;
  var W = 768, H = 1024;
  var strokes = new Map();
  var bgElement = null;
  var bgFile = null;
  var pending = false;

  function toElement(s, idx) {
    var pts = s.pts || [];
    if (!pts.length) return null;
    var ox = pts[0][0], oy = pts[0][1];
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    var points = pts.map(function (p) {
      var x = p[0] - ox, y = p[1] - oy;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      return [x, y];
    });
    return {
      id: 'ipad-stroke-' + idx,
      type: 'freedraw',
      x: ox, y: oy,
      width: Math.max(1, maxX - minX),
      height: Math.max(1, maxY - minY),
      angle: 0,
      strokeColor: s.color || '#000000',
      backgroundColor: 'transparent',
      fillStyle: 'solid',
      strokeWidth: Math.max(1, (s.width || 4) * 0.55),
      strokeStyle: 'solid',
      roughness: 0,
      opacity: 100,
      groupIds: [],
      frameId: null,
      roundness: null,
      seed: 1,
      version: 1,
      versionNonce: 1,
      isDeleted: false,
      boundElements: null,
      updated: Date.now(),
      link: null,
      locked: false,
      points: points,
      pressures: [],
      simulatePressure: false,
      lastCommittedPoint: null
    };
  }

  function schedule() {
    if (pending || !api) return;
    pending = true;
    requestAnimationFrame(function () {
      pending = false;
      var els = [];
      if (bgElement) els.push(bgElement);
      strokes.forEach(function (s, idx) {
        var e = toElement(s, idx);
        if (e) els.push(e);
      });
      try { api.updateScene({ elements: els }); } catch (e) { console.warn(e); }
    });
  }

  function setBackground(m) {
    var fileId = 'ipad-bg';
    bgFile = {
      id: fileId,
      mimeType: m.mime || 'image/jpeg',
      dataURL: 'data:' + (m.mime || 'image/jpeg') + ';base64,' + m.data,
      created: Date.now()
    };
    bgElement = {
      id: 'ipad-background',
      type: 'image',
      x: 0, y: 0,
      width: m.w || W, height: m.h || H,
      angle: 0,
      strokeColor: 'transparent',
      backgroundColor: 'transparent',
      fillStyle: 'solid',
      strokeWidth: 1,
      strokeStyle: 'solid',
      roughness: 0,
      opacity: 100,
      groupIds: [],
      frameId: null,
      roundness: null,
      seed: 2,
      version: 1,
      versionNonce: 2,
      isDeleted: false,
      boundElements: null,
      updated: Date.now(),
      link: null,
      locked: true,
      fileId: fileId,
      status: 'saved',
      scale: [1, 1]
    };
    if (api) {
      try {
        api.addFiles([bgFile]);
        api.updateScene({ elements: [bgElement] });
      } catch (e) { console.warn(e); }
    }
  }

  var sentFiles = Object.create(null);
  var expected = 0;
  var totalKnown = 0;

  function requestSync() {
    strokes.clear();
    expected = 0;
    fetch('/sync', { method: 'POST' }).catch(function () {});
  }

  function pushBackground(dataURL) {
    var img = new Image();
    img.onload = function () {
      var c = document.createElement('canvas');
      c.width = W; c.height = H;
      var g = c.getContext('2d');
      g.fillStyle = '#fff';
      g.fillRect(0, 0, W, H);
      var sc = Math.min(W / img.width, H / img.height);
      var dw = img.width * sc, dh = img.height * sc;
      g.drawImage(img, (W - dw) / 2, (H - dh) / 2, dw, dh);
      var out = c.toDataURL('image/jpeg', 0.85);
      var b64 = out.split(',')[1];
      hud.textContent = 'pushing page to ipad…';
      fetch('/background', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ type: 'background', mime: 'image/jpeg', w: W, h: H, data: b64 })
      }).then(function (r) {
        hud.textContent = r.ok ? 'page sent to ipad' : 'ipad not attached';
      }).catch(function () { hud.textContent = 'push failed'; });
    };
    img.src = dataURL;
  }

  function App() {
    return React.createElement(Excalidraw, {
      excalidrawAPI: function (a) {
        api = a;
        hud.textContent = 'excalidraw ready';
        if (bgElement) api.addFiles([bgFile]);
        schedule();
      },
      onChange: function (elements, appState, files) {
        if (!files) return;
        for (var i = 0; i < elements.length; i++) {
          var el = elements[i];
          if (el.type !== 'image' || !el.fileId || el.isDeleted) continue;
          var f = files[el.fileId];
          if (!f || !f.dataURL || sentFiles[el.fileId]) continue;
          sentFiles[el.fileId] = true;
          pushBackground(f.dataURL);
        }
      },
      initialData: { appState: { viewBackgroundColor: '#ffffff' } }
    });
  }

  ReactDOM.createRoot(document.getElementById('root')).render(React.createElement(App));

  var es = new EventSource('/events');
  es.onopen = function () { hud.textContent = 'connected'; };
  es.onerror = function () { hud.textContent = 'reconnecting…'; };
  setInterval(function () {
    if (api && strokes.size !== totalKnown) requestSync();
  }, 3000);

  es.onmessage = function (e) {
    var m;
    try { m = JSON.parse(e.data); } catch (err) { return; }
    if (m.type === 'hello') {
      W = m.w || W; H = m.h || H;
      hud.textContent = 'canvas ' + W + '×' + H;
      requestSync();
    } else if (m.type === 'reset') {
      strokes.clear();
      expected = 0;
    } else if (m.type === 'stroke') {
      if (typeof m.index === 'number') {
        if (m.index !== expected) { requestSync(); return; }
        strokes.set(m.index, m);
        expected = m.index + 1;
        if (typeof m.total === 'number') totalKnown = m.total;
      }
    } else if (m.type === 'update') {
      if (typeof m.index === 'number') strokes.set(m.index, m);
    } else if (m.type === 'background') {
      setBackground(m);
    }
    schedule();
  };
})();
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: object) -> None:
        pass

    def do_POST(self) -> None:  # noqa: N802
        if self.path == "/sync":
            ok = live_view.send_to_device({"type": "sync"})
            self.send_response(200 if ok else 503)
            body = b'{"ok":true}' if ok else b'{"ok":false}'
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path != "/background":
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(400)
            return
        raw = self.rfile.read(length)
        try:
            msg = json.loads(raw)
        except Exception:
            self.send_error(400)
            return
        if msg.get("type") != "background" or not isinstance(msg.get("data"), str):
            self.send_error(400)
            return
        ok = live_view.send_to_device(msg)
        self.send_response(200 if ok else 503)
        self.send_header("Content-Type", "application/json")
        body = b'{"ok":true}' if ok else b'{"ok":false}'
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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
        with live_view.clients_lock:
            live_view.clients.add(queue)
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
            with live_view.clients_lock:
                live_view.clients.discard(queue)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device-port", type=int, default=8080)
    parser.add_argument("--web-port", type=int, default=8091)
    parser.add_argument("--device-id", type=int, default=None)
    args = parser.parse_args()

    web = ThreadingHTTPServer(("127.0.0.1", args.web_port), Handler)
    threading.Thread(target=web.serve_forever, daemon=True).start()
    print(f"open http://127.0.0.1:{args.web_port}/ in a browser", file=sys.stderr, flush=True)

    while True:
        dev_id, sock = live_view.wait_for_device(args.device_id, args.device_port)
        print(f"attached to device {dev_id} port {args.device_port}", file=sys.stderr, flush=True)
        try:
            live_view.pump_device(sock)
        except KeyboardInterrupt:
            return 0
        finally:
            try:
                sock.close()
            except OSError:
                pass
        print("device dropped; waiting for it to come back", file=sys.stderr, flush=True)
        time.sleep(1)


if __name__ == "__main__":
    sys.exit(main())
