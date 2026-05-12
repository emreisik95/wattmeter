import Foundation
import Sparkle

@MainActor
final class UpdaterBridge: NSObject {
    static let shared = UpdaterBridge()
    let controller: SPUStandardUpdaterController

    override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}
