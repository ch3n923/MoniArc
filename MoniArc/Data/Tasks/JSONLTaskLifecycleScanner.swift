import Foundation

struct JSONLTaskLifecycleScanner: Sendable {
    private let decoder = LifecycleEnvelopeDecoder()

    func scan(
        fileURL: URL,
        byteLimit requestedLimit: Int,
        fallbackProfile: TaskLightingProfile = .fallback
    ) throws -> TaskLifecycleScanResult {
        let byteLimit = max(1, min(requestedLimit, CodexTaskObserverConfiguration.defaultPerFileByteLimit))
        let read = try BoundedJSONLTailReader.read(fileURL: fileURL, byteLimit: byteLimit)

        var state: TaskLifecycleState?
        var lightingProfile = fallbackProfile
        var pendingUserInputCalls = Set<String>()
        var recognizedEnvelopeCount = 0
        var recognizedLifecycleCount = 0
        var latestTerminalErrorOffset: UInt64?
        var latestResetActivityOffset: UInt64?

        for line in read.lines {
            guard let event = decoder.decode(line.data) else {
                continue
            }
            recognizedEnvelopeCount += 1

            switch event {
            case let .lightingSettings(patch):
                patch.apply(to: &lightingProfile)

            case .taskStarted:
                state = .running
                pendingUserInputCalls.removeAll(keepingCapacity: true)
                latestResetActivityOffset = line.absoluteOffset
                recognizedLifecycleCount += 1

            case .taskActivity:
                if state == nil {
                    state = .running
                }
                latestResetActivityOffset = line.absoluteOffset
                recognizedLifecycleCount += 1

            case let .requestUserInput(callID):
                state = .waitingForUser
                if let callID {
                    pendingUserInputCalls.insert(callID)
                }
                latestResetActivityOffset = line.absoluteOffset
                recognizedLifecycleCount += 1

            case let .toolOutput(callID):
                let matchedPendingInput = callID.map { pendingUserInputCalls.remove($0) != nil } ?? false
                if matchedPendingInput, pendingUserInputCalls.isEmpty {
                    state = .running
                } else if state == nil {
                    // A bounded tail may begin after task_started. A tool output
                    // still proves that this turn is active unless a later
                    // terminal event clears it.
                    state = .running
                }
                latestResetActivityOffset = line.absoluteOffset
                recognizedLifecycleCount += 1

            case .taskCompleted:
                state = nil
                pendingUserInputCalls.removeAll(keepingCapacity: true)
                recognizedLifecycleCount += 1

            case .explicitError:
                state = .error
                pendingUserInputCalls.removeAll(keepingCapacity: true)
                latestTerminalErrorOffset = line.absoluteOffset
                recognizedLifecycleCount += 1

            case .interrupted:
                state = nil
                pendingUserInputCalls.removeAll(keepingCapacity: true)
                recognizedLifecycleCount += 1

            case .compatibleButIrrelevant:
                continue
            }
        }

        return TaskLifecycleScanResult(
            activeState: state,
            lightingProfile: lightingProfile,
            bytesRead: read.bytesRead,
            recognizedEnvelopeCount: recognizedEnvelopeCount,
            recognizedLifecycleCount: recognizedLifecycleCount,
            latestTerminalErrorOffset: latestTerminalErrorOffset,
            latestResetActivityOffset: latestResetActivityOffset
        )
    }
}

private struct BoundedJSONLLine {
    let data: Data
    let absoluteOffset: UInt64
}

private struct BoundedJSONLTailReader {
    let lines: [BoundedJSONLLine]
    let bytesRead: Int

    static func read(fileURL: URL, byteLimit: Int) throws -> BoundedJSONLTailReader {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        let requested = UInt64(max(1, byteLimit))
        let offset = fileSize > requested ? fileSize - requested : 0
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: Int(min(requested, fileSize))) ?? Data()

