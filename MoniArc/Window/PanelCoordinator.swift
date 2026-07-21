import AppKit
import QuartzCore
import SwiftUI

/// Owns the single nonactivating window. Timing and state decisions deliberately
/// remain in `IslandStore`; this object only reports pointer/lifecycle events and
/// executes revisioned frame transitions.
@MainActor
final class PanelCoordinator: NSObject, PanelDriver {
    static let placementDefaultsKey = "MoniArc.placementPreference"
    static let glowMotionOverrideDefaultsKey = "MoniArc.glowMotionOverride"
    static let hdrOverrideDefaultsKey = "MoniArc.hdrOverride"
    static let legacyBorderGlowDefaultsKey = "MoniArc.borderGlowStyle"
    static let legacyHDRBrightnessDefaultsKey = "MoniArc.hdrBrightnessMode"

    let model: IslandViewModel
    let panel = IslandPanel()

    var onHoverChanged: ((Bool) -> Void)?
    var onPlacementPreferenceChanged: ((PlacementPreference) -> Void)?
    var onRefreshQuota: (() -> Void)?
    var onDisplayChanged: (() -> Void)?
    var onApplicationSuspendedChanged: ((Bool) -> Void)?
    var onFrameTransition: ((CGRect, CGRect, TimeInterval, UInt64, pid_t?) -> Void)?

    private let pointerMonitor = PointerMonitor()
    private var observers: [NSObjectProtocol] = []
    private var hostingView: NSHostingView<IslandView>?
    private var hdrGlowView: HDRStatusGlowView?
    private var pointerInside = false
    private var reflectedPanelPhase: PanelPhase = .collapsed
    private var isSessionAvailable = true
    private var activeRevision: UInt64 = 0
    private var reflectedPreference: PlacementPreference
    private var reflectedGlowMotionOverride: GlowMotionOverride
    private var reflectedHDROverride: HDROverride
    private var lastReflectedState: IslandState?

    override init() {
        fatalError("Use init(model:)")
    }

    init(model: IslandViewModel) {
        self.model = model
        self.reflectedPreference = Self.savedPlacementPreference
        self.reflectedGlowMotionOverride = Self.savedGlowMotionOverride
        self.reflectedHDROverride = Self.savedHDROverride
        super.init()
        UserDefaults.standard.set(
            reflectedGlowMotionOverride.rawValue,
            forKey: Self.glowMotionOverrideDefaultsKey
        )
        UserDefaults.standard.set(
            reflectedHDROverride.rawValue,
            forKey: Self.hdrOverrideDefaultsKey
        )
    }

    static var savedPlacementPreference: PlacementPreference {
        let raw = UserDefaults.standard.string(forKey: placementDefaultsKey)
        return PlacementPreference(rawValue: raw ?? "") ?? .automatic
    }

    static var savedGlowMotionOverride: GlowMotionOverride {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: glowMotionOverrideDefaultsKey),
           let value = GlowMotionOverride(rawValue: raw) {
            return value
        }

