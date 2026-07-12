#if DEBUG
import AppKit
import SwiftUI

@MainActor
final class HarnessEnvironment {
    let monotonicClock = ManualMonotonicClock()
    let wallClock: FakeWallClock
    let quotaSource: HarnessQuotaSource
    let taskSource: HarnessTaskSource

    init() {
        let now = Date()
        wallClock = FakeWallClock(now: now)
        quotaSource = HarnessQuotaSource(snapshot: QuotaSnapshot(
            fiveHour: QuotaWindow(kind: .fiveHour, remainingPercent: 72, resetsAt: now.addingTimeInterval(32 * 60)),
            weekly: QuotaWindow(kind: .weekly, remainingPercent: 41, resetsAt: now.addingTimeInterval(2 * 86_400)),
            additionalBuckets: [
                QuotaBucket(
                    id: "codex_bengalfox",
                    displayName: "GPT-5.3-Codex-Spark",
                    fiveHour: QuotaWindow(kind: .fiveHour, remainingPercent: 96, resetsAt: now.addingTimeInterval(55 * 60)),
                    weekly: QuotaWindow(kind: .weekly, remainingPercent: 88, resetsAt: now.addingTimeInterval(6 * 86_400))
                )
            ],
            receivedAt: now
        ))
        taskSource = HarnessTaskSource(tasks: Self.runningTasks)
    }

    func setTaskStatus(_ status: IslandVisualStatus) {
        Task {
            switch status {
            case .running:
                await taskSource.setHealth(.connected)
                await taskSource.setTasks(Self.runningTasks)
            case .waitingForUser:
                await taskSource.setHealth(.connected)
                await taskSource.setTasks([
                    TaskSummary(id: "harness-1", title: "实现额度状态聚合器", runState: .waitingForUser)
                ])
            case .error:
                await taskSource.setHealth(.connected)
                await taskSource.setTasks([
                    TaskSummary(id: "harness-1", title: "实现额度状态聚合器", runState: .error)
                ])
                await taskSource.emitTerminalError(taskID: "harness-1")
            case .idle:
                await taskSource.setHealth(.connected)
                await taskSource.setTasks([])
            case .disconnected:
                await taskSource.setTasks([])
                await taskSource.setHealth(.disconnected)
            }
        }
    }

    func toggleQuotaStale() {
        Task { await quotaSource.toggleStale() }
    }

    func setWeeklyMissing() {
        Task { await quotaSource.setWeeklyMissing() }
    }

    func toggleQuotaDisconnected() {
        Task { await quotaSource.toggleDisconnected() }
    }

    func advance(_ duration: Duration) {
        monotonicClock.advance(by: duration)
    }

    private static let runningTasks = [
        TaskSummary(id: "harness-1", title: "实现额度状态聚合器", runState: .running),
        TaskSummary(id: "harness-2", title: "验证刘海安全区几何", runState: .running),
        TaskSummary(id: "harness-3", title: "补充 JSONL 隐私测试", runState: .running)
    ]
}

actor HarnessQuotaSource: QuotaSource {
    private var continuation: AsyncStream<QuotaSourceEvent>.Continuation?
    private var snapshot: QuotaSnapshot
    private var health: SourceHealth = .connected
    private var started = false

    init(snapshot: QuotaSnapshot) {
        self.snapshot = snapshot
    }

    func events() async -> AsyncStream<QuotaSourceEvent> {
        continuation?.finish()
        let pair = AsyncStream<QuotaSourceEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        continuation = pair.continuation
        return pair.stream
    }

    func start() async {
        started = true
        continuation?.yield(.healthChanged(health))
        continuation?.yield(.snapshot(snapshot))
    }

    func stop() async {
        started = false
    }

    func refresh() async {
        guard started else { return }
        continuation?.yield(.snapshot(snapshot))
    }

    func toggleStale() {
        let stale = !(snapshot.fiveHour?.isStale ?? false)
        snapshot.fiveHour?.isStale = stale
        snapshot.weekly?.isStale = stale
        health = stale ? .stale : .connected
        continuation?.yield(.healthChanged(health))
        continuation?.yield(.snapshot(snapshot))
    }

    func setWeeklyMissing() {
        snapshot.weekly = nil
        continuation?.yield(.snapshot(snapshot))
    }

    func toggleDisconnected() {
        health = health == .failed ? .connected : .failed
        continuation?.yield(.healthChanged(health))
        if health == .connected { continuation?.yield(.snapshot(snapshot)) }
    }
}

