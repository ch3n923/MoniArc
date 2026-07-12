import AppKit

@MainActor
final class AppKitScreenProvider: ScreenProvider {
    private var continuation: AsyncStream<PanelLayoutSnapshot?>.Continuation?
    private var lastLayout: PanelLayoutSnapshot?
    private var hasPublished = false
    private var isAvailable = true
#if DEBUG
    private var harnessDisplayOverride: DisplaySnapshot?
#endif

    func layouts() async -> AsyncStream<PanelLayoutSnapshot?> {
        continuation?.finish()
        let pair = AsyncStream<PanelLayoutSnapshot?>.makeStream(bufferingPolicy: .bufferingNewest(4))
        continuation = pair.continuation
        if hasPublished {
            pair.continuation.yield(lastLayout)
        }
        return pair.stream
    }

    func refresh(for preference: PlacementPreference) async {
        guard isAvailable else {
            publish(nil)
            return
        }

        let display: DisplaySnapshot?
#if DEBUG
        if let harnessDisplayOverride {
            display = harnessDisplayOverride
        } else {
            display = Self.primaryScreen().map(DisplaySnapshot.current(from:))
        }
#else
        display = Self.primaryScreen().map(DisplaySnapshot.current(from:))
#endif
        guard let display else {
            publish(nil)
            return
        }

        let collapsed = PanelGeometry.resolve(display: display, preference: preference, expanded: false)
        let expanded = PanelGeometry.resolve(display: display, preference: preference, expanded: true)
        publish(PanelLayoutSnapshot(
            placement: collapsed.placement,
            collapsedFrame: PanelFrame(collapsed.frame),
            expandedFrame: PanelFrame(expanded.frame),
            notchFrame: collapsed.notchRect.map(PanelFrame.init)
        ))
    }

    func setAvailable(_ available: Bool, preference: PlacementPreference) async {
        isAvailable = available
        await refresh(for: preference)
    }

#if DEBUG
    func setHarnessDisplayOverride(_ snapshot: DisplaySnapshot?, preference: PlacementPreference) async {
        harnessDisplayOverride = snapshot
        await refresh(for: preference)
    }
#endif

    private func publish(_ layout: PanelLayoutSnapshot?) {
        lastLayout = layout
        hasPublished = true
        continuation?.yield(layout)
    }

    private static func primaryScreen() -> NSScreen? {
        NSScreen.screens.first(where: { abs($0.frame.origin.x) < 0.5 && abs($0.frame.origin.y) < 0.5 })
            ?? NSScreen.screens.first
    }
}

private extension PanelFrame {
    init(_ rect: CGRect) {
        self.init(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.width),
            height: Double(rect.height)
        )
    }
}

extension CGRect {
    init(_ frame: PanelFrame) {
        self.init(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }
}
