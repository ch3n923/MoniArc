import XCTest
@testable import MoniArc

final class IslandReducerTests: XCTestCase {
    private let zero = MonotonicInstant.zero

    func testQuotaRotationUsesExactSixtyAndTenSecondBoundaries() {
        var reducer = IslandReducer()
        var state = IslandState()

        let startEffects = reducer.reduce(state: &state, action: .start, now: zero)
        XCTAssertEqual(state.quotaRotation.visibleKind, .fiveHour)
        XCTAssertTrue(startEffects.contains(
            .scheduleTimer(.quotaRotation, token: state.quotaRotation.generation, after: .seconds(60))
        ))

        let firstToken = state.quotaRotation.generation
        _ = reducer.reduce(
            state: &state,
            action: .quotaRotationTimerFired(firstToken),
            now: zero.advanced(by: .milliseconds(59_999))
        )
        XCTAssertEqual(state.quotaRotation.visibleKind, .fiveHour)
        XCTAssertEqual(state.quotaRotation.remaining, .milliseconds(1))

        let rescheduledToken = state.quotaRotation.generation
        _ = reducer.reduce(
            state: &state,
            action: .quotaRotationTimerFired(rescheduledToken),
            now: zero.advanced(by: .seconds(60))
        )
        XCTAssertEqual(state.quotaRotation.visibleKind, .weekly)
        XCTAssertEqual(state.quotaRotation.remaining, .seconds(10))

        let weeklyToken = state.quotaRotation.generation
        _ = reducer.reduce(
            state: &state,
            action: .quotaRotationTimerFired(weeklyToken),
            now: zero.advanced(by: .seconds(70))
        )
        XCTAssertEqual(state.quotaRotation.visibleKind, .fiveHour)
        XCTAssertEqual(state.quotaRotation.remaining, .seconds(60))
    }

    func testAllPauseReasonsMustClearBeforeQuotaRotationResumes() {
        var reducer = IslandReducer()
        var state = IslandState()
        _ = reducer.reduce(state: &state, action: .start, now: zero)

        _ = reducer.reduce(
            state: &state,
            action: .setQuotaPause(reason: .panelInteraction, active: true),
            now: zero.advanced(by: .seconds(10))
        )
        XCTAssertEqual(state.quotaRotation.remaining, .seconds(50))
        XCTAssertNil(state.quotaRotation.runningSince)

        _ = reducer.reduce(
            state: &state,
            action: .setQuotaPause(reason: .appSuspended, active: true),
            now: zero.advanced(by: .seconds(20))
        )
        _ = reducer.reduce(
            state: &state,
            action: .setQuotaPause(reason: .panelInteraction, active: false),
            now: zero.advanced(by: .seconds(100))
        )
        XCTAssertEqual(state.quotaPauseReasons, [.appSuspended])
        XCTAssertNil(state.quotaRotation.runningSince)
        XCTAssertEqual(state.quotaRotation.remaining, .seconds(50))

        let resumeEffects = reducer.reduce(
            state: &state,
            action: .setQuotaPause(reason: .appSuspended, active: false),
            now: zero.advanced(by: .seconds(200))
        )
        XCTAssertEqual(state.quotaPauseReasons, [])
        XCTAssertEqual(state.quotaRotation.runningSince, zero.advanced(by: .seconds(200)))
        XCTAssertTrue(resumeEffects.contains(
            .scheduleTimer(.quotaRotation, token: state.quotaRotation.generation, after: .seconds(50))
        ))
    }