        var completeTail = data
        var completeTailOffset = offset
        if offset > 0 {
            guard let firstLineBreak = completeTail.firstIndex(of: 0x0A) else {
                return BoundedJSONLTailReader(lines: [], bytesRead: data.count)
            }
            let firstCompleteIndex = completeTail.index(after: firstLineBreak)
            completeTailOffset += UInt64(completeTail.distance(from: completeTail.startIndex, to: firstCompleteIndex))
            completeTail = Data(completeTail[firstCompleteIndex...])
        }

        var lines: [BoundedJSONLLine] = []
        var lineStart = completeTail.startIndex
        for index in completeTail.indices where completeTail[index] == 0x0A {
            if lineStart < index {
                let relativeOffset = UInt64(
                    completeTail.distance(from: completeTail.startIndex, to: lineStart)
                )
                lines.append(
                    BoundedJSONLLine(
                        data: Data(completeTail[lineStart..<index]),
                        absoluteOffset: completeTailOffset + relativeOffset
                    )
                )
            }
            lineStart = completeTail.index(after: index)
        }
        if lineStart < completeTail.endIndex {
            let relativeOffset = UInt64(
                completeTail.distance(from: completeTail.startIndex, to: lineStart)
            )
            lines.append(
                BoundedJSONLLine(
                    data: Data(completeTail[lineStart..<completeTail.endIndex]),
                    absoluteOffset: completeTailOffset + relativeOffset
                )
            )
        }
        return BoundedJSONLTailReader(lines: lines, bytesRead: data.count)
    }
}

private enum LifecycleEnvelopeEvent {
    case lightingSettings(TaskLightingProfilePatch)
    case taskStarted
    case taskActivity
    case requestUserInput(callID: String?)
    case toolOutput(callID: String?)
    case taskCompleted
    case explicitError
    case interrupted
    case compatibleButIrrelevant
}

private struct TaskLightingProfilePatch {
    var theme: TaskLightingTheme?
    var speed: TaskSpeedMode?
    var prefersHDR: Bool?

    func apply(to profile: inout TaskLightingProfile) {
        if let theme { profile.theme = theme }
        if let speed { profile.speed = speed }
        if let prefersHDR { profile.prefersHDR = prefersHDR }
    }
}

/// Decodes only routing and lifecycle keys. Unknown JSON members (including
/// messages, prompts, code, arguments and tool outputs) are never retained.
private struct LifecycleEnvelopeDecoder: Sendable {
    func decode(_ data: Data) -> LifecycleEnvelopeEvent? {
        guard let envelope = try? JSONDecoder().decode(LifecycleEnvelope.self, from: data) else {
            return nil
        }

        let envelopeType = Self.normalize(envelope.type)
        if envelopeType == "turncontext" {
            return .lightingSettings(Self.lightingPatch(
                model: envelope.payload.model,
                serviceTier: envelope.payload.serviceTier,
                reasoningEffort: envelope.payload.effort ?? envelope.payload.reasoningEffort
            ))
        }

        guard envelopeType == "eventmsg" || envelopeType == "responseitem" else {
            return nil
        }

        let payloadType = Self.normalize(envelope.payload.type)
        let status = Self.normalize(envelope.payload.status)

        if envelopeType == "eventmsg" {
            switch payloadType {
            case "threadsettingsapplied":
                guard let settings = envelope.payload.threadSettings else {
                    return .compatibleButIrrelevant
                }
                return .lightingSettings(Self.lightingPatch(
                    model: settings.model,
                    serviceTier: settings.serviceTier,
                    reasoningEffort: settings.reasoningEffort ?? settings.effort
                ))
            case "taskstarted":
                return .taskStarted
            case "usermessage", "agentreasoning", "agentmessage", "tokencount":
                return .taskActivity
            case "taskcomplete", "taskcompleted":
                return .taskCompleted
            case "error", "systemerror", "failed":
                return .explicitError
            case "turnaborted", "interrupted", "turninterrupted", "cancelled", "canceled":
                return .interrupted
            default:
                if status == "failed" || status == "error" || status == "systemerror" {
                    return .explicitError
                }
                if status == "interrupted" || status == "cancelled" || status == "canceled" {
                    return .interrupted
                }
                return .compatibleButIrrelevant
            }
        }

        switch payloadType {
        case "functioncall", "customtoolcall":
            if Self.normalize(envelope.payload.name) == "requestuserinput" {
                return .requestUserInput(callID: envelope.payload.callID)
            }
            return .taskActivity
        case "functioncalloutput", "customtoolcalloutput":
            return .toolOutput(callID: envelope.payload.callID)
        case "reasoning", "message":
            return .taskActivity
        case "error", "systemerror", "failed":
            return .explicitError
        default:
            if status == "failed" || status == "error" || status == "systemerror" {
                return .explicitError
            }
        }

        return .compatibleButIrrelevant
    }

