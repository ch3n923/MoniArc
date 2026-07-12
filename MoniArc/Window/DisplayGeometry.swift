import AppKit

struct DisplaySnapshot: Equatable, Sendable {
    var identifier: String
    var frame: CGRect
    var visibleFrame: CGRect
    var safeAreaTop: CGFloat
    var statusBarThickness: CGFloat
    var auxiliaryTopLeftArea: CGRect?
    var auxiliaryTopRightArea: CGRect?
    var backingScaleFactor: CGFloat

    var topChromeHeight: CGFloat {
        max(safeAreaTop, frame.maxY - visibleFrame.maxY, statusBarThickness)
    }

    var notchRect: CGRect? {
        guard safeAreaTop > 0,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea,
              !left.isEmpty,
              !right.isEmpty else {
            return nil
        }

        let minX = left.maxX
        let maxX = right.minX
        guard maxX > minX else { return nil }
        return CGRect(x: minX, y: frame.maxY - safeAreaTop, width: maxX - minX, height: safeAreaTop)
    }

    var hasNotchSignal: Bool {
        safeAreaTop > 0
    }

    static func current(from screen: NSScreen) -> DisplaySnapshot {
        let identifier = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map(String.init(describing:)) ?? "unknown"
        return DisplaySnapshot(
            identifier: identifier,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            statusBarThickness: NSStatusBar.system.thickness,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
            backingScaleFactor: screen.backingScaleFactor
        )
    }
}

struct PanelGeometry: Equatable, Sendable {
    static let islandWidth: CGFloat = 304
    /// Transparent rendering safety margin for the 5.5pt halo. This must stay
    /// in sync with IslandDesign.glowOutset.
    static let glowOutset: CGFloat = 28
    static let panelWidth: CGFloat = islandWidth + glowOutset * 2
    static let collapsedHeight: CGFloat = 32
    /// The extra transparent strip lets the status outline pass below the
    /// physical notch instead of being completely covered by it.
    static let overlayCollapsedWindowHeight: CGFloat = 34
    static let overlayExpandedHeight: CGFloat = 140
    static let floatingExpandedHeight: CGFloat = 108
    static let floatingGap: CGFloat = 8
    static let minimumWingWidth: CGFloat = 43

    var placement: PanelPlacement
    var frame: CGRect
    var notchRect: CGRect?
    var physicalNotchWidth: CGFloat?
    var usesWingLayout: Bool
    var fellBackForSafety: Bool

    static func resolve(
        display: DisplaySnapshot,
        preference: PlacementPreference,
        expanded: Bool
    ) -> PanelGeometry {
        let notch = display.notchRect
        let safeNotch = notch.flatMap { notch -> CGRect? in
            let wingWidth = (islandWidth - notch.width) / 2
            guard display.safeAreaTop <= collapsedHeight,
                  wingWidth >= minimumWingWidth else { return nil }
            return notch
        }

        let placement: PanelPlacement
        let fellBack: Bool
        switch preference {
        case .automatic:
            placement = safeNotch == nil ? .floating : .overlay
            fellBack = display.hasNotchSignal && safeNotch == nil
        case .floating:
            placement = .floating
            fellBack = false
        case .overlay:
            if display.hasNotchSignal {
                placement = safeNotch == nil ? .floating : .overlay
                fellBack = safeNotch == nil
            } else {
                // Manual overlay remains useful on a flat/external display.
                placement = .overlay
                fellBack = false
            }
        }

        let visualHeight: CGFloat
        let top: CGFloat
        switch placement {
        case .overlay:
            visualHeight = expanded
                ? overlayExpandedHeight
                : (safeNotch == nil ? collapsedHeight : overlayCollapsedWindowHeight)
            top = display.frame.maxY
        case .floating:
            visualHeight = expanded ? floatingExpandedHeight : collapsedHeight
            top = display.frame.maxY - display.topChromeHeight - floatingGap
        }
        let height = visualHeight + (placement == .floating ? glowOutset * 2 : glowOutset)

        let centerX = safeNotch?.midX ?? display.frame.midX
        let scale = max(display.backingScaleFactor, 1)
        let rawX = centerX - panelWidth / 2
        let rawY = top - height
        let frame = CGRect(
            x: (rawX * scale).rounded() / scale,
            y: (rawY * scale).rounded() / scale,
            width: panelWidth,
            height: height
        )

        return PanelGeometry(
            placement: placement,
            frame: frame,
            notchRect: notch,
            physicalNotchWidth: safeNotch?.width,
            usesWingLayout: placement == .overlay && safeNotch != nil,
            fellBackForSafety: fellBack
        )
    }
}

enum PointerHitTesting {
    /// Keep the collapsed activation target slightly inside the visible island.
    /// The panel itself includes a large transparent glow margin, which should
    /// never open the island just because the pointer crossed it.
    static let collapsedHorizontalInset: CGFloat = 8
    static let collapsedVerticalInset: CGFloat = 3

    static func hoverRegion(
        panelFrame: CGRect,
        placement: PanelPlacement,
        phase: PanelPhase
    ) -> CGRect {
        let isExpanded = phase == .expanded || phase == .collapsePending
        let surfaceHeight: CGFloat
        switch (placement, isExpanded) {
        case (.overlay, true):
            surfaceHeight = PanelGeometry.overlayExpandedHeight
        case (.overlay, false):
            surfaceHeight = min(PanelGeometry.overlayCollapsedWindowHeight, panelFrame.height)
        case (.floating, true):
            surfaceHeight = PanelGeometry.floatingExpandedHeight
        case (.floating, false):
            surfaceHeight = PanelGeometry.collapsedHeight
        }

        let surfaceMaxY = placement == .floating
            ? panelFrame.maxY - PanelGeometry.glowOutset
            : panelFrame.maxY
        var region = CGRect(
            x: panelFrame.midX - PanelGeometry.islandWidth / 2,
            y: surfaceMaxY - surfaceHeight,
            width: PanelGeometry.islandWidth,
            height: surfaceHeight
        )

        if !isExpanded {
            region = region.insetBy(
                dx: collapsedHorizontalInset,
                dy: collapsedVerticalInset
            )
        }
        return region
    }

    /// NSEvent.mouseLocation can land exactly on a screen's maxY. CGRect.contains
    /// uses a half-open upper bound, so use a closed interval and tolerate a
    /// tiny logical overshoot at the top edge.
    static func contains(
        _ point: CGPoint,
        in rect: CGRect,
        topOvershoot: CGFloat = 2
    ) -> Bool {
        point.x >= rect.minX
            && point.x <= rect.maxX
            && point.y >= rect.minY
            && point.y <= rect.maxY + topOvershoot
    }
}
