import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: ApplicationRuntime?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Host-based XCTest launches the app executable. Starting real App Server,
        // FSEvents and a status-bar panel there can keep the test host alive and
        // contaminate read-only fixture tests.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil {
            return
        }
        let isHarness = ProcessInfo.processInfo.arguments.contains("--harness")
        let runtime = ApplicationRuntime(isHarness: isHarness)
        self.runtime = runtime
        runtime.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
