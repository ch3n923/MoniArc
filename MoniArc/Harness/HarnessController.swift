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

    fileprivate static let runningTasks = [
        TaskSummary(
            id: "harness-1",
            title: "实现额度状态聚合器",
            runState: .running,
            lightingProfile: TaskLightingProfile(theme: .terra, speed: .standard, prefersHDR: false)
        ),
        TaskSummary(
            id: "harness-2",
            title: "验证刘海安全区几何",
            runState: .running,
            lightingProfile: TaskLightingProfile(theme: .terra, speed: .standard, prefersHDR: false)
        ),
        TaskSummary(
            id: "harness-3",
            title: "补充 JSONL 隐私测试",
            runState: .running,
            lightingProfile: TaskLightingProfile(theme: .terra, speed: .standard, prefersHDR: false)
        ),
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
        let task = tasks.first { $0.id == taskID }
        continuation?.yield(.terminalError(
            taskID: taskID,
            taskUpdatedAt: task?.updatedAt,
            lightingProfile: task?.lightingProfile ?? .fallback
        ))
    }
}

@MainActor
final class HarnessController {
    private let store: IslandStore
    private let environment: HarnessEnvironment
    private let screenProvider: AppKitScreenProvider
    private let panelCoordinator: PanelCoordinator
    private var window: NSWindow?
    private var harnessStatus: IslandVisualStatus = .running
    private var harnessTheme: TaskLightingTheme = .terra
    private var harnessSpeed: TaskSpeedMode = .standard
    private var harnessReasoningEffort: HarnessReasoningEffort = .medium
    private var usesMultiTaskPriorityFixture = false

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
        runLightingLogicChecks()
        panelCoordinator.onFrameTransition = { from, to, duration, revision, pid in
            print("[Harness] panel revision=\(revision) duration=\(String(format: "%.3f", duration)) from=\(NSStringFromRect(from)) to=\(NSStringFromRect(to)) frontmostPID=\(pid.map(String.init) ?? "nil")")
        }

        let root = HarnessControlView(
            model: panelCoordinator.model,
            setStatus: { [weak self] in self?.setTaskStatusImmediately($0) },
            setTheme: { [weak self] in self?.setHarnessTheme($0) },
            setSpeed: { [weak self] in self?.setHarnessSpeed($0) },
            setReasoningEffort: { [weak self] in self?.setHarnessReasoningEffort($0) },
            setMultiTaskPriorityFixture: { [weak self] in self?.setMultiTaskPriorityFixture($0) },
            setGlowOverride: { [weak self] in self?.panelCoordinator.setGlowMotionOverride($0) },
            setHDROverride: { [weak self] in self?.panelCoordinator.setHDROverride($0) },
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
        window.setContentSize(CGSize(width: 520, height: 640))
        window.isReleasedWhenClosed = false
        window.center()
        window.orderFrontRegardless()
        self.window = window
        setTaskStatusImmediately(.running)
    }

    func close() {
        window?.close()
        window = nil
    }

