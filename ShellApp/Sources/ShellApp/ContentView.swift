import SwiftUI

#if os(iOS)
import PencilKit
import UIKit
import Network
import PDFKit
import UniformTypeIdentifiers

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

private struct BackgroundMsg: Encodable {
    let type = "background"
    let mime: String
    let w: Double
    let h: Double
    let data: String
}

// MARK: - TCP bridge to the host, reachable through usbmuxd port forwarding.

final class CanvasBridge {
    static let shared = CanvasBridge()

    private let queue = DispatchQueue(label: "canvas.bridge")
    private let encoder = JSONEncoder()
    private var listener: NWListener?
    private var conns: [NWConnection] = []
    private var canvasSize = CGSize.zero
    private var lastBackground: BackgroundMsg?

    /// Commands arriving from the host (computer side), e.g. clear / undo.
    var onHostCommand: ((String) -> Void)?

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
                    if let bg = self.lastBackground {
                        self.sendEncoded(bg, to: c)
                    }
                    self.receive(on: c)
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

    /// Publishes a rendered page image so both screens share the same paper.
    func background(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        let msg = BackgroundMsg(
            mime: "image/jpeg",
            w: Double(image.size.width),
            h: Double(image.size.height),
            data: data.base64EncodedString()
        )
        queue.async { [weak self] in
            self?.lastBackground = msg
        }
        emit(msg)
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isDone, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                if let line = String(data: data, encoding: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let type = json["type"] as? String {
                    DispatchQueue.main.async { self.onHostCommand?(type) }
                }
            }
            if let error {
                NSLog("host read error: \(error)")
                return
            }
            if isDone { return }
            self.receive(on: conn)
        }
    }

    private func emit<T: Encodable>(_ msg: T) {
        queue.async { [weak self] in
            guard let self else { return }
            let data = try? self.encoder.encode(msg)
            guard let data, let line = String(data: data, encoding: .utf8) else { return }
            let payload = (line + "\n").data(using: .utf8) ?? Data()
            for c in self.conns {
                c.send(content: payload, completion: .contentProcessed { _ in })
            }
        }
    }

    private func sendEncoded<T: Encodable>(_ msg: T, to c: NWConnection) {
        let data = try? encoder.encode(msg)
        guard let data, let line = String(data: data, encoding: .utf8) else { return }
        c.send(content: (line + "\n").data(using: .utf8) ?? Data(), completion: .contentProcessed { _ in })
    }

    private func sendHello(to c: NWConnection) {
        let size = canvasSize
        let msg = HelloMsg(w: Double(size.width), h: Double(size.height))
        sendEncoded(msg, to: c)
    }

    private static func points(_ s: PKStroke) -> [[Double]] {
        var out: [[Double]] = []
        out.reserveCapacity(s.path.count)
        for i in 0..<s.path.count {
            let p = s.path[i]
            out.append([
                Double(p.location.x), Double(p.location.y),
                Double(p.force), Double(p.size.width), Double(p.timeOffset),
            ])
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

// MARK: - PDF / image page rasteriser

enum BackgroundRenderer {
    static func render(url: URL, canvasSize: CGSize) -> UIImage? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
            return render(page: page, into: canvasSize)
        }
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        return fit(image: img, into: canvasSize)
    }

    static func render(page: PDFPage, into size: CGSize) -> UIImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else { return nil }

        let scale = min(size.width / bounds.width, size.height / bounds.height)
        let drawSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let origin = CGPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            let cg = ctx.cgContext
            cg.saveGState()
            cg.translateBy(x: origin.x, y: origin.y + drawSize.height)
            cg.scaleBy(x: scale, y: -scale)
            cg.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
            page.draw(with: .mediaBox, to: cg)
            cg.restoreGState()
        }
    }

    static func fit(image: UIImage, into size: CGSize) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 2
        let renderer = UIGraphicsImageRenderer(size: size, format: fmt)
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}

// MARK: - Canvas model shared by the toolbar and the canvas

@MainActor
final class CanvasModel: ObservableObject {
    enum ToolKind: String, CaseIterable {
        case pen, eraser, lasso
    }

    @Published var tool: ToolKind = .pen { didSet { apply() } }
    @Published var color: UIColor = .black { didSet { apply() } }
    @Published var width: Double = 4 { didSet { apply() } }

    weak var canvas: PKCanvasView?

    func attach(_ c: PKCanvasView) {
        canvas = c
        apply()
    }

    func apply() {
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

    func clearDrawing() {
        canvas?.drawing = PKDrawing()
    }
}

// MARK: - Canvas delegate

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

        if strokes.count < sentCount {
            CanvasBridge.shared.reset()
            for (i, s) in strokes.enumerated() {
                CanvasBridge.shared.stroke(s, index: i, update: false)
            }
            return
        }

        if strokes.count > sentCount {
            for i in sentCount..<strokes.count {
                CanvasBridge.shared.stroke(strokes[i], index: i, update: false)
            }
            return
        }

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
    @ObservedObject var model: CanvasModel

    func makeCoordinator() -> CanvasCoordinator { CanvasCoordinator() }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.delegate = context.coordinator
        model.attach(canvas)
        DispatchQueue.main.async {
            CanvasBridge.shared.configure(size: canvas.bounds.size)
            CanvasBridge.shared.start()
            CanvasBridge.shared.onHostCommand = { [weak model] cmd in
                guard let model else { return }
                switch cmd {
                case "clear": model.clearDrawing()
                case "undo": model.undo()
                case "redo": model.redo()
                default: break
                }
            }
        }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        CanvasBridge.shared.configure(size: canvas.bounds.size)
    }
}

struct Toolbar: View {
    @ObservedObject var model: CanvasModel
    var onImport: () -> Void

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
            ))
            .labelsHidden()

            Divider().frame(height: 24)

            Slider(value: $model.width, in: 1...20).frame(width: 100)

            Divider().frame(height: 24)

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }

            Divider().frame(height: 24)

            Button { onImport() } label: { Image(systemName: "photo.on.rectangle") }
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
    @State private var background: UIImage?
    @State private var importing = false

    var body: some View {
        ZStack {
            Color.white
            if let bg = background {
                Image(uiImage: bg)
                    .resizable()
                    .ignoresSafeArea()
            }
            PencilCanvas(model: model)
                .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            Toolbar(model: model, onImport: { importing = true })
                .padding(.top, 10)
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.pdf, .image],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let size = UIScreen.main.bounds.size
            if let rendered = BackgroundRenderer.render(url: url, canvasSize: size) {
                background = rendered
                CanvasBridge.shared.background(rendered)
            }
        }
    }
}
#endif

struct RootView: View {
    var body: some View {
        #if os(iOS)
        ContentView()
        #else
        Text("iOS only")
        #endif
    }
}
