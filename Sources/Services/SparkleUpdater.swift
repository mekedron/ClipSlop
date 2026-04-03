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
        controller?.checkForUpdates(nil)
    }
}