    private func runLightingLogicChecks() {
        let terraFastHDR = TaskLightingProfile.normalized(
            model: "gpt-5.6-terra",
            serviceTier: "priority",
            reasoningEffort: "high"
        )
        precondition(terraFastHDR == TaskLightingProfile(theme: .terra, speed: .fast, prefersHDR: true))
        precondition(TaskLightingProfile.normalizedSpeed("fast") == .fast)
        precondition(TaskLightingProfile.normalized(model: nil, serviceTier: nil, reasoningEffort: nil) == .fallback)
        for effort in ["high", "xhigh", "max", "ultra"] {
            precondition(TaskLightingProfile.normalizedHDRPreference(effort))
        }
        precondition(!TaskLightingProfile.normalizedHDRPreference("medium"))

        let now = Date()
        var state = IslandState(
            tasks: [
                TaskSummary(
                    id: "terra",
                    title: "Terra",
                    runState: .running,
                    updatedAt: now,
                    lightingProfile: terraFastHDR
                )
            ],
            taskSourceHealth: .connected
        )
        var appearance = state.resolvedGlowAppearance(
            motionOverride: .automatic,
            hdrOverride: .automatic
        )
        precondition(appearance.theme == .terra && appearance.motion == .flow && appearance.usesHDR)

        state.tasks = [
            TaskSummary(
                id: "sol",
                title: "Sol",
                runState: .waitingForUser,
                updatedAt: now.addingTimeInterval(-10),
                lightingProfile: TaskLightingProfile(theme: .sol, speed: .fast, prefersHDR: false)
            ),
            TaskSummary(
                id: "other-newest",
                title: "Other",
                runState: .running,
                updatedAt: now,
                lightingProfile: TaskLightingProfile(theme: .other, speed: .standard, prefersHDR: true)
            ),
        ]
        appearance = state.resolvedGlowAppearance(
            motionOverride: .automatic,
            hdrOverride: .automatic
        )
        precondition(appearance.theme == .sol && appearance.motion == .solarFlare && !appearance.usesHDR)

        appearance = state.resolvedGlowAppearance(motionOverride: .breathe, hdrOverride: .on)
        precondition(appearance.motion == .breathe && appearance.usesHDR)
        appearance = state.resolvedGlowAppearance(motionOverride: .flow, hdrOverride: .off)
        precondition(appearance.motion == .solarFlare && !appearance.usesHDR)

        state.tasks = [
            TaskSummary(
                id: "terra-older",
                title: "Terra older",
                runState: .running,
                updatedAt: now.addingTimeInterval(-5),
                lightingProfile: TaskLightingProfile(theme: .terra, speed: .fast, prefersHDR: true)
            ),
            TaskSummary(
                id: "terra-newer",
                title: "Terra newer",
                runState: .running,
                updatedAt: now,
                lightingProfile: TaskLightingProfile(theme: .terra, speed: .standard, prefersHDR: false)
            ),
        ]
        appearance = state.resolvedGlowAppearance(
            motionOverride: .automatic,
            hdrOverride: .automatic
        )
        precondition(appearance.theme == .terra && appearance.motion == .breathe && !appearance.usesHDR)

        state.tasks = []
        state.terminalErrorLatch = TerminalErrorLatch(
            taskID: "luna-error",
            taskUpdatedAt: now,
            lightingProfile: TaskLightingProfile(theme: .luna, speed: .standard, prefersHDR: true),
            expiresAt: .init(nanoseconds: 1),
            generation: .init()
        )
        appearance = state.resolvedGlowAppearance(
            motionOverride: .automatic,
            hdrOverride: .automatic
        )
        precondition(appearance.isBusy && appearance.theme == .luna && appearance.usesHDR)

        state.terminalErrorLatch = nil
        appearance = state.resolvedGlowAppearance(motionOverride: .flow, hdrOverride: .on)
        precondition(appearance == .inactive)

        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoniArc-lighting-harness-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let fixture = """
        {"type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"high"}}
        {"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"priority"}}}
        {"type":"event_msg","payload":{"type":"task_started"}}

        """
        do {
            try Data(fixture.utf8).write(to: fixtureURL, options: .atomic)
            let result = try JSONLTaskLifecycleScanner().scan(
                fileURL: fixtureURL,
                byteLimit: 16 * 1_024
            )
            precondition(result.activeState == .running)
            precondition(result.lightingProfile == TaskLightingProfile(
                theme: .sol,
                speed: .fast,
                prefersHDR: true
            ))
        } catch {
            preconditionFailure("Lighting JSONL harness check failed: \(error)")
        }

        print("[Harness] model-linked lighting logic checks passed")
    }