    func testStaleQuotaAndHoverTokensAreRejected() {
        var reducer = IslandReducer()
        var state = IslandState()
        _ = reducer.reduce(state: &state, action: .start, now: zero)
        let staleQuotaToken = state.quotaRotation.generation

        _ = reducer.reduce(
            state: &state,
            action: .setQuotaPause(reason: .appSuspended, active: true),
            now: zero.advanced(by: .seconds(1))
        )
        let quotaEffects = reducer.reduce(
            state: &state,
            action: .quotaRotationTimerFired(staleQuotaToken),
            now: zero.advanced(by: .seconds(60))
        )
        XCTAssertTrue(quotaEffects.isEmpty)
        XCTAssertEqual(state.quotaRotation.visibleKind, .fiveHour)

        _ = reducer.reduce(state: &state, action: .hoverChanged(true), now: zero)
        let staleHoverToken = state.interactionGeneration
        _ = reducer.reduce(
            state: &state,
            action: .hoverChanged(false),
            now: zero.advanced(by: .milliseconds(100))
        )
        let hoverEffects = reducer.reduce(
            state: &state,
            action: .hoverExpansionTimerFired(staleHoverToken),
            now: zero.advanced(by: .milliseconds(220))
        )
        XCTAssertTrue(hoverEffects.isEmpty)
        XCTAssertEqual(state.panelPhase, .collapsed)
    }

    func testHoverExpansionAndCollapseRespectExactDelays() {
        var reducer = IslandReducer()
        var state = IslandState(panelLayout: Self.floatingLayout)

        _ = reducer.reduce(state: &state, action: .hoverChanged(true), now: zero)
        let expansionToken = state.interactionGeneration
        _ = reducer.reduce(
            state: &state,
            action: .hoverExpansionTimerFired(expansionToken),
            now: zero.advanced(by: .milliseconds(219))
        )
        XCTAssertEqual(state.panelPhase, .expandPending)

        _ = reducer.reduce(
            state: &state,
            action: .hoverExpansionTimerFired(expansionToken),
            now: zero.advanced(by: .milliseconds(220))
        )
        XCTAssertEqual(state.panelPhase, .expanded)

        _ = reducer.reduce(
            state: &state,
            action: .hoverChanged(false),
            now: zero.advanced(by: .milliseconds(220))
        )
        let collapseToken = state.interactionGeneration
        _ = reducer.reduce(
            state: &state,
            action: .hoverCollapseTimerFired(collapseToken),
            now: zero.advanced(by: .milliseconds(569))
        )
        XCTAssertEqual(state.panelPhase, .collapsePending)

        _ = reducer.reduce(
            state: &state,
            action: .hoverCollapseTimerFired(collapseToken),
            now: zero.advanced(by: .milliseconds(570))
        )
        XCTAssertEqual(state.panelPhase, .collapsed)
    }

    func testReturningDuringCollapseGracePeriodDoesNotFlashClosed() {
        var reducer = IslandReducer()
        var state = IslandState(
            panelPhase: .expanded,
            panelLayout: Self.floatingLayout,
            isPointerInside: true
        )
        _ = reducer.reduce(state: &state, action: .hoverChanged(false), now: zero)
        let obsoleteCollapseToken = state.interactionGeneration
        XCTAssertEqual(state.panelPhase, .collapsePending)

        _ = reducer.reduce(
            state: &state,
            action: .hoverChanged(true),
            now: zero.advanced(by: .milliseconds(349))
        )
        XCTAssertEqual(state.panelPhase, .expanded)

        let effects = reducer.reduce(
            state: &state,
            action: .hoverCollapseTimerFired(obsoleteCollapseToken),
            now: zero.advanced(by: .milliseconds(350))
        )
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(state.panelPhase, .expanded)
    }

    func testVisualStatusPriorityIsDisconnectedErrorWaitingRunningIdle() {
        var state = IslandState(
            tasks: [TaskSummary(id: "run", title: "Run", runState: .running)],
            taskSourceHealth: .disconnected,
            terminalErrorLatch: TerminalErrorLatch(
                taskID: nil,
                expiresAt: zero.advanced(by: .seconds(30)),
                generation: GenerationToken(rawValue: 1)
            )
        )
        XCTAssertEqual(state.effectiveStatus, .disconnected)

        state.taskSourceHealth = .connected
        XCTAssertEqual(state.effectiveStatus, .error)

        state.terminalErrorLatch = nil
        state.tasks = [
            TaskSummary(id: "run", title: "Run", runState: .running),
            TaskSummary(id: "wait", title: "Wait", runState: .waitingForUser),
        ]
        XCTAssertEqual(state.effectiveStatus, .waitingForUser)

        state.tasks.removeLast()
        XCTAssertEqual(state.effectiveStatus, .running)

        state.tasks = []
        XCTAssertEqual(state.effectiveStatus, .idle)
    }

