import SwiftUI

#if os(iOS)
import PencilKit

/// Full-screen PencilKit canvas: the minimum "does drawing work at all" shell.
struct PencilCanvas: UIViewRepresentable {
    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        canvas.backgroundColor = .white
        canvas.isOpaque = true
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