    /// Visual state controls should respond in the same run-loop turn. The
    /// source actors remain useful for testing startup and streaming behavior,
    /// but routing a manual button press through two actor hops and an
    /// AsyncStream made the visual Harness unnecessarily sluggish.
    private func setTaskStatusImmediately(_ status: IslandVisualStatus) {
        harnessStatus = status
        let health: SourceHealth
        let tasks = harnessTasks(for: status)

        switch status {
        case .running:
            health = .connected
        case .waitingForUser:
            health = .connected
        case .error:
            health = .connected
        case .idle:
            health = .connected
        case .disconnected:
            health = .disconnected
        }

        store.send(.taskSourceEvent(.healthChanged(health)))
        store.send(.taskSourceEvent(.lifecycleActivity(taskID: tasks.first?.id)))
        store.send(.taskSourceEvent(.snapshot(tasks)))
        if status == .error {
            let task = tasks.first
            store.send(.taskSourceEvent(.terminalError(
                taskID: task?.id,
                taskUpdatedAt: task?.updatedAt,
                lightingProfile: task?.lightingProfile ?? .fallback
            )))
        }
    }

    private func setHarnessTheme(_ theme: TaskLightingTheme) {
        harnessTheme = theme
        setTaskStatusImmediately(harnessStatus)
    }

    private func setHarnessSpeed(_ speed: TaskSpeedMode) {
        harnessSpeed = speed
        setTaskStatusImmediately(harnessStatus)
    }

    private func setHarnessReasoningEffort(_ effort: HarnessReasoningEffort) {
        harnessReasoningEffort = effort
        setTaskStatusImmediately(harnessStatus)
    }

    private func setMultiTaskPriorityFixture(_ enabled: Bool) {
        usesMultiTaskPriorityFixture = enabled
        setTaskStatusImmediately(harnessStatus)
    }

    private func harnessTasks(for status: IslandVisualStatus) -> [TaskSummary] {
        let runState: TaskRunState
        switch status {
        case .running: runState = .running
        case .waitingForUser: runState = .waitingForUser
        case .error: runState = .error
        case .idle, .disconnected: return []
        }

        let selectedProfile = TaskLightingProfile.normalized(
            model: harnessTheme.harnessModelID,
            serviceTier: harnessSpeed == .fast ? "priority" : "default",
            reasoningEffort: harnessReasoningEffort.rawValue
        )
        let now = Date()

        guard usesMultiTaskPriorityFixture else {
            return [
                TaskSummary(
                    id: "harness-1",
                    title: "实现模型联动灯效",
                    runState: runState,
                    updatedAt: now,
                    lightingProfile: selectedProfile
                )
            ]
        }

        // Deliberately make Other the newest and Sol the oldest. A gold result
        // proves model priority wins before recency.
        return [
            harnessPriorityTask(id: "other", theme: .other, runState: runState, updatedAt: now),
            harnessPriorityTask(id: "luna", theme: .luna, runState: runState, updatedAt: now.addingTimeInterval(-1)),
            harnessPriorityTask(id: "terra", theme: .terra, runState: runState, updatedAt: now.addingTimeInterval(-2)),
            harnessPriorityTask(id: "sol", theme: .sol, runState: runState, updatedAt: now.addingTimeInterval(-3)),
        ]
    }

    private func harnessPriorityTask(
        id: String,
        theme: TaskLightingTheme,
        runState: TaskRunState,
        updatedAt: Date
    ) -> TaskSummary {
        TaskSummary(
            id: "harness-\(id)",
            title: "多任务优先级验证 \(id)",
            runState: runState,
            updatedAt: updatedAt,
            lightingProfile: TaskLightingProfile(
                theme: theme,
                speed: harnessSpeed,
                prefersHDR: harnessReasoningEffort.prefersHDR
            )
        )
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

enum HarnessReasoningEffort: String, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .xhigh: "极高"
        }
    }

    var prefersHDR: Bool {
        TaskLightingProfile.normalizedHDRPreference(rawValue)
    }
}

private extension TaskLightingTheme {
    var harnessModelID: String {
        switch self {
        case .sol: "gpt-5.6-sol"
        case .terra: "gpt-5.6-terra"
        case .luna: "gpt-5.6-luna"
        case .other: "gpt-5.5"
        }
    }

