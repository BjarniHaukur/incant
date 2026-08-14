import AppKit

@main
struct IncantMain {
    // NSApplication.delegate is weak. Keep the delegate alive for the entire
    // process lifetime or release builds can exit immediately after launch.
    @MainActor private static let appDelegate = AppDelegate()

    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.delegate = appDelegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
