import SwiftUI

@main
struct omiwatch_Watch_AppApp: App {
    @StateObject private var viewModel = WatchAudioRecorderViewModel()

    var body: some Scene {
        WindowGroup {
            // The live heart-rate page (LiveHeartRateView in ContentView.swift)
            // is written and ready but not shown: the watch app's HealthKit
            // entitlement cannot be signed from the command line while Xcode
            // has no Apple ID registered. Restore the TabView once it can.
            WatchRecorderView(viewModel: viewModel)
        }
    }
}
