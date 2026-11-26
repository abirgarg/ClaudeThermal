import AppKit
import ServiceManagement
import UserNotifications

/// True when running from a signed .app bundle. Notifications and SMAppService
/// require one; the raw `swift run` binary skips them instead of crashing.
let isRunningFromAppBundle: Bool = {
    Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
}()

// MARK: - Launch at Login

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var statusNote: String?
    let isAvailable = isRunningFromAppBundle

    init() {
        reRegisterIfMoved()
        refresh()
    }

    /// The login item points at the bundle path it was registered from. If the app has
    /// moved (e.g. build/ → /Applications), register again so login launches this copy.
    private func reRegisterIfMoved() {
        guard isAvailable else { return }
        let key = "loginItem.registeredPath"
        let path = Bundle.main.bundlePath
        let defaults = UserDefaults.standard
        guard SMAppService.mainApp.status == .enabled else { return }
        if defaults.string(forKey: key) != path {
            try? SMAppService.mainApp.unregister()
            try? SMAppService.mainApp.register()
        }
        defaults.set(path, forKey: key)
    }

    func refresh() {
        guard isAvailable else {
            isEnabled = false
            statusNote = "Needs .app"
            return
        }
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true; statusNote = nil
        case .requiresApproval:
            isEnabled = true; statusNote = "Approve in Settings"
        case .notRegistered, .notFound:
            isEnabled = false; statusNote = nil
        @unknown default:
            isEnabled = false; statusNote = nil
        }
    }

    func setEnabled(_ on: Bool) {
        guard isAvailable else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("ClaudeThermal: launch-at-login change failed: \(error.localizedDescription)")
        }
        refresh()
        UserDefaults.standard.set(Bundle.main.bundlePath, forKey: "loginItem.registeredPath")
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

// MARK: - 80% overheat alert

@MainActor
final class OverheatNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let defaults = UserDefaults.standard
    private let askedKey = "notifications.requested"
    /// End of the window we already alerted for. The alert re-arms only once that window has reset.
    private let alertedUntilKey = "overheat.alertedUntil"
    private let threshold = 0.80
    /// `--simulate` keeps the flag in memory so a preview never suppresses a real alert.
    private let persist = !CommandLine.arguments.contains("--simulate")
    private var memoryAlertedUntil: Double = 0

    private var alertedUntil: Double {
        get { persist ? defaults.double(forKey: alertedUntilKey) : memoryAlertedUntil }
        set { if persist { defaults.set(newValue, forKey: alertedUntilKey) } else { memoryAlertedUntil = newValue } }
    }

    func requestAuthorizationOnFirstLaunch() {
        guard isRunningFromAppBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        guard !defaults.bool(forKey: askedKey) else { return }
        defaults.set(true, forKey: askedKey)
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func evaluate(_ snap: UsageSnapshot) {
        guard isRunningFromAppBundle, let reset = snap.sessionResetsAt else { return }
        let now = Date()
        if alertedUntil > 0, now.timeIntervalSince1970 < alertedUntil { return } // same window: already fired

        guard snap.sessionFraction >= threshold else { return }
        alertedUntil = reset.timeIntervalSince1970

        let content = UNMutableNotificationContent()
        content.title = "Claude Code Overheating"
        content.body = "80% of 5h session used. Resets at \(Format.clock(reset))."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: "overheat-\(Int(reset.timeIntervalSince1970))",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Show banners even though we're technically the "frontmost" accessory app sometimes.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
