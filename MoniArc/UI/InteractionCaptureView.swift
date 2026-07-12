import AppKit
import SwiftUI

struct InteractionCaptureView: NSViewRepresentable {
    var onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onRightClick = onRightClick
    }
}

final class CaptureView: NSView {
    var onRightClick: ((CGPoint) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(NSEvent.mouseLocation)
    }
}