actor HarnessTaskSource: TaskSource {
    private var continuation: AsyncStream<TaskSourceEvent>.Continuation?
    private var tasks: [TaskSummary]
    private var health: SourceHealth = .connected

    init(tasks: [TaskSummary]) {
        self.tasks = tasks
    }

    func events() async -> AsyncStream<TaskSourceEvent> {
        continuation?.finish()
        let pair = AsyncStream<TaskSourceEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        continuation = pair.continuation
        return pair.stream
    }

    func start() async {
        continuation?.yield(.healthChanged(health))
        continuation?.yield(.snapshot(tasks))
    }

    func stop() async {}

    func setTasks(_ newTasks: [TaskSummary]) {
        tasks = newTasks
        continuation?.yield(.lifecycleActivity(taskID: newTasks.first?.id))
        continuation?.yield(.snapshot(newTasks))
    }

    func setHealth(_ newHealth: SourceHealth) {
        health = newHealth
        continuation?.yield(.healthChanged(newHealth))
    }

    func emitTerminalError(taskID: String?) {
        continuation?.yield(.terminalError(taskID: taskID))
    }
}

@MainActor
final class HarnessController {
    private let store: IslandStore
    private let environment: HarnessEnvironment
    private let screenProvider: AppKitScreenProvider
    private let panelCoordinator: PanelCoordinator
    private var window: NSWindow?

    init(
        store: IslandStore,
        environment: HarnessEnvironment,
        screenProvider: AppKitScreenProvider,
        panelCoordinator: PanelCoordinator
    ) {
        self.store = store
        self.environment = environment
        self.screenProvider = screenProvider
        self.panelCoordinator = panelCoordinator
    }

    func show() {
        panelCoordinator.onFrameTransition = { from, to, duration, revision, pid in
            print("[Harness] panel revision=\(revision) duration=\(String(format: "%.3f", duration)) from=\(NSStringFromRect(from)) to=\(NSStringFromRect(to)) frontmostPID=\(pid.map(String.init) ?? "nil")")
        }

        let root = HarnessControlView(
            setStatus: { [weak environment] in environment?.setTaskStatus($0) },
            setPlacement: { [weak store] in store?.send(.placementPreferenceChanged($0)) },
            setDisplay: { [weak self] in self?.setDisplayProfile($0) },
            refreshQuota: { [weak store] in store?.send(.refreshQuota) },
            toggleQuotaStale: { [weak environment] in environment?.toggleQuotaStale() },
            setWeeklyMissing: { [weak environment] in environment?.setWeeklyMissing() },
            toggleQuotaDisconnected: { [weak environment] in environment?.toggleQuotaDisconnected() },
            advanceClock: { [weak environment] in environment?.advance($0) }
        )
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = "MoniArc Harness"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(CGSize(width: 470, height: 440))
        window.isReleasedWhenClosed = false
        window.center()
        window.orderFrontRegardless()
        self.window = window
    }

    func close() {
        window?.close()
        window = nil
    }

