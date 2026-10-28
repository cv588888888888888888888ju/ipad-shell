import SwiftUI

#if os(iOS)
import PencilKit

/// v0.1 canvas plus exactly one addition: a PencilKit delegate that only logs.
/// If this build goes blank, the delegate hook itself is what kills rendering.
final class CanvasCoordinator: NSObject, PKCanvasViewDelegate {
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        NSLog("drawing changed strokes=\(canvasView.drawing.strokes.count)")
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
