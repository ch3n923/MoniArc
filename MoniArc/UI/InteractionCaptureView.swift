import AppKit
import SwiftUI

struct InteractionCaptureView: NSViewRepresentable {
    var onClick: () -> Void
    var onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onClick = onClick
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onClick = onClick
        nsView.onRightClick = onRightClick
    }
}

final class CaptureView: NSView {
    var onClick: (() -> Void)?
    var onRightClick: ((CGPoint) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(NSEvent.mouseLocation)
    }
}
