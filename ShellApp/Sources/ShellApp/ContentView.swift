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
        CanvasHub.shared.canvas = canvas
        DispatchQueue.main.async {
            CanvasBridge.shared.configure(size: canvas.bounds.size)
            CanvasBridge.shared.start()
        }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {}
}
#endif


// MARK: - Bisect step 4: full toolbar wired through a singleton hub

@MainActor
final class CanvasHub {
    static let shared = CanvasHub()
    weak var canvas: PKCanvasView?

    func apply(tool: CanvasModel.ToolKind, color: UIColor, width: Double) {
        guard let canvas else { return }
        switch tool {
        case .pen:
            canvas.tool = PKInkingTool(.pen, color: color, width: CGFloat(width))
        case .eraser:
            canvas.tool = PKEraserTool(.vector)
        case .lasso:
            canvas.tool = PKLassoTool()
        }
    }

    func undo() { canvas?.undoManager?.undo() }
    func redo() { canvas?.undoManager?.redo() }
}

@MainActor
final class CanvasModel: ObservableObject {
    enum ToolKind: String, CaseIterable { case pen, eraser, lasso }

    @Published var tool: ToolKind = .pen {
        didSet { CanvasHub.shared.apply(tool: tool, color: color, width: width) }
    }
    @Published var color: UIColor = .black {
        didSet { CanvasHub.shared.apply(tool: tool, color: color, width: width) }
    }
    @Published var width: Double = 4 {
        didSet { CanvasHub.shared.apply(tool: tool, color: color, width: width) }
    }

    func undo() { CanvasHub.shared.undo() }
    func redo() { CanvasHub.shared.redo() }
}

struct Toolbar: View {
    @ObservedObject var model: CanvasModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CanvasModel.ToolKind.allCases, id: \.self) { kind in
                Button {
                    model.tool = kind
                } label: {
                    Image(systemName: icon(for: kind))
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(model.tool == kind ? Color.accentColor.opacity(0.2) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .foregroundStyle(model.tool == kind ? Color.accentColor : Color.primary)
            }
            Divider().frame(height: 24)
            ColorPicker("", selection: Binding(
                get: { Color(model.color) },
                set: { model.color = UIColor($0) }
            )).labelsHidden()
            Divider().frame(height: 24)
            Slider(value: $model.width, in: 1...20).frame(width: 100)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private func icon(for kind: CanvasModel.ToolKind) -> String {
        switch kind {
        case .pen: return "pencil.tip"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        }
    }
}

struct ContentView: View {
    @StateObject private var model = CanvasModel()

    var body: some View {
        #if os(iOS)
        PencilCanvas()
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                Toolbar(model: model)
                    .padding(.top, 10)
            }
        #else
        Text("iOS only")
        #endif
    }
}
