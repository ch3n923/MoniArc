import Foundation

struct CodexAppServerNotification: Sendable, Equatable {
    let method: String
    /// JSON-encoded params only. The transport never logs or persists it.
    let params: Data
}

enum CodexAppServerTransportEvent: Sendable, Equatable {
    case notification(CodexAppServerNotification)
    case disconnected
}

actor CodexAppServerTransport {
    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let executableURL: URL
    private let environment: [String: String]
    private let requestTimeout: Duration
    private let maximumBufferedBytes = 4 * 1_024 * 1_024

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var receiveBuffer = Data()
    private var nextRequestID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var eventContinuation: AsyncStream<CodexAppServerTransportEvent>.Continuation?
    private var isConnected = false
    private var isStopping = false

    init(
        executableURL: URL,
        environment: [String: String],
        requestTimeout: Duration
    ) {
        self.executableURL = executableURL
        self.environment = environment
        self.requestTimeout = requestTimeout
    }

    func events() -> AsyncStream<CodexAppServerTransportEvent> {
        eventContinuation?.finish()

        var captured: AsyncStream<CodexAppServerTransportEvent>.Continuation?
        let stream = AsyncStream<CodexAppServerTransportEvent>(bufferingPolicy: .bufferingNewest(32)) {
            captured = $0
        }
        eventContinuation = captured
        return stream
    }

    func connect() throws {
        guard !isConnected else { return }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        outputHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            Task { await self?.received(chunk) }
        }
        // stderr must be drained to prevent back-pressure, but is deliberately never logged.
        errorHandle.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.processDidTerminate() }
        }

        do {
            try process.run()
        } catch {
            outputHandle.readabilityHandler = nil
            errorHandle.readabilityHandler = nil
            throw CodexQuotaError.processLaunchFailed
        }

        self.process = process
        inputHandle = inputPipe.fileHandleForWriting
        self.outputHandle = outputHandle
        self.errorHandle = errorHandle
        receiveBuffer.removeAll(keepingCapacity: true)
        isStopping = false
        isConnected = true
    }

    func request(method: String, params: Data? = nil) async throws -> Data {
        guard isConnected, let inputHandle else {
            throw CodexQuotaError.transportClosed
        }

        let requestID = nextRequestID
        nextRequestID += 1
        let encoded = try encodeMessage(id: requestID, method: method, params: params)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: self?.requestTimeout ?? .seconds(10))
                    } catch {
                        return
                    }
                    await self?.timeoutRequest(requestID)
                }
                pending[requestID] = PendingRequest(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )

                do {
                    try inputHandle.write(contentsOf: encoded)
                } catch {
                    finishRequest(requestID, with: .failure(CodexQuotaError.transportClosed))
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(requestID) }
        }
    }

    func notify(method: String, params: Data? = nil) throws {
        guard isConnected, let inputHandle else {
            throw CodexQuotaError.transportClosed
        }
        let encoded = try encodeMessage(id: nil, method: method, params: params)
        do {
            try inputHandle.write(contentsOf: encoded)
        } catch {
            throw CodexQuotaError.transportClosed
        }
    }

    func shutdown() {
        guard process != nil || isConnected else {
            eventContinuation?.finish()
            eventContinuation = nil
            return
        }

        isStopping = true
        isConnected = false
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        try? inputHandle?.close()
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil

        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        failAllPending(with: CodexQuotaError.transportClosed)
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private func received(_ chunk: Data) {
        guard isConnected else { return }
        guard !chunk.isEmpty else {
            handleDisconnect()
            return
        }

        receiveBuffer.append(chunk)
        if receiveBuffer.count > maximumBufferedBytes,
           receiveBuffer.firstIndex(of: 0x0A) == nil
        {
            receiveBuffer.removeAll(keepingCapacity: false)
            return
        }

        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            var line = receiveBuffer[..<newline]
            receiveBuffer.removeSubrange(...newline)
            if line.last == 0x0D {
                line = line.dropLast()
            }
            guard !line.isEmpty else { continue }
            handleLine(Data(line))
        }
    }

    private func handleLine(_ line: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: line),
            let message = object as? [String: Any]
        else {
            // A malformed line cannot be correlated safely. Ignore it and keep the stream alive.
            return
        }

        if let requestID = integerID(message["id"]), pending[requestID] != nil {
            if let error = message["error"] as? [String: Any] {
                let code = numericInteger(error["code"])
                finishRequest(requestID, with: .failure(CodexQuotaError.rpcError(code: code)))
                return
            }

            guard let result = message["result"] else {
                finishRequest(requestID, with: .failure(CodexQuotaError.malformedMessage))
                return
            }

            guard let resultData = try? JSONSerialization.data(
                withJSONObject: result,
                options: [.fragmentsAllowed]
            ) else {
                finishRequest(requestID, with: .failure(CodexQuotaError.malformedMessage))
                return
            }
            finishRequest(requestID, with: .success(resultData))
            return
        }

        guard let method = message["method"] as? String else { return }
        let params = message["params"] ?? [String: Any]()
        guard let paramsData = try? JSONSerialization.data(
            withJSONObject: params,
            options: [.fragmentsAllowed]
        ) else {
            return
        }
        eventContinuation?.yield(.notification(
            CodexAppServerNotification(method: method, params: paramsData)
        ))
    }

    private func encodeMessage(id: Int?, method: String, params: Data?) throws -> Data {
        var message: [String: Any] = ["method": method]
        if let id {
            message["id"] = id
        }
        if let params {
            guard let object = try? JSONSerialization.jsonObject(with: params) else {
                throw CodexQuotaError.malformedMessage
            }
            message["params"] = object
        }

        guard var data = try? JSONSerialization.data(withJSONObject: message) else {
            throw CodexQuotaError.malformedMessage
        }
        data.append(0x0A)
        return data
    }

    private func finishRequest(_ id: Int, with result: Result<Data, Error>) {
        guard let pending = pending.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        switch result {
        case let .success(data):
            pending.continuation.resume(returning: data)
        case let .failure(error):
            pending.continuation.resume(throwing: error)
        }
    }

    private func timeoutRequest(_ id: Int) {
        finishRequest(id, with: .failure(CodexQuotaError.requestTimedOut))
    }

    private func cancelRequest(_ id: Int) {
        finishRequest(id, with: .failure(CodexQuotaError.requestCancelled))
    }

    private func processDidTerminate() {
        handleDisconnect()
    }

    private func handleDisconnect() {
        guard isConnected else { return }
        isConnected = false
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        process = nil
        failAllPending(with: CodexQuotaError.transportClosed)
        if !isStopping {
            eventContinuation?.yield(.disconnected)
        }
        eventContinuation?.finish()
    }

    private func failAllPending(with error: Error) {
        let requests = pending
        pending.removeAll(keepingCapacity: true)
        for request in requests.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func integerID(_ value: Any?) -> Int? {
        numericInteger(value)
    }

    private func numericInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }
}
