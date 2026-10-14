import Foundation
import ServiceManagement

/// Launch-at-login backed by `SMAppService`, so the app shows up under
/// System Settings › General › Login Items where it can also be turned off.
///
/// Registration only works from a real `.app` bundle; running the bare binary out of
/// `.build/` is a no-op rather than an error.
@MainActor
enum LaunchAtLogin {
    /// Set once the user turns the toggle off, so we stop re-enabling it on every launch.
    private static let optedOutKey = "LaunchAtLoginOptedOut"
    /// Where the bundle was when it last registered. The login item is filed under the bundle
    /// ID, so it still reads as enabled after the app moves while pointing at the old place.
    private static let registeredPathKey = "LaunchAtLoginRegisteredPath"

    private static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        isBundled && SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        guard isBundled else { return }
        UserDefaults.standard.set(!enabled, forKey: optedOutKey)
        do {
            if enabled {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(Bundle.main.bundlePath, forKey: registeredPathKey)
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Notch: launch at login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }

    /// Enable on first launch, and re-register when a rebuild has invalidated the stored
    /// login item — unless the user has explicitly opted out.
    static func syncOnLaunch() {
        guard isBundled, !UserDefaults.standard.bool(forKey: optedOutKey) else { return }

        switch SMAppService.mainApp.status {
        case .enabled:
            // Registered from somewhere else (the app was moved or reinstalled elsewhere):
            // point the login item at this copy.
            let registeredPath = UserDefaults.standard.string(forKey: registeredPathKey)
            if registeredPath != Bundle.main.bundlePath {
                try? SMAppService.mainApp.unregister()
                setEnabled(true)
            }
        case .requiresApproval:
            NSLog("Notch: launch at login needs approval in System Settings › General › Login Items.")
        default:
            setEnabled(true)
        }
    }
}