    private func setDisplayProfile(_ profile: HarnessDisplayProfile) {
        let preference = store.state.placementPreference
        if profile == .unavailable {
            Task { await screenProvider.setAvailable(false, preference: preference) }
            return
        }

        Task {
            await screenProvider.setAvailable(true, preference: preference)
            if profile == .actual {
                await screenProvider.setHarnessDisplayOverride(nil, preference: preference)
                return
            }

            let origin: CGPoint = profile == .negativeExternal ? CGPoint(x: -1920, y: 200) : .zero
            let size = profile == .negativeExternal ? CGSize(width: 1920, height: 1080) : CGSize(width: 1512, height: 982)
            let frame = CGRect(origin: origin, size: size)
            let notchWidth = profile.notchWidth
            let safeTop: CGFloat = notchWidth == nil ? 0 : 32
            let left: CGRect?
            let right: CGRect?
            if let notchWidth {
                let leftMax = frame.midX - notchWidth / 2
                let rightMin = frame.midX + notchWidth / 2
                left = CGRect(x: frame.minX, y: frame.maxY - safeTop, width: leftMax - frame.minX, height: safeTop)
                right = CGRect(x: rightMin, y: frame.maxY - safeTop, width: frame.maxX - rightMin, height: safeTop)
            } else {
                left = nil
                right = nil
            }

            await screenProvider.setHarnessDisplayOverride(DisplaySnapshot(
                identifier: "harness-\(profile.rawValue)",
                frame: frame,
                visibleFrame: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - 33),
                safeAreaTop: safeTop,
                statusBarThickness: 24,
                auxiliaryTopLeftArea: left,
                auxiliaryTopRightArea: right,
                backingScaleFactor: 2
            ), preference: preference)
        }
    }
}

enum HarnessDisplayProfile: String, CaseIterable, Identifiable {
    case actual
    case notch185
    case notch198
    case notch218
    case narrowWing
    case flat
    case negativeExternal
    case unavailable

    var id: String { rawValue }

    var label: String {
        switch self {
        case .actual: "真实屏幕"
        case .notch185: "刘海 185"
        case .notch198: "刘海 198"
        case .notch218: "刘海 218"
        case .narrowWing: "异常窄翼"
        case .flat: "无刘海"
        case .negativeExternal: "负坐标外接"
        case .unavailable: "屏幕不可用"
        }
    }

    var notchWidth: CGFloat? {
        switch self {
        case .notch185: 185
        case .notch198: 198
        case .notch218: 218
        case .narrowWing: 230
        default: nil
        }
    }
}

private struct HarnessControlView: View {
    var setStatus: (IslandVisualStatus) -> Void
    var setPlacement: (PlacementPreference) -> Void
    var setDisplay: (HarnessDisplayProfile) -> Void
    var refreshQuota: () -> Void
    var toggleQuotaStale: () -> Void
    var setWeeklyMissing: () -> Void
    var toggleQuotaDisconnected: () -> Void
    var advanceClock: (Duration) -> Void

    @State private var displayProfile: HarnessDisplayProfile = .actual

    var body: some View {
        Form {
            Section("任务状态") {
                HStack {
                    ForEach(IslandVisualStatus.displayCases, id: \.self) { status in
                        Button(status.localizedName) { setStatus(status) }
                    }
                }
            }
            Section("位置与屏幕") {
                HStack {
                    Button("自动") { setPlacement(.automatic) }
                    Button("覆盖") { setPlacement(.overlay) }
                    Button("悬浮") { setPlacement(.floating) }
                }
                Picker("屏幕", selection: $displayProfile) {
                    ForEach(HarnessDisplayProfile.allCases) { profile in
                        Text(profile.label).tag(profile)
                    }
                }
                .onChange(of: displayProfile) { _, value in setDisplay(value) }
            }
            Section("确定性单调时钟") {
                HStack {
                    Button("+59.999s") { advanceClock(.milliseconds(59_999)) }
                    Button("+1ms") { advanceClock(.milliseconds(1)) }
                    Button("+10s") { advanceClock(.seconds(10)) }
                    Button("+30s") { advanceClock(.seconds(30)) }
                }
            }
            Section("额度源") {
                HStack {
                    Button("刷新", action: refreshQuota)
                    Button("切换 stale", action: toggleQuotaStale)
                    Button("缺失周额度", action: setWeeklyMissing)
                    Button("断线 / 恢复", action: toggleQuotaDisconnected)
                }
            }
            Text("Frame、动画时长、revision 与前台 PID 输出到调试控制台。Release 构建不编译本控制窗口。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 470, height: 440)
    }
}
#endif