        guard defaults.object(forKey: legacyBorderGlowDefaultsKey) != nil else {
            return .automatic
        }
        switch defaults.string(forKey: legacyBorderGlowDefaultsKey) {
        case "flow", "flowing": return .flow
        case "breathe", "breathing": return .breathe
        default: return .automatic
        }
    }

    static var savedHDROverride: HDROverride {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: hdrOverrideDefaultsKey),
           let value = HDROverride(rawValue: raw) {
            return value
        }

        guard defaults.object(forKey: legacyHDRBrightnessDefaultsKey) != nil else {
            return .automatic
        }
        switch defaults.string(forKey: legacyHDRBrightnessDefaultsKey) {
        case "bright", "soft", "on": return .on
        case "off": return .off
        default: return .automatic
        }
    }

    func start() {
        configureContent()
        pointerMonitor.onLocationChanged = { [weak self] location in
            self?.updatePointerState(at: location)
        }
        installLifecycleObservers()
        pointerMonitor.start()
    }

    func stop() {
        pointerMonitor.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        hdrGlowView?.stopRendering()
        panel.orderOut(nil)
    }

    func reflect(state: IslandState) {
        lastReflectedState = state
        reflectedPreference = state.placementPreference
        reflectedPanelPhase = state.panelPhase
        UserDefaults.standard.set(state.placementPreference.rawValue, forKey: Self.placementDefaultsKey)

        if state.isAwaitingRehostLayout, let previousLayout = state.panelLayout {
            // Freeze any animator callback from the old host and collapse against
            // the old top anchor before the replacement layout is installed.
            activeRevision = max(activeRevision, state.panelRevision.rawValue)
            panel.setFrame(CGRect(previousLayout.collapsedFrame), display: true)
        }

        model.placement = state.resolvedPlacement
        if let layout = state.panelLayout {
            let notchWidth = layout.notchFrame.map(CGRect.init)?.width ?? 0
            model.physicalNotchWidth = notchWidth
            model.usesWingLayout = layout.placement == .overlay
                && notchWidth > 0
                && (PanelGeometry.islandWidth - notchWidth) / 2 >= PanelGeometry.minimumWingWidth
        } else {
            model.physicalNotchWidth = 0
            model.usesWingLayout = false
        }

        applyResolvedGlowAppearance()
        updateHDRGlow()

        if !isSessionAvailable || state.panelLayout == nil {
            panel.orderOut(nil)
        }
        updatePointerState(at: NSEvent.mouseLocation)
    }

    func apply(_ transition: PanelTransition) async {
        let revision = transition.revision.rawValue
        activeRevision = max(activeRevision, revision)
        let targetFrame = CGRect(transition.frame)
        let oldFrame = panel.frame
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let requestedDuration = transition.duration.timeInterval
        let duration = transition.animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? requestedDuration
            : 0

        guard isSessionAvailable else {
            panel.setFrame(targetFrame, display: false)
            onFrameTransition?(oldFrame, targetFrame, 0, revision, frontmostPID)
            return
        }

        panel.orderFrontRegardless()
        if duration == 0 {
            panel.setFrame(targetFrame, display: true)
            updateHDRGlow()
            onFrameTransition?(oldFrame, targetFrame, 0, revision, frontmostPID)
            updatePointerState(at: NSEvent.mouseLocation)
            return
        }

        onFrameTransition?(oldFrame, targetFrame, duration, revision, frontmostPID)
        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = transition.curve == .easeOut
                    ? CAMediaTimingFunction(controlPoints: 0.70, 0, 1, 1)
                    : CAMediaTimingFunction(controlPoints: 0.82, 0, 1, 1)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(targetFrame, display: true)
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    if let self, self.activeRevision == revision {
                        self.panel.setFrame(targetFrame, display: true)
                        self.updateHDRGlow()
                        self.updatePointerState(at: NSEvent.mouseLocation)
                    }
                    continuation.resume()
                }
            }
        }
    }

    private func configureContent() {
        model.onContextMenu = { [weak self] point in self?.showContextMenu(at: point) }

        let initialFrame = CGRect(
            origin: .zero,
            size: CGSize(
                width: PanelGeometry.panelWidth,
                height: PanelGeometry.collapsedHeight + PanelGeometry.glowOutset
            )
        )
        let container = NSView(frame: initialFrame)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        let hdrGlow = HDRStatusGlowView(frame: initialFrame)
        model.usesMetalGlow = hdrGlow.isRendererAvailable
        if hdrGlow.isRendererAvailable {
            hdrGlow.autoresizingMask = [.width, .height]
            container.addSubview(hdrGlow)
            hdrGlowView = hdrGlow
        }

        let host = NSHostingView(rootView: IslandView(model: model))
        host.frame = initialFrame
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: hdrGlowView)
        panel.contentView = container

        hostingView = host
        updateHDRGlow()
    }

    private func updateHDRGlow() {
        guard let hdrGlowView else { return }
        let surfaceHeight: CGFloat
        if model.isExpanded {
            surfaceHeight = model.placement == .overlay
                ? IslandDesign.overlayExpandedHeight
                : IslandDesign.floatingExpandedHeight
        } else {
            surfaceHeight = model.placement == .overlay && model.usesWingLayout
                ? IslandDesign.overlayCollapsedHeight
                : IslandDesign.collapsedHeight
        }

        hdrGlowView.update(
            appearance: model.glowAppearance,
            surfaceHeight: surfaceHeight,
            bottomRadius: model.isExpanded ? IslandDesign.expandedRadius : IslandDesign.floatingRadius,
            closesTop: model.placement == .floating,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    private func updatePointerState(at location: CGPoint) {
        guard isSessionAvailable else { return }
        let shouldIgnoreMouseEvents = PointerHitTesting.shouldIgnoreMouseEvents(
            at: location,
            panelFrame: panel.frame,
            placement: model.placement,
            phase: reflectedPanelPhase
        )
        panel.ignoresMouseEvents = shouldIgnoreMouseEvents
        let isInside = !shouldIgnoreMouseEvents
        guard isInside != pointerInside else { return }
        pointerInside = isInside
        onHoverChanged?(isInside)
    }

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateHDRGlow()
                self?.onDisplayChanged?()
            }
        })

        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onDisplayChanged?() }
        })

        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.setSessionAvailable(false) }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.setSessionAvailable(true) }
            })
        }
    }

    private func setSessionAvailable(_ available: Bool) {
        guard isSessionAvailable != available else { return }
        isSessionAvailable = available
        onApplicationSuspendedChanged?(!available)
        if available {
            onDisplayChanged?()
            onRefreshQuota?()
        } else {
            pointerInside = false
            onHoverChanged?(false)
            panel.orderOut(nil)
        }
    }

    private func showContextMenu(at screenPoint: CGPoint) {
        let menu = NSMenu(title: "MoniArc")
        menu.autoenablesItems = false

        for (title, preference) in [
            ("覆盖", PlacementPreference.overlay),
            ("悬浮", PlacementPreference.floating)
        ] {
            let item = NSMenuItem(title: title, action: #selector(selectPlacement(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preference.rawValue
            item.state = preference == reflectedPreference ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let glowMenu = NSMenu(title: "边框光效")
        for style in GlowMotionOverride.allCases {
            let item = NSMenuItem(
                title: style.localizedName,
                action: #selector(selectBorderGlow(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = style.rawValue
            item.state = style == reflectedGlowMotionOverride ? .on : .off
            glowMenu.addItem(item)
        }
        let glowItem = NSMenuItem(title: "边框光效", action: nil, keyEquivalent: "")
        glowItem.submenu = glowMenu
        menu.addItem(glowItem)

        let hdrMenu = NSMenu(title: "HDR")
        for mode in HDROverride.allCases {
            let item = NSMenuItem(
                title: mode.localizedName,
                action: #selector(selectHDRBrightness(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == reflectedHDROverride ? .on : .off
            hdrMenu.addItem(item)
        }
        let hdrItem = NSMenuItem(title: "HDR", action: nil, keyEquivalent: "")
        hdrItem.submenu = hdrMenu
        menu.addItem(hdrItem)
        menu.addItem(.separator())

        let github = NSMenuItem(
            title: "GitHub 地址",
            action: #selector(openGitHubRepository),
            keyEquivalent: ""
        )
        github.target = self
        menu.addItem(github)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 MoniArc", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: screenPoint, in: nil)
    }

    @objc private func selectPlacement(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preference = PlacementPreference(rawValue: raw) else { return }
        onPlacementPreferenceChanged?(preference)
    }

    @objc private func selectBorderGlow(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = GlowMotionOverride(rawValue: raw) else { return }
        setGlowMotionOverride(style)
    }

    @objc private func selectHDRBrightness(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = HDROverride(rawValue: raw) else { return }
        setHDROverride(mode)
    }

    func setGlowMotionOverride(_ value: GlowMotionOverride) {
        reflectedGlowMotionOverride = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.glowMotionOverrideDefaultsKey)
        applyResolvedGlowAppearance()
        updateHDRGlow()
    }

    func setHDROverride(_ value: HDROverride) {
        reflectedHDROverride = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.hdrOverrideDefaultsKey)
        applyResolvedGlowAppearance()
        updateHDRGlow()
    }

    private func applyResolvedGlowAppearance() {
        guard let state = lastReflectedState else {
            model.glowAppearance = .inactive
            return
        }
        model.glowAppearance = state.resolvedGlowAppearance(
            motionOverride: reflectedGlowMotionOverride,
            hdrOverride: reflectedHDROverride
        )
    }

    @objc private func openGitHubRepository() {
        NSWorkspace.shared.open(URL(string: "https://github.com/ch3n923/MoniArc")!)
    }

    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
