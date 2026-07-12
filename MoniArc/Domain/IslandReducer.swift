import Foundation

public enum IslandTimer: Hashable, Sendable {
    case quotaRotation
    case hoverExpansion
    case hoverCollapse
    case terminalError
}

public enum TaskSelectionDirection: Sendable {
    case previous
    case next
}

public enum IslandAction: Sendable {
    case start
    case stop
    case quotaSourceEvent(QuotaSourceEvent)
    case taskSourceEvent(TaskSourceEvent)
    case quotaRotationTimerFired(GenerationToken)
    case hoverChanged(Bool)
    case hoverExpansionTimerFired(GenerationToken)
    case hoverCollapseTimerFired(GenerationToken)
    case togglePinned
    case selectTask(TaskSelectionDirection)
    case placementPreferenceChanged(PlacementPreference)
    case panelLayoutUpdated(PanelLayoutSnapshot?)
    case panelTransitionCompleted(PanelRevision)
    case setQuotaPause(reason: QuotaPauseReason, active: Bool)
    case terminalErrorTimerFired(GenerationToken)
    case refreshQuota
}

public enum IslandEffect: Equatable, Sendable {
    case scheduleTimer(IslandTimer, token: GenerationToken, after: Duration)
    case cancelTimer(IslandTimer)
    case startSources
    case stopSources
    case refreshQuota
    case requestPanelLayout(PlacementPreference)
    case submitPanel(PanelTransition)
}

