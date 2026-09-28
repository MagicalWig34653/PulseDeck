import Observation
import ServiceManagement

/// Launch at Login through `SMAppService.mainApp` (SPEC §33: Apple's supported login-item
/// mechanism, no launch agents or scripts).
///
/// The registration state lives in the system (the user can change it in System Settings →
/// General → Login Items), so it is read from `SMAppService` rather than stored in preferences.
@MainActor
@Observable
final class LoginItemController {
    private(set) var status: SMAppService.Status
    /// Message of the last failed registration change, shown under the toggle.
    private(set) var lastError: String?

    init() {
        status = SMAppService.mainApp.status
    }

    /// On, or registered and waiting for the user's approval in System Settings.
    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    var requiresApproval: Bool { status == .requiresApproval }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            // Typical causes: the app is not in /Applications or its signature is not accepted
            // (ad-hoc signed development builds).
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Re-reads the status, e.g. when Settings appears after a change in System Settings.
    func refresh() {
        status = SMAppService.mainApp.status
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
