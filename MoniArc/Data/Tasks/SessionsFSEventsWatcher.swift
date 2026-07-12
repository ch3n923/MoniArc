import CoreServices
import Foundation

enum SessionsFSEventsWatcherError: Error, Equatable, Sendable {
    case directoryUnavailable
    case streamCreationFailed
    case streamStartFailed
}

final class SessionsFSEventsWatcher: @unchecked Sendable {
    private final class CallbackBox: @unchecked Sendable {
        let handler: @Sendable () -> Void

        init(handler: @escaping @Sendable () -> Void) {
            self.handler = handler
        }
    }

    private let queue = DispatchQueue(label: "com.zhengzipeng.moniarc.task-fsevents")
    private let callbackBox: CallbackBox
    private var stream: FSEventStreamRef?

    init(
        directoryURL: URL,
        latency: TimeInterval = 0.3,
        handler: @escaping @Sendable () -> Void
    ) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SessionsFSEventsWatcherError.directoryUnavailable
        }

        let callbackBox = CallbackBox(handler: handler)
        self.callbackBox = callbackBox

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [directoryURL.path] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, contextInfo, _, _, _, _ in
                guard let contextInfo else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(contextInfo).takeUnretainedValue()
                box.handler()
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            throw SessionsFSEventsWatcherError.streamCreationFailed
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            throw SessionsFSEventsWatcherError.streamStartFailed
        }
    }

    deinit {
        stop()
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
