import AppKit
import Sparkle

@MainActor
final class SparkleUpdater {
    private(set) static var shared: SparkleUpdater?

    private var controller: SPUStandardUpdaterController?

    func start() {
        guard controller == nil else { return }
        guard Bundle.main.infoDictionary?["SUFeedURL"] != nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        SparkleUpdater.shared = self
    }

    func checkForUpdates() {
        // Activate the app so Sparkle's update window appears above all other windows
        NSApplication.shared.activate()
        controller?.checkForUpdates(nil)
    }
}
