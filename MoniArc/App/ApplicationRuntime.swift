import AppKit
import Combine
import Foundation

@MainActor
final class ApplicationRuntime {
    let model: IslandViewModel
    let panelCoordinator: PanelCoordinator
    let screenProvider: AppKitScreenProvider
    let pointerSensor: PanelPointerSensor
    let store: IslandStore

    private let isHarness: Bool
    private var stateObservation: AnyCancellable?
#if DEBUG
    private var harnessEnvironment: HarnessEnvironment?
    private var harnessController: HarnessController?
#endif

    init(isHarness: Bool) {
        self.isHarness = isHarness

        let model = IslandViewModel()
        let panelCoordinator = PanelCoordinator(model: model)
        let screenProvider = AppKitScreenProvider()
        let pointerSensor = PanelPointerSensor()
        self.model = model
        self.panelCoordinator = panelCoordinator
        self.screenProvider = screenProvider
        self.pointerSensor = pointerSensor

        let initialState = IslandState(
            placementPreference: PanelCoordinator.savedPlacementPreference
        )

#if DEBUG
        if isHarness {
            let environment = HarnessEnvironment()
            self.harnessEnvironment = environment
            self.store = IslandStore(
                initialState: initialState,
                dependencies: IslandDependencies(
                    clock: environment.monotonicClock,
                    wallClock: environment.wallClock,
                    quotaSource: environment.quotaSource,
                    taskSource: environment.taskSource,
                    panelDriver: panelCoordinator,
                    screenProvider: screenProvider,
                    pointerSensor: pointerSensor
                )
            )
        } else {
            self.store = IslandStore(
                initialState: initialState,
                dependencies: IslandDependencies(
                    quotaSource: CodexAppServerQuotaSource(),
                    taskSource: CodexTaskSource(),
                    panelDriver: panelCoordinator,
                    screenProvider: screenProvider,
                    pointerSensor: pointerSensor
                )
            )
        }
#else
        self.store = IslandStore(
            initialState: initialState,
            dependencies: IslandDependencies(
                quotaSource: CodexAppServerQuotaSource(),
                taskSource: CodexTaskSource(),
                panelDriver: panelCoordinator,
                screenProvider: screenProvider,
                pointerSensor: pointerSensor
            )
        )
#endif
    }

    func start() {
        configureCallbacks()
        stateObservation = store.$state.sink { [weak self] state in
            self?.render(state)
        }
        panelCoordinator.start()
        store.start()

#if DEBUG
        if isHarness, let harnessEnvironment {
            let controller = HarnessController(
                store: store,
                environment: harnessEnvironment,
                screenProvider: screenProvider,
                panelCoordinator: panelCoordinator
            )
            harnessController = controller
            controller.show()
        }
#endif
    }

    func stop() {
        store.stop()
        stateObservation?.cancel()
        stateObservation = nil
        panelCoordinator.stop()
#if DEBUG
        harnessController?.close()
        harnessController = nil
#endif
    }

    private func configureCallbacks() {
        panelCoordinator.onHoverChanged = { [weak pointerSensor] isInside in
            pointerSensor?.emit(isInside)
        }
        panelCoordinator.onPlacementPreferenceChanged = { [weak store] preference in
            store?.send(.placementPreferenceChanged(preference))
        }
        panelCoordinator.onRefreshQuota = { [weak store] in
            store?.send(.refreshQuota)
        }
        panelCoordinator.onDisplayChanged = { [weak self] in
            guard let self else { return }
            let preference = self.store.state.placementPreference
            Task { await self.screenProvider.refresh(for: preference) }
        }
        panelCoordinator.onApplicationSuspendedChanged = { [weak self] suspended in
            guard let self else { return }
            self.store.send(.setQuotaPause(reason: .appSuspended, active: suspended))
            let preference = self.store.state.placementPreference
            Task { await self.screenProvider.setAvailable(!suspended, preference: preference) }
        }
        model.onPreviousTask = { [weak self] in
            self?.store.send(.selectTask(.previous))
            self?.recordForegroundApplicationAfterNavigation()
        }
        model.onNextTask = { [weak self] in
            self?.store.send(.selectTask(.next))
            self?.recordForegroundApplicationAfterNavigation()
        }
    }

    private func render(_ state: IslandState) {
        model.isExpanded = state.panelPhase == .expanded || state.panelPhase == .collapsePending
        model.activeQuotaPage = state.quotaRotation.visibleKind == .fiveHour ? .fiveHour : .weekly
        model.fiveHourQuota = quotaPresentation(state.quotaSnapshot?.fiveHour)
        model.weeklyQuota = quotaPresentation(state.quotaSnapshot?.weekly)
        model.normalizeActiveQuotaPage()
        model.additionalQuotas = state.quotaSnapshot?.additionalBuckets.map { bucket in
            AdditionalQuotaPresentation(
                id: bucket.id,
                label: quotaBucketLabel(id: bucket.id, displayName: bucket.displayName),
                fiveHour: quotaPresentation(bucket.fiveHour),
                weekly: quotaPresentation(bucket.weekly)
            )
        } ?? []
        model.normalizeQuotaBucketSelection()
        model.tasks = state.tasks.map { IslandTaskPresentation(id: $0.id, title: $0.title) }
        model.selectedTaskIndex = state.selectedTaskIndex ?? 0
        model.normalizeTaskSelection()
        model.status = state.effectiveStatus
        model.quotaSourceMessage = quotaMessage(for: state.quotaSourceHealth)
        panelCoordinator.reflect(state: state)
    }

    private func quotaPresentation(_ window: QuotaWindow?) -> QuotaPresentation {
        guard let window else { return .unavailable }
        return QuotaPresentation(
            remainingPercent: Int(window.remainingPercent.rounded()),
            resetsAt: window.resetsAt,
            isStale: window.isStale
        )
    }

    private func quotaMessage(for health: SourceHealth) -> String? {
        switch health {
        case .connected: nil
        case .stale: "额度旧值"
        case .disconnected: "正在连接"
        case .failed: "额度断开"
        case .incompatible: "协议不兼容"
        }
    }

    private func quotaBucketLabel(id: String, displayName: String?) -> String {
        let candidate = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate?.localizedCaseInsensitiveContains("spark") == true
            || id.localizedCaseInsensitiveContains("spark")
            || id.localizedCaseInsensitiveContains("bengalfox")
        {
            return "Spark"
        }
        guard let candidate, !candidate.isEmpty else { return "其他" }
        return candidate.count <= 10 ? candidate : String(candidate.prefix(9)) + "…"
    }

    private func recordForegroundApplicationAfterNavigation() {
#if DEBUG
        guard isHarness else { return }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        print("[Harness] task navigation frontmostPID=\(pid.map(String.init) ?? "nil")")
#endif
    }
}
