import SwiftUI

@main
struct BleuE2EApp: App {
    @StateObject private var model: E2EViewModel

    init() {
        let launchConfiguration = E2ELaunchConfiguration.parse()
        let model = E2EViewModel(launchConfiguration: launchConfiguration)
        _model = StateObject(wrappedValue: model)

        if launchConfiguration.hasAutomation {
            Task { @MainActor in
                await model.runLaunchAutomationIfNeeded()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            E2ERootView(model: model)
        }
    }
}
