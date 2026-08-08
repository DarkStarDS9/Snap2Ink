import SwiftUI

@main
struct Snap2InkApp: App {
    @StateObject private var model = PrintStudioModel(
        camera: CameraController(),
        transport: Snap2InkApp.makeTransport()
    )
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            StudioView(model: model)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Snap2Ink has no reason to keep holding the reader's screen (or the BLE link) once
            // backgrounded and idle — unlike an audio or navigation app, there's nothing left running.
            // Dropping it here, rather than in CompanionKit, keeps that no-op-in-background default
            // generic for apps that do have a reason to stay connected. The one exception is a send
            // already in flight: `disconnectForBackground()` defers to let it finish, which is why
            // `bluetooth-central` is still declared in Info.plist — that's what keeps iOS from
            // suspending the radio mid-transfer.
            DebugLog.shared.log("scenePhase -> \(newPhase)")
            switch newPhase {
            case .background:
                model.disconnectForBackground()
            case .active:
                // `StudioView`'s `.task` only fires on first appearance, so resuming from the
                // background needs its own kick to re-scan and re-pair.
                model.connect()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    /// Picks the transport. The simulator has no Bluetooth radio at all, so there is nothing for a
    /// real transport to do there but fail — and the mock's realistic timing is what makes the
    /// developing animation designable without a device in hand. See `MockDisplayTransport`.
    ///
    private static func makeTransport() -> DisplayTransport {
        #if targetEnvironment(simulator)
        return MockDisplayTransport()
        #else
        return CompanionKitTransport()
        #endif
    }
}
