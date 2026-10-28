import SwiftUI

#if os(iOS)
import PencilKit
import UIKit
import Network

// MARK: - Wire protocol: newline-delimited JSON, one object per line.

private struct HelloMsg: Encodable {
    let type = "hello"
    let w: Double
    let h: Double
    let v = 1
}

private struct StrokeMsg: Encodable {
    let type: String
    let index: Int
    let color: String
    let width: Double
    /// [x, y, force, size, timeOffset] per sample.
    let pts: [[Double]]
}

private struct ResetMsg: Encodable {
    let type = "reset"
}

// MARK: - TCP bridge to the host, reachable through usbmuxd port forwarding.

final class CanvasBridge {
    static let shared = CanvasBridge()

    private let queue = DispatchQueue(label: "canvas.bridge")
    private let encoder = JSONEncoder()
    private var listener: NWListener?
    private var conns: [NWConnection] = []
    private var canvasSize = CGSize.zero

    func configure(size: CGSize) {
        canvasSize = size
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            guard let port = NWEndpoint.Port(rawValue: 8080) else { return }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            do {
                let l = try NWListener(using: params, on: port)
                l.newConnectionHandler = { [weak self] c in
                    guard let self else { return }
                    c.start(queue: self.queue)
                    self.conns.append(c)
                    self.sendHello(to: c)
                }
                l.start(queue: self.queue)
                self.listener = l
                NSLog("canvas bridge listening on :8080")
            } catch {
                NSLog("canvas bridge failed: \(error)")
            }
        }
    }

    func stroke(_ s: PKStroke, index: Int, update: Bool) {
        let msg = StrokeMsg(
            type: update ? "update" : "stroke",
            index: index,
            color: Self.hex(s.ink.color),
            width: Self.width(s),
            pts: Self.points(s)
        )
        emit(msg)
    }

    func reset() {
        emit(ResetMsg())
    }

    private func emit<T: Encodable>(_ msg: T) {
        guard let d = try? encoder.encode(msg),
              let line = String(data: d, encoding: .utf8) else { return }
        send(line)
    }

    private func sendHello(to c: NWConnection) {
        let msg = HelloMsg(w: Double(canvasSize.width), h: Double(canvasSize.height))
        guard let d = try? encoder.encode(msg),
              let line = String(data: d, encoding: .utf8) else { return }
        send(line, to: c)
    }

    private func send(_ line: String, to one: NWConnection? = nil) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let one {
            one.send(content: data, completion: .contentProcessed { _ in })
        } else {
            for c in conns {
                c.send(content: data, completion: .contentProcessed { _ in })
            }
        }
    }

    private static func points(_ s: PKStroke) -> [[Double]] {
        var out: [[Double]] = []
        out.reserveCapacity(s.path.count)
        for i in 0..<s.path.count {
            let p = s.path[i]
            out.append([
                Double(p.location.x), Double(p.location.y),
                Double(p.force), Double(p.size), Double(p.timeOffset),
            ])
        }
        return out
    }

    private static func width(_ s: PKStroke) -> Double {
        s.path.count > 0 ? Double(s.path[0].size) : 4.0
    }

    private static func hex(_ c: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: - Canvas delegate: turns drawing changes into wire messages.

final class CanvasCoordinator: NSObject, PKCanvasViewDelegate {
    private var sentCount = 0
    private var lastPointCount = -1
    private var lastSend = Date.distantPast

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        let strokes = canvasView.drawing.strokes
        let now = Date()
        defer {
            sentCount = strokes.count
            lastPointCount = strokes.last?.path.count ?? -1
        }

        // Erase / undo shrank the drawing: the host must rebuild from scratch.
        if strokes.count < sentCount {
            CanvasBridge.shared.reset()
            for (i, s) in strokes.enumerated() {
                CanvasBridge.shared.stroke(s, index: i, update: false)
            }
            return
        }

        // New strokes were committed.
        if strokes.count > sentCount {
            for i in sentCount..<strokes.count {
                CanvasBridge.shared.stroke(strokes[i], index: i, update: false)
            }
            return
        }

        // The stroke in progress grew: resend it, throttled to 20 fps.
        guard let last = strokes.last else { return }
        if last.path.count != lastPointCount,
           now.timeIntervalSince(lastSend) > 0.05 {
            CanvasBridge.shared.stroke(last, index: strokes.count - 1, update: true)
            lastSend = now
        }
    }
}

// MARK: - Views

struct PencilCanvas: UIViewRepresentable {
    func makeCoordinator() -> CanvasCoordinator { CanvasCoordinator() }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        canvas.delegate = context.coordinator
        DispatchQueue.main.async {
            CanvasBridge.shared.configure(size: canvas.bounds.size)
            CanvasBridge.shared.start()
        }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        CanvasBridge.shared.configure(size: canvas.bounds.size)
    }
}
#endif

struct ContentView: View {
    var body: some View {
        #if os(iOS)
        PencilCanvas()
            .ignoresSafeArea()
        #else
        Text("iOS only")
        #endif
    }
}
