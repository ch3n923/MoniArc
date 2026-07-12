import Foundation

/// Read-only quota source backed by a private, dedicated `codex app-server --stdio` process.
/// It never reads auth files and never invokes account mutation or thread-control methods.
actor CodexAppServerQuotaSource: QuotaSource {
    private let configuration: CodexQuotaSourceConfiguration

    private var eventContinuation: AsyncStream<QuotaSourceEvent>.Continuation?
    private var supervisorTask: Task<Void, Never>?
    private var notificationDebounceTask: Task<Void, Never>?
    private var retentionTask: Task<Void, Never>?
    private var activeTransport: CodexAppServerTransport?
    private var latestSnapshot: CodexQuotaPayloadSnapshot?
    private var isStarted = false
    private var connectionGeneration: UInt64 = 0
    private var retentionRevision: UInt64 = 0

    init(configuration: CodexQuotaSourceConfiguration = .live) {
        self.configuration = configuration
    }

    func events() async -> AsyncStream<QuotaSourceEvent> {
        eventContinuation?.finish()
        let pair = AsyncStream<QuotaSourceEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        eventContinuation = pair.continuation
        return pair.stream
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        publish(.healthChanged(.disconnected))
        supervisorTask = Task { [weak self] in
            await self?.superviseConnections()
        }
    }

    func stop() async {
        guard isStarted else { return }
        isStarted = false
        supervisorTask?.cancel()
        supervisorTask = nil
        notificationDebounceTask?.cancel()
        notificationDebounceTask = nil
        retentionTask?.cancel()
        retentionTask = nil
        retentionRevision &+= 1

        if let activeTransport {
            await activeTransport.shutdown()
        }
        activeTransport = nil
        publish(.healthChanged(.disconnected))
    }

    func refresh() async {
        guard let activeTransport else { return }
        do {
            try await readAndPublishRateLimits(from: activeTransport)
        } catch {
            markLatestSnapshotStale()
            await activeTransport.shutdown()
        }
    }

    private func superviseConnections() async {
        var retryIndex = 0

        while isStarted, !Task.isCancelled {
            guard let executableURL = CodexBinaryResolver.resolve(
                override: configuration.binaryOverride,
                environment: configuration.environment
            ) else {
                publish(.healthChanged(.failed))
                guard await waitBeforeRetry(index: retryIndex) else { break }
                retryIndex = min(retryIndex + 1, maximumRetryIndex)
                continue
            }

            connectionGeneration &+= 1
            let generation = connectionGeneration
            let transport = CodexAppServerTransport(
                executableURL: executableURL,
                environment: configuration.environment,
                requestTimeout: configuration.requestTimeout
            )
            activeTransport = transport
            let transportEvents = await transport.events()

            do {
                try await transport.connect()
                try await initialize(transport)
                try await readAndPublishRateLimits(from: transport)
                publish(.healthChanged(.connected))
                retryIndex = 0
                try await runConnectedSession(
                    transport: transport,
                    events: transportEvents,
                    generation: generation
                )
                throw CodexQuotaError.transportClosed
            } catch is CancellationError {
                await transport.shutdown()
                break
            } catch {
                await transport.shutdown()
                if activeTransport === transport {
                    activeTransport = nil
                }
                markLatestSnapshotStale()
                publishFailureHealth(for: error)
                guard await waitBeforeRetry(index: retryIndex) else { break }
                retryIndex = min(retryIndex + 1, maximumRetryIndex)
            }
        }

        activeTransport = nil
    }

    private func initialize(_ transport: CodexAppServerTransport) async throws {
        let initializeParams = try jsonData([
            "clientInfo": [
                "name": "moniarc",
                "title": "MoniArc",
                "version": "1.0.0",
            ],
            "capabilities": [
                "experimentalApi": false,
                "requestAttestation": false,
            ],
        ])
        _ = try await transport.request(method: "initialize", params: initializeParams)
        try await transport.notify(method: "initialized")

        let accountParams = try jsonData(["refreshToken": false])
        _ = try await transport.request(method: "account/read", params: accountParams)
    }

    private func runConnectedSession(
        transport: CodexAppServerTransport,
        events: AsyncStream<CodexAppServerTransportEvent>,
        generation: UInt64
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                try await self.pollRateLimits(from: transport)
            }
            group.addTask { [weak self] in
                guard let self else { return }
                await self.consumeTransportEvents(
                    events,
                    transport: transport,
                    generation: generation
                )
            }

            do {
                _ = try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func pollRateLimits(from transport: CodexAppServerTransport) async throws {
        while !Task.isCancelled {
            try await Task.sleep(for: configuration.pollingInterval)
            try Task.checkCancellation()
            try await readAndPublishRateLimits(from: transport)
        }
    }

    private func consumeTransportEvents(
        _ events: AsyncStream<CodexAppServerTransportEvent>,
        transport: CodexAppServerTransport,
        generation: UInt64
    ) async {
        for await event in events {
            if Task.isCancelled { return }
            switch event {
            case let .notification(notification):
                handle(notification, transport: transport, generation: generation)
            case .disconnected:
                markLatestSnapshotStale()
                return
            }
        }
    }

    private func handle(
        _ notification: CodexAppServerNotification,
        transport: CodexAppServerTransport,
        generation: UInt64
    ) {
        guard notification.method == "account/rateLimits/updated" else { return }

        // Notifications can belong to any metered bucket (for example Spark).
        // Treat them only as an invalidation signal; a full read below selects
        // rateLimitsByLimitId["codex"] for the main collapsed quota and also
        // captures the other buckets for the expanded comparison.

        notificationDebounceTask?.cancel()
        let debounce = configuration.sparseNotificationDebounce
        notificationDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            await self?.performDebouncedRefresh(
                transport: transport,
                generation: generation
            )
        }
    }

    private func performDebouncedRefresh(
        transport: CodexAppServerTransport,
        generation: UInt64
    ) async {
        guard
            isStarted,
            connectionGeneration == generation,
            activeTransport === transport
        else {
            return
        }

        do {
            try await readAndPublishRateLimits(from: transport)
        } catch {
            markLatestSnapshotStale()
            await transport.shutdown()
        }
    }

    private func readAndPublishRateLimits(
        from transport: CodexAppServerTransport
    ) async throws {
        let response = try await transport.request(method: "account/rateLimits/read")
        let snapshot = try CodexRateLimitsParser.parseResponse(
            response,
            receivedAt: configuration.now(),
            maximumStaleAge: configuration.maximumStaleAge,
            resetGracePeriod: configuration.resetGracePeriod
        )
        latestSnapshot = snapshot
        retentionRevision &+= 1
        retentionTask?.cancel()
        retentionTask = nil
        publishDomainSnapshot(snapshot)
    }

    private func markLatestSnapshotStale() {
        guard let latestSnapshot else {
            publish(.healthChanged(.disconnected))
            return
        }

        let stale = latestSnapshot.markedStale(at: configuration.now())
        self.latestSnapshot = stale
        publishDomainSnapshot(stale)
        if stale.hasKnownWindow {
            publish(.healthChanged(.stale))
            scheduleRetentionExpiry(for: stale)
        } else {
            publish(.healthChanged(.disconnected))
        }
    }

    private func scheduleRetentionExpiry(for snapshot: CodexQuotaPayloadSnapshot) {
        retentionRevision &+= 1
        let revision = retentionRevision
        retentionTask?.cancel()

        guard let deadline = snapshot.nextRetentionDeadline else {
            retentionTask = nil
            return
        }

        let interval = max(0, deadline.timeIntervalSince(configuration.now()))
        retentionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            await self?.expireRetainedValues(revision: revision)
        }
    }

    private func expireRetainedValues(revision: UInt64) {
        guard
            retentionRevision == revision,
            let snapshot = latestSnapshot,
            snapshot.isStale
        else {
            return
        }

        let expired = snapshot.markedStale(at: configuration.now())
        latestSnapshot = expired
        publishDomainSnapshot(expired)
        if expired.hasKnownWindow {
            publish(.healthChanged(.stale))
            scheduleRetentionExpiry(for: expired)
        } else {
            publish(.healthChanged(.disconnected))
        }
    }

    private var maximumRetryIndex: Int {
        max(0, configuration.reconnectDelays.count - 1)
    }

    private func waitBeforeRetry(index: Int) async -> Bool {
        guard isStarted, !Task.isCancelled else { return false }
        let delays = configuration.reconnectDelays
        let delay = delays.isEmpty ? Duration.seconds(30) : delays[min(index, delays.count - 1)]
        do {
            try await Task.sleep(for: delay)
            return isStarted && !Task.isCancelled
        } catch {
            return false
        }
    }

    private func publishFailureHealth(for error: Error) {
        if let quotaError = error as? CodexQuotaError {
            switch quotaError {
            case .malformedMessage, .missingRateLimits, .noRecognizedWindow:
                publish(.healthChanged(.incompatible))
            default:
                if latestSnapshot?.hasKnownWindow == true {
                    publish(.healthChanged(.stale))
                } else {
                    publish(.healthChanged(.failed))
                }
            }
        } else if latestSnapshot?.hasKnownWindow == true {
            publish(.healthChanged(.stale))
        } else {
            publish(.healthChanged(.failed))
        }
    }

    private func publishDomainSnapshot(_ snapshot: CodexQuotaPayloadSnapshot) {
        publish(.snapshot(QuotaSnapshot(
            fiveHour: snapshot.fiveHour.map {
                QuotaWindow(
                    kind: .fiveHour,
                    remainingPercent: $0.remainingPercent,
                    resetsAt: $0.resetsAt,
                    isStale: $0.isStale
                )
            },
            weekly: snapshot.weekly.map {
                QuotaWindow(
                    kind: .weekly,
                    remainingPercent: $0.remainingPercent,
                    resetsAt: $0.resetsAt,
                    isStale: $0.isStale
                )
            },
            additionalBuckets: snapshot.additionalBuckets.map { bucket in
                QuotaBucket(
                    id: bucket.id,
                    displayName: bucket.displayName,
                    fiveHour: bucket.fiveHour.map {
                        QuotaWindow(
                            kind: .fiveHour,
                            remainingPercent: $0.remainingPercent,
                            resetsAt: $0.resetsAt,
                            isStale: $0.isStale
                        )
                    },
                    weekly: bucket.weekly.map {
                        QuotaWindow(
                            kind: .weekly,
                            remainingPercent: $0.remainingPercent,
                            resetsAt: $0.resetsAt,
                            isStale: $0.isStale
                        )
                    }
                )
            },
            receivedAt: snapshot.receivedAt
        )))
    }

    private func publish(_ event: QuotaSourceEvent) {
        eventContinuation?.yield(event)
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            throw CodexQuotaError.malformedMessage
        }
        return data
    }
}