    func testTaskSelectionAndQuotaPageSurvivePlacementRehost() {
        var reducer = IslandReducer()
        var state = IslandState(
            placementPreference: .floating,
            resolvedPlacement: .floating,
            panelPhase: .expanded,
            panelLayout: Self.floatingLayout,
            quotaRotation: QuotaRotationState(visibleKind: .weekly, remaining: .seconds(7))
        )
        let tasks = [
            TaskSummary(id: "one", title: "One", runState: .running),
            TaskSummary(id: "two", title: "Two", runState: .waitingForUser),
            TaskSummary(id: "three", title: "Three", runState: .running),
        ]
        _ = reducer.reduce(
            state: &state,
            action: .taskSourceEvent(.snapshot(tasks)),
            now: zero
        )
        _ = reducer.reduce(state: &state, action: .selectTask(.next), now: zero)
        XCTAssertEqual(state.selectedTaskID, "two")

        _ = reducer.reduce(
            state: &state,
            action: .placementPreferenceChanged(.overlay),
            now: zero
        )
        XCTAssertEqual(state.panelPhase, .collapsed)
        _ = reducer.reduce(
            state: &state,
            action: .panelLayoutUpdated(Self.overlayLayout),
            now: zero.advanced(by: .milliseconds(1))
        )

        XCTAssertEqual(state.resolvedPlacement, .overlay)
        XCTAssertEqual(state.selectedTaskID, "two")
        XCTAssertEqual(state.quotaRotation.visibleKind, .weekly)
        XCTAssertEqual(state.quotaRotation.remaining, .seconds(7))
    }

    func testTerminalErrorExpiresAtThirtySecondsOrClearsOnLifecycleActivity() {
        var reducer = IslandReducer()
        var state = IslandState(taskSourceHealth: .connected)
        _ = reducer.reduce(
            state: &state,
            action: .taskSourceEvent(.terminalError(
                taskID: "task",
                taskUpdatedAt: nil,
                lightingProfile: .fallback
            )),
            now: zero
        )
        let firstToken = state.terminalErrorGeneration
        _ = reducer.reduce(
            state: &state,
            action: .terminalErrorTimerFired(firstToken),
            now: zero.advanced(by: .milliseconds(29_999))
        )
        XCTAssertNotNil(state.terminalErrorLatch)
        _ = reducer.reduce(
            state: &state,
            action: .terminalErrorTimerFired(firstToken),
            now: zero.advanced(by: .seconds(30))
        )
        XCTAssertNil(state.terminalErrorLatch)

        _ = reducer.reduce(
            state: &state,
            action: .taskSourceEvent(.terminalError(
                taskID: "task",
                taskUpdatedAt: nil,
                lightingProfile: .fallback
            )),
            now: zero.advanced(by: .seconds(31))
        )
        XCTAssertNotNil(state.terminalErrorLatch)
        _ = reducer.reduce(
            state: &state,
            action: .taskSourceEvent(.lifecycleActivity(taskID: "task")),
            now: zero.advanced(by: .seconds(32))
        )
        XCTAssertNil(state.terminalErrorLatch)
    }

    private static let floatingLayout = PanelLayoutSnapshot(
        placement: .floating,
        collapsedFrame: PanelFrame(x: 604, y: 900, width: 304, height: 32),
        expandedFrame: PanelFrame(x: 604, y: 824, width: 304, height: 108)
    )

    private static let overlayLayout = PanelLayoutSnapshot(
        placement: .overlay,
        collapsedFrame: PanelFrame(x: 604, y: 950, width: 304, height: 32),
        expandedFrame: PanelFrame(x: 604, y: 842, width: 304, height: 140),
        notchFrame: PanelFrame(x: 663.5, y: 950, width: 185, height: 32)
    )
}