    var harnessLabel: String {
        switch self {
        case .sol: "Sol"
        case .terra: "Terra"
        case .luna: "Luna"
        case .other: "其他"
        }
    }
}

private extension GlowMotion {
    var harnessLabel: String {
        switch self {
        case .breathe: "2.5s 呼吸"
        case .flow: "4s 流动"
        case .solarFlare: "Sol 太阳耀斑"
        }
    }
}

private struct HarnessControlView: View {
    @ObservedObject var model: IslandViewModel
    var setStatus: (IslandVisualStatus) -> Void
    var setTheme: (TaskLightingTheme) -> Void
    var setSpeed: (TaskSpeedMode) -> Void
    var setReasoningEffort: (HarnessReasoningEffort) -> Void
    var setMultiTaskPriorityFixture: (Bool) -> Void
    var setGlowOverride: (GlowMotionOverride) -> Void
    var setHDROverride: (HDROverride) -> Void
    var setPlacement: (PlacementPreference) -> Void
    var setDisplay: (HarnessDisplayProfile) -> Void
    var refreshQuota: () -> Void
    var toggleQuotaStale: () -> Void
    var setWeeklyMissing: () -> Void
    var toggleQuotaDisconnected: () -> Void
    var advanceClock: (Duration) -> Void

    @State private var displayProfile: HarnessDisplayProfile = .actual
    @State private var theme: TaskLightingTheme = .terra
    @State private var speed: TaskSpeedMode = .standard
    @State private var reasoningEffort: HarnessReasoningEffort = .medium
    @State private var multiTaskPriority = false
    @State private var glowOverride = PanelCoordinator.savedGlowMotionOverride
    @State private var hdrOverride = PanelCoordinator.savedHDROverride

    var body: some View {
        Form {
            Section("任务状态") {
                HStack {
                    ForEach(IslandVisualStatus.displayCases, id: \.self) { status in
                        Button(status.localizedName) { setStatus(status) }
                    }
                }
            }
            Section("模型联动灯效") {
                Picker("模型", selection: $theme) {
                    ForEach(TaskLightingTheme.allCases, id: \.self) { value in
                        Text(value.harnessLabel).tag(value)
                    }
                }
                .onChange(of: theme) { _, value in setTheme(value) }

                Picker("速度", selection: $speed) {
                    Text("标准").tag(TaskSpeedMode.standard)
                    Text("快速 priority").tag(TaskSpeedMode.fast)
                }
                .onChange(of: speed) { _, value in setSpeed(value) }

                Picker("推理强度", selection: $reasoningEffort) {
                    ForEach(HarnessReasoningEffort.allCases) { value in
                        Text(value.label).tag(value)
                    }
                }
                .onChange(of: reasoningEffort) { _, value in setReasoningEffort(value) }

                Toggle("Sol 优先的四任务测试", isOn: $multiTaskPriority)
                    .onChange(of: multiTaskPriority) { _, value in setMultiTaskPriorityFixture(value) }

                Text(resolvedAppearanceText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(resolvedAppearanceText)
            }
            Section("手动覆盖") {
                Picker("光效", selection: $glowOverride) {
                    ForEach(GlowMotionOverride.allCases, id: \.self) { value in
                        Text(value.localizedName).tag(value)
                    }
                }
                .onChange(of: glowOverride) { _, value in setGlowOverride(value) }

                Picker("HDR", selection: $hdrOverride) {
                    ForEach(HDROverride.allCases, id: \.self) { value in
                        Text(value.localizedName).tag(value)
                    }
                }
                .onChange(of: hdrOverride) { _, value in setHDROverride(value) }
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
        .frame(width: 520, height: 640)
    }

    private var resolvedAppearanceText: String {
        let appearance = model.glowAppearance
        guard appearance.isBusy else { return "实际：灰色静态 · SDR" }
        return "实际：\(appearance.theme.harnessLabel) · \(appearance.motion.harnessLabel) · \(appearance.usesHDR ? "HDR" : "SDR")"
    }
}
#endif