    private static func normalize(_ value: String?) -> String {
        guard let value else { return "" }
        return value.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
    }

    private static func lightingPatch(
        model: String?,
        serviceTier: String?,
        reasoningEffort: String?
    ) -> TaskLightingProfilePatch {
        TaskLightingProfilePatch(
            theme: model.map(TaskLightingProfile.normalizedTheme),
            speed: serviceTier.map(TaskLightingProfile.normalizedSpeed),
            prefersHDR: reasoningEffort.map(TaskLightingProfile.normalizedHDRPreference)
        )
    }
}

private struct LifecycleEnvelope: Decodable {
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String?
        let name: String?
        let callID: String?
        let status: String?
        let model: String?
        let effort: String?
        let reasoningEffort: String?
        let serviceTier: String?
        let threadSettings: ThreadSettings?

        enum CodingKeys: String, CodingKey {
            case type
            case name
            case callID = "call_id"
            case camelCaseCallID = "callId"
            case id
            case status
            case model
            case effort
            case reasoningEffort = "reasoning_effort"
            case camelCaseReasoningEffort = "reasoningEffort"
            case serviceTier = "service_tier"
            case camelCaseServiceTier = "serviceTier"
            case threadSettings = "thread_settings"
            case camelCaseThreadSettings = "threadSettings"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            effort = try container.decodeIfPresent(String.self, forKey: .effort)
            reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
                ?? container.decodeIfPresent(String.self, forKey: .camelCaseReasoningEffort)
            serviceTier = try container.decodeIfPresent(String.self, forKey: .serviceTier)
                ?? container.decodeIfPresent(String.self, forKey: .camelCaseServiceTier)
            threadSettings = try container.decodeIfPresent(ThreadSettings.self, forKey: .threadSettings)
                ?? container.decodeIfPresent(ThreadSettings.self, forKey: .camelCaseThreadSettings)
            callID = try container.decodeIfPresent(String.self, forKey: .callID)
                ?? container.decodeIfPresent(String.self, forKey: .camelCaseCallID)
                ?? container.decodeIfPresent(String.self, forKey: .id)
        }

        struct ThreadSettings: Decodable {
            let model: String?
            let effort: String?
            let reasoningEffort: String?
            let serviceTier: String?

            enum CodingKeys: String, CodingKey {
                case model
                case effort
                case reasoningEffort = "reasoning_effort"
                case camelCaseReasoningEffort = "reasoningEffort"
                case serviceTier = "service_tier"
                case camelCaseServiceTier = "serviceTier"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                model = try container.decodeIfPresent(String.self, forKey: .model)
                effort = try container.decodeIfPresent(String.self, forKey: .effort)
                reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
                    ?? container.decodeIfPresent(String.self, forKey: .camelCaseReasoningEffort)
                serviceTier = try container.decodeIfPresent(String.self, forKey: .serviceTier)
                    ?? container.decodeIfPresent(String.self, forKey: .camelCaseServiceTier)
            }
        }
    }
}
