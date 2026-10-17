import AppKit
import Sparkle

/// In-app updates, with Sparkle. Once a day DigUp reads its appcast (`SUFeedURL` in Info.plist); a newer version is
/// downloaded, checked against the EdDSA key in Info.plist (`SUPublicEDKey`) and Apple's signature, put in place of this
/// copy and reopened, after one click. Finder can't replace a running app, and DigUp runs most of the time.
///
/// DigUp lives in the menu bar, so an update the daily check finds doesn't pop up over whatever you're doing (Sparkle's
/// "gentle reminders"): it waits in the menu ("Update to DigUp 0.6.1…"), as a dot on the menubar mark, and in the
/// window's status bar, until you open it. Checks you ask for show Sparkle's window at once.
final class Updates: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private let model: AppModel
    private var controller: SPUStandardUpdaterController!
    /// Sparkle's window closed: the Dock icon goes unless one of DigUp's windows is open.
    var onSessionEnded: () -> Void = {}

    init(model: AppModel) {
        self.model = model
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    /// Manual updates protect the fork from being replaced by an upstream release.
    func start() {} // This fork has no signed automatic-update feed yet.

    var automaticallyChecks: Bool {
        get { false }
        set { /* Manual updates only for this fork. */ }
    }

    var canCheck: Bool { true }

    func checkNow() {
        NSWorkspace.shared.open(URL(string: "https://github.com/yuezheng2006/DigUp/releases")!)
    }

    func checkInBackground() {} // Never install an upstream build over the Chinese fork.

    // MARK: Gentle reminders

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// An update the daily check found waits for you to open it.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                             andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if handleShowingUpdate {
            // Sparkle's window comes up: like DigUp's own windows, with the Dock icon while it's open.
            NSApp.setActivationPolicy(.regular)
            bringAppToFront()
        } else {
            model.updateAvailable = update.displayVersionString
            log("updates: \(update.displayVersionString) is available; waiting in the menu")
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        model.updateAvailable = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        model.updateAvailable = nil
        onSessionEnded()
    }

    // MARK: What happened (logged)

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log("updates: found \(item.displayVersionString) (\(item.versionString))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        log("updates: up to date")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        log("updates: \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        log("updates: installing \(item.displayVersionString)")
    }
}