public struct IslandReducer: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var fiveHourDisplayDuration: Duration
        public var weeklyDisplayDuration: Duration
        public var hoverExpansionDelay: Duration
        public var hoverCollapseDelay: Duration
        public var expansionDuration: Duration
        public var collapseDuration: Duration
        public var terminalErrorDuration: Duration

        public init(
            fiveHourDisplayDuration: Duration = .seconds(60),
            weeklyDisplayDuration: Duration = .seconds(10),
            hoverExpansionDelay: Duration = .milliseconds(220),
            hoverCollapseDelay: Duration = .milliseconds(350),
            expansionDuration: Duration = .milliseconds(210),
            collapseDuration: Duration = .milliseconds(150),
            terminalErrorDuration: Duration = .seconds(30)
        ) {
            self.fiveHourDisplayDuration = fiveHourDisplayDuration
            self.weeklyDisplayDuration = weeklyDisplayDuration
            self.hoverExpansionDelay = hoverExpansionDelay
            self.hoverCollapseDelay = hoverCollapseDelay
            self.expansionDuration = expansionDuration
            self.collapseDuration = collapseDuration
            self.terminalErrorDuration = terminalErrorDuration
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    @discardableResult
    public mutating func reduce(
        state: inout IslandState,
        action: IslandAction,
        now: MonotonicInstant
    ) -> [IslandEffect] {
        switch action {
        case .start:
            guard !state.isStarted else { return [] }
            state.isStarted = true
            var effects: [IslandEffect] = [
                .startSources,
                .refreshQuota,
                .requestPanelLayout(state.placementPreference),
            ]
            effects += resumeQuotaRotationIfPossible(state: &state, now: now)
            return effects

        case .stop:
            guard state.isStarted else { return [] }
            state.isStarted = false
            state.quotaRotation.runningSince = nil
            state.quotaRotation.generation = state.quotaRotation.generation.advanced()
            state.interactionGeneration = state.interactionGeneration.advanced()
            state.pendingPanelDeadline = nil
            state.terminalErrorGeneration = state.terminalErrorGeneration.advanced()
            return IslandTimer.all.map(IslandEffect.cancelTimer) + [.stopSources]

        case let .quotaSourceEvent(event):
            switch event {
            case let .snapshot(snapshot):
                state.quotaSnapshot = snapshot
                state.quotaSourceHealth = .connected
            case let .healthChanged(health):
                state.quotaSourceHealth = health
            }
            return []

        case let .taskSourceEvent(event):
            return reduceTaskSourceEvent(event, state: &state, now: now)

        case let .quotaRotationTimerFired(token):
            guard
                token == state.quotaRotation.generation,
                state.quotaPauseReasons.isEmpty,
                let runningSince = state.quotaRotation.runningSince
            else { return [] }

            let elapsed = runningSince.duration(to: now)
            if elapsed < state.quotaRotation.remaining {
                let stillRemaining = nonnegative(state.quotaRotation.remaining - elapsed)
                state.quotaRotation.remaining = stillRemaining
                state.quotaRotation.runningSince = now
                state.quotaRotation.generation = state.quotaRotation.generation.advanced()
                return [
                    .scheduleTimer(
                        .quotaRotation,
                        token: state.quotaRotation.generation,
                        after: stillRemaining
                    ),
                ]
            }

            state.quotaRotation.visibleKind = state.quotaRotation.visibleKind == .fiveHour ? .weekly : .fiveHour
            state.quotaRotation.remaining = displayDuration(for: state.quotaRotation.visibleKind)
            state.quotaRotation.runningSince = now
            state.quotaRotation.generation = state.quotaRotation.generation.advanced()
            return [
                .scheduleTimer(
                    .quotaRotation,
                    token: state.quotaRotation.generation,
                    after: state.quotaRotation.remaining
                ),
            ]

        case let .hoverChanged(isInside):
            guard state.isPointerInside != isInside else { return [] }
            state.isPointerInside = isInside
            return isInside
                ? handlePointerEntry(state: &state, now: now)
                : handlePointerExit(state: &state, now: now)

        case let .hoverExpansionTimerFired(token):
            guard
                token == state.interactionGeneration,
                state.panelPhase == .expandPending,
                state.isPointerInside || state.isPinned,
                let deadline = state.pendingPanelDeadline
            else { return [] }
            if now < deadline {
                return [.scheduleTimer(.hoverExpansion, token: token, after: now.duration(to: deadline))]
            }
            state.pendingPanelDeadline = nil
            state.panelPhase = .expanded
            return submitPanelIfPossible(
                state: &state,
                expanded: true,
                animated: true,
                duration: configuration.expansionDuration,
                curve: .easeOut
            )

        case let .hoverCollapseTimerFired(token):
            guard
                token == state.interactionGeneration,
                state.panelPhase == .collapsePending,
                !state.isPointerInside,
                !state.isPinned,
                let deadline = state.pendingPanelDeadline
            else { return [] }
            if now < deadline {
                return [.scheduleTimer(.hoverCollapse, token: token, after: now.duration(to: deadline))]
            }
            state.pendingPanelDeadline = nil
            state.panelPhase = .collapsed
            let panelEffects = submitPanelIfPossible(
                state: &state,
                expanded: false,
                animated: true,
                duration: configuration.collapseDuration,
                curve: .easeIn
            )
            if panelEffects.isEmpty {
                return setQuotaPause(.panelInteraction, active: false, state: &state, now: now)
            }
            return panelEffects

        case .togglePinned:
            if state.isPinned {
                state.isPinned = false
                if !state.isPointerInside, state.panelPhase == .expanded {
                    return scheduleCollapse(state: &state, now: now)
                }
                return []
            }

            state.isPinned = true
            var effects = setQuotaPause(.panelInteraction, active: true, state: &state, now: now)
            state.interactionGeneration = state.interactionGeneration.advanced()
            state.pendingPanelDeadline = nil
            effects += [.cancelTimer(.hoverExpansion), .cancelTimer(.hoverCollapse)]
            if state.panelPhase != .expanded {
                state.panelPhase = .expanded
                effects += submitPanelIfPossible(
                    state: &state,
                    expanded: true,
                    animated: true,
                    duration: configuration.expansionDuration,
                    curve: .easeOut
                )
            }
            return effects

        case let .selectTask(direction):
            guard !state.tasks.isEmpty else { return [] }
            let currentIndex = state.selectedTaskIndex ?? 0
            let nextIndex: Int
            switch direction {
            case .previous:
                nextIndex = (currentIndex - 1 + state.tasks.count) % state.tasks.count
            case .next:
                nextIndex = (currentIndex + 1) % state.tasks.count
            }
            state.selectedTaskID = state.tasks[nextIndex].id
            return []

        case let .placementPreferenceChanged(preference):
            guard preference != state.placementPreference else { return [] }
            state.placementPreference = preference
            state.isAwaitingRehostLayout = true
            var effects = beginRehost(state: &state, now: now)
            effects.append(.requestPanelLayout(preference))
            return effects

        case let .panelLayoutUpdated(layout):
            guard let layout else {
                state.panelLayout = nil
                return setQuotaPause(.screenUnavailable, active: true, state: &state, now: now)
            }

            var effects = setQuotaPause(.screenUnavailable, active: false, state: &state, now: now)
            let needsRehost = state.isAwaitingRehostLayout || state.panelLayout != layout
            state.panelLayout = layout
            state.resolvedPlacement = layout.placement
            guard needsRehost else { return effects }

            if !state.quotaPauseReasons.contains(.windowRehosting) {
                effects += setQuotaPause(.windowRehosting, active: true, state: &state, now: now)
            }
            state.isAwaitingRehostLayout = false
            state.panelPhase = .collapsed
            state.isPinned = false
            state.interactionGeneration = state.interactionGeneration.advanced()
            state.pendingPanelDeadline = nil
            effects += [.cancelTimer(.hoverExpansion), .cancelTimer(.hoverCollapse)]
            effects += submitPanelIfPossible(
                state: &state,
                expanded: false,
                animated: false,
                duration: .zero,
                curve: .easeIn
            )
            if !state.quotaPauseReasons.contains(.panelInteraction) {
                return effects
            }
            effects += setQuotaPause(.panelInteraction, active: false, state: &state, now: now)
            return effects

        case let .panelTransitionCompleted(revision):
            guard revision == state.panelRevision else { return [] }
            var effects: [IslandEffect] = []
            if !state.isAwaitingRehostLayout {
                effects += setQuotaPause(.windowRehosting, active: false, state: &state, now: now)
            }
            if state.panelPhase == .collapsed, !state.isPointerInside, !state.isPinned {
                effects += setQuotaPause(.panelInteraction, active: false, state: &state, now: now)
            }
            return effects

        case let .setQuotaPause(reason, active):
            return setQuotaPause(reason, active: active, state: &state, now: now)

        case let .terminalErrorTimerFired(token):
            guard
                token == state.terminalErrorGeneration,
                let latch = state.terminalErrorLatch,
                latch.generation == token
            else { return [] }
            if now < latch.expiresAt {
                return [.scheduleTimer(.terminalError, token: token, after: now.duration(to: latch.expiresAt))]
            }
            state.terminalErrorLatch = nil
            return []

        case .refreshQuota:
            return [.refreshQuota]
        }
    }

    private mutating func handlePointerEntry(
        state: inout IslandState,
        now: MonotonicInstant
    ) -> [IslandEffect] {
        var effects = setQuotaPause(.panelInteraction, active: true, state: &state, now: now)
        switch state.panelPhase {
        case .collapsed:
            state.panelPhase = .expandPending
            state.interactionGeneration = state.interactionGeneration.advanced()
            state.pendingPanelDeadline = now.advanced(by: configuration.hoverExpansionDelay)
            effects += [
                .cancelTimer(.hoverCollapse),
                .scheduleTimer(
                    .hoverExpansion,
                    token: state.interactionGeneration,
                    after: configuration.hoverExpansionDelay
                ),
            ]
        case .collapsePending:
            state.panelPhase = .expanded
            state.interactionGeneration = state.interactionGeneration.advanced()
            state.pendingPanelDeadline = nil
            effects.append(.cancelTimer(.hoverCollapse))
        case .expandPending, .expanded:
            break
        }
        return effects
    }

    private mutating func handlePointerExit(
        state: inout IslandState,
        now: MonotonicInstant
    ) -> [IslandEffect] {
        guard !state.isPinned else { return [] }
        switch state.panelPhase {
        case .expandPending:
            state.panelPhase = .collapsed
            state.interactionGeneration = state.interactionGeneration.advanced()
            state.pendingPanelDeadline = nil
            var effects: [IslandEffect] = [.cancelTimer(.hoverExpansion)]
            effects += setQuotaPause(.panelInteraction, active: false, state: &state, now: now)
            return effects
        case .expanded:
            return scheduleCollapse(state: &state, now: now)
        case .collapsed:
            return setQuotaPause(.panelInteraction, active: false, state: &state, now: now)
        case .collapsePending:
            return []
        }
    }

    private mutating func scheduleCollapse(
        state: inout IslandState,
        now: MonotonicInstant
    ) -> [IslandEffect] {
        state.panelPhase = .collapsePending
        state.interactionGeneration = state.interactionGeneration.advanced()
        state.pendingPanelDeadline = now.advanced(by: configuration.hoverCollapseDelay)
        return [
            .cancelTimer(.hoverExpansion),
            .scheduleTimer(
                .hoverCollapse,
                token: state.interactionGeneration,
                after: configuration.hoverCollapseDelay
            ),
        ]
    }

    private mutating func beginRehost(
        state: inout IslandState,
        now: MonotonicInstant
    ) -> [IslandEffect] {
        var effects = setQuotaPause(.windowRehosting, active: true, state: &state, now: now)
        state.panelPhase = .collapsed
        state.isPinned = false
        state.interactionGeneration = state.interactionGeneration.advanced()
        state.pendingPanelDeadline = nil
        // Invalidate every callback from the old host before asking for new geometry.
        state.panelRevision = state.panelRevision.advanced()
        effects += [.cancelTimer(.hoverExpansion), .cancelTimer(.hoverCollapse)]
        effects += setQuotaPause(.panelInteraction, active: false, state: &state, now: now)
        return effects
    }

    private mutating func submitPanelIfPossible(
        state: inout IslandState,
        expanded: Bool,
        animated: Bool,
        duration: Duration,
        curve: PanelAnimationCurve
    ) -> [IslandEffect] {
        guard let layout = state.panelLayout else { return [] }
        state.panelRevision = state.panelRevision.advanced()
        let frame = expanded ? layout.expandedFrame : layout.collapsedFrame
        return [
            .submitPanel(
                PanelTransition(
                    revision: state.panelRevision,
                    frame: frame,
                    animated: animated,
                    duration: duration,
                    curve: curve
                )
            ),
        ]
    }

    private mutating func reduceTaskSourceEvent(
        _ event: TaskSourceEvent,
        state: inout IslandState,
        now: MonotonicInstant
    ) -> [IslandEffect] {
        switch event {
        case let .snapshot(tasks):
            let previousSelection = state.selectedTaskID
            state.tasks = tasks
            if let previousSelection, tasks.contains(where: { $0.id == previousSelection }) {
                state.selectedTaskID = previousSelection
            } else {
                state.selectedTaskID = tasks.first?.id
            }
            return []

        case let .healthChanged(health):
            state.taskSourceHealth = health
            return []

        case let .terminalError(taskID):
            state.terminalErrorGeneration = state.terminalErrorGeneration.advanced()
            let token = state.terminalErrorGeneration
            let expiresAt = now.advanced(by: configuration.terminalErrorDuration)
            state.terminalErrorLatch = TerminalErrorLatch(
                taskID: taskID,
                expiresAt: expiresAt,
                generation: token
            )
            return [
                .cancelTimer(.terminalError),
                .scheduleTimer(.terminalError, token: token, after: configuration.terminalErrorDuration),
            ]

        case .lifecycleActivity:
            guard state.terminalErrorLatch != nil else { return [] }
            state.terminalErrorLatch = nil
            state.terminalErrorGeneration = state.terminalErrorGeneration.advanced()
            return [.cancelTimer(.terminalError)]
        }
    }

    private mutating func setQuotaPause(
        _ reason: QuotaPauseReason,
        active: Bool,
        state: inout IslandState,
        now: MonotonicInstant
    ) -> [IslandEffect] {
        if active {
            guard state.quotaPauseReasons.insert(reason).inserted else { return [] }
            guard state.quotaPauseReasons.count == 1 else { return [] }
            if let runningSince = state.quotaRotation.runningSince {
                let elapsed = runningSince.duration(to: now)
                state.quotaRotation.remaining = nonnegative(state.quotaRotation.remaining - elapsed)
                state.quotaRotation.runningSince = nil
            }
            state.quotaRotation.generation = state.quotaRotation.generation.advanced()
            return [.cancelTimer(.quotaRotation)]
        }

        guard state.quotaPauseReasons.remove(reason) != nil else { return [] }
        return resumeQuotaRotationIfPossible(state: &state, now: now)
    }

    private mutating func resumeQuotaRotationIfPossible(
        state: inout IslandState,
        now: MonotonicInstant
    ) -> [IslandEffect] {
        guard
            state.isStarted,
            state.quotaPauseReasons.isEmpty,
            state.quotaRotation.runningSince == nil
        else { return [] }

        state.quotaRotation.runningSince = now
        state.quotaRotation.generation = state.quotaRotation.generation.advanced()
        return [
            .scheduleTimer(
                .quotaRotation,
                token: state.quotaRotation.generation,
                after: state.quotaRotation.remaining
            ),
        ]
    }

    private func displayDuration(for kind: QuotaKind) -> Duration {
        switch kind {
        case .fiveHour: configuration.fiveHourDisplayDuration
        case .weekly: configuration.weeklyDisplayDuration
        }
    }

    private func nonnegative(_ duration: Duration) -> Duration {
        duration < .zero ? .zero : duration
    }
}

private extension IslandTimer {
    static let all: [IslandTimer] = [
        .quotaRotation,
        .hoverExpansion,
        .hoverCollapse,
        .terminalError,
    ]
}
