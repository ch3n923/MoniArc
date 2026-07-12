import AppKit

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
        animationBehavior = .utilityWindow
        collectionBehavior = [
            .canJoinAllSpaces,
            .transient,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        if #available(macOS 15.0, *) {
            collectionBehavior.insert(.canJoinAllApplications)
        }
    }
}
