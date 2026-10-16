import Foundation

/// Finds the App Sandbox. A sandboxed app cannot run the vendor CLIs.
enum SandboxCheck {
    static func isSandboxed(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
}
