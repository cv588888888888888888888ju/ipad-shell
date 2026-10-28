import SwiftUI

#if os(iOS)
import PencilKit
import Network
import UIKit

/// Bisect step 2: v0.1 canvas + delegate + the TCP bridge. No toolbar, no hub.

private struct HelloMsg: Encodable {
    let type = "hello"
    let w: Double
    let h: Double
    let v = 1
}

private struct StrokeMsg: Encodable {
    let type = "stroke"
    let index: Int
    let color: String
    let width: Double
    let pts: [[Double]]
}

final class CanvasBridge {
    static let shared = CanvasBridge()

    private let queue = DispatchQueue(label: "canvas.bridge")
    private let encoder = JSONEncoder()
    private var listener: NWListener?
    private var conns: [NWConnection] = []
    private var canvasSize = CGSize.zero

    func configure(size: CGSize) { canvasSize = size }

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
                    let msg = HelloMsg(w: Double(self.canvasSize.width), h: Double(self.canvasSize.height))
                    if let d = try? self.encoder.encode(msg),
                       let s = String(data: d, encoding: .utf8) {
                        c.send(content: (s + "\n").data(using: .utf8) ?? Data(),
                               completion: .contentProcessed { _ in })
                    }
                }
                l.start(queue: self.queue)
                self.listener = l
                NSLog("bridge listening on :8080")
            } catch {
                NSLog("bridge failed: \(error)")
            }
        }
    }

    func stroke(_ s: PKStroke, index: Int) {
        let msg = StrokeMsg(index: index,
                            color: Self.hex(s.ink.color),
                            width: Self.width(s),
                            pts: Self.points(s))
        queue.async { [weak self] in
            guard let self,
                  let d = try? self.encoder.encode(msg),
                  let line = String(data: d, encoding: .utf8) else { return }
            let payload = (line + "\n").data(using: .utf8) ?? Data()
            for c in self.conns {
                c.send(content: payload, completion: .contentProcessed { _ in })
            }
        }
    }

    private static func points(_ s: PKStroke) -> [[Double]] {
        var out: [[Double]] = []
        out.reserveCapacity(s.path.count)
        for i in 0..<s.path.count {
            let p = s.path[i]
            out.append([Double(p.location.x), Double(p.location.y),
                        Double(p.force), Double(p.size.width), Double(p.timeOffset)])
        }
        return out
    }

    private static func width(_ s: PKStroke) -> Double {
        s.path.count > 0 ? Double(s.path[0].size.width) : 4.0
    }

    private static func hex(_ c: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

final class CanvasCoordinator: NSObject, PKCanvasViewDelegate {
    private var sent = 0

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        let strokes = canvasView.drawing.strokes
        guard strokes.count > sent else { return }
        for i in sent..<strokes.count {
            CanvasBridge.shared.stroke(strokes[i], index: i)
        }
        sent = strokes.count
    }
}

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

    func updateUIView(_ canvas: PKCanvasView, context: Context) {}
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
