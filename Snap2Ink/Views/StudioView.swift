import CompanionKit
import SwiftUI

/// The whole app, in one screen that changes what it is showing.
///
/// There is no navigation stack because there is nowhere to navigate to: take a photo, look at it,
/// send it, watch it develop. Anything that pushed a second screen would be a feature this app has
/// decided not to have.
struct StudioView: View {
    @ObservedObject var model: PrintStudioModel
    @StateObject private var restoreCoordinator: PhotoRestoreCoordinator
    #if DEBUG
    @State private var showsDiagnostics = false
    #endif
    @State private var showsLabelEditor = false
    @State private var showsDebugLog = false
    @State private var showsPhotoSettings = false
    @State private var showsBackupPrompt = false
    @State private var labelDraft = ""

    init(model: PrintStudioModel) {
        self.model = model
        _restoreCoordinator = StateObject(wrappedValue: PhotoRestoreCoordinator(model: model))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                LinkStatusBar(
                    state: model.transportState,
                    showsRestore: model.stage == .viewfinder && !restoreCoordinator.isRestoring,
                    onReconnect: { model.connect() },
                    onEditLabel: {
                        labelDraft = Snap2InkPeer.userLabel()
                        showsLabelEditor = true
                    },
                    onOpenPhotoSettings: { showsPhotoSettings = true },
                    onRestore: { restoreCoordinator.present() }
                )
                    #if DEBUG
                    // Tap the status bar for the capability readout. Documented in
                    // MANUAL-DEVICE-TESTS.md, which asks the tester to record values that are
                    // otherwise only visible over a serial cable.
                    .onTapGesture { showsDiagnostics = true }
                    #endif
                    // Long-press for the debug log, in every build configuration — unlike the
                    // capability readout above, this exists to diagnose bugs a TestFlight tester
                    // hits in the field, where there is no debugger to fall back on.
                    .onLongPressGesture { showsDebugLog = true }

                switch model.stage {
                case .viewfinder:
                    ViewfinderView(model: model)
                case .proofing:
                    ProofView(model: model)
                case .printing, .printed:
                    DevelopingView(model: model)
                }
            }
        }
        .task {
            await model.camera.start()
            model.connect()
            if !PhotoBackupSettings.hasPrompted() {
                showsBackupPrompt = true
            }
        }
        .alert(
            "Snap2Ink",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { message in
            Text(message)
        }
        // Distinguishes this install of Snap2Ink from another one paired to the same reader — e.g.
        // two people sharing one reader — in the device's gallery picker. Only takes effect on the
        // next launch: `Snap2InkPeer.identity()` is read once when the app starts (see
        // `Snap2InkApp.makeTransport()`), and `CompanionClient` holds it for its whole lifetime.
        .alert("Label This Phone", isPresented: $showsLabelEditor) {
            TextField("e.g. Alex's iPhone", text: $labelDraft)
            Button("Save") { Snap2InkPeer.setUserLabel(labelDraft) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shown on the reader so two people pairing the same reader can tell their photos apart. Takes effect next time you open Snap2Ink.")
        }
        .alert("Back Up Your Photos?", isPresented: $showsBackupPrompt) {
            Button("Not Now") { PhotoBackupSettings.setHasPrompted() }
            Button("Save Backups") {
                Task {
                    let granted = await PhotoBackupService.requestAddOnlyAuthorization()
                    PhotoBackupSettings.setHasPrompted()
                    if granted { PhotoBackupSettings.setEnabled(true) }
                }
            }
        } message: {
            Text("Snap2Ink can save the original photo behind every print to a Photos album, so you can resend it later looking exactly the same. You can change this anytime.")
        }
        .alert(
            "Snap2Ink",
            isPresented: Binding(
                get: { restoreCoordinator.summaryMessage != nil },
                set: { if !$0 { restoreCoordinator.summaryMessage = nil } }
            ),
            presenting: restoreCoordinator.summaryMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        #if DEBUG
        .sheet(isPresented: $showsDiagnostics) {
            DiagnosticsView(model: model)
        }
        #endif
        .sheet(isPresented: $showsDebugLog) {
            DebugLogView()
        }
        .sheet(isPresented: $showsPhotoSettings) {
            PhotoBackupSettingsView()
        }
        .sheet(isPresented: $restoreCoordinator.isPickerPresented) {
            PhotoRestorePicker(onSelection: restoreCoordinator.handlePickerResults)
        }
    }
}

/// One line at the top saying what the reader is doing. It earns the space because two of its
/// states — "confirm on your reader" and "another app has the screen" — are things the user must
/// act on somewhere other than this phone, and a spinner would tell them nothing.
private struct LinkStatusBar: View {
    let state: TransportState
    /// Restoring drives the model through the same stages a live capture does — see
    /// `PrintStudioModel.restoreAndSend` — so the entry point only makes sense from the viewfinder,
    /// same as the shutter, and hides itself while a batch is already running.
    let showsRestore: Bool
    let onReconnect: () -> Void
    let onEditLabel: () -> Void
    let onOpenPhotoSettings: () -> Void
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            if showsRestore {
                iconButton("photo.stack", action: onRestore)
            }
            iconButton("gearshape", action: onOpenPhotoSettings)
            iconButton("person.crop.circle", action: onEditLabel)
            if showsReconnect {
                Button("Reconnect", action: onReconnect)
                    .font(.footnote.weight(.medium))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.white.opacity(0.06))
    }

    /// HIG calls for a 44×44pt minimum tap target; the glyph itself stays footnote-sized so the bar
    /// doesn't visually balloon, but the hit area around it is padded out to that minimum.
    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.footnote)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .foregroundStyle(.white.opacity(0.75))
    }

    private var message: String {
        switch state {
        case .idle: return "Not connected"
        case .scanning: return "Looking for your reader…"
        case .connecting: return "Connecting…"
        case .awaitingPairingConfirmation: return "Confirm on your reader"
        case .pairingRefused(.timeout): return "Pairing timed out"
        case .pairingRefused: return "Pairing declined on the reader"
        case .ready: return "Reader ready"
        case .sending(let progress): return "Sending — \(Int(progress * 100))%"
        case .developing: return "Developing on the reader"
        case .backgrounded(.preempted): return "Another app has the screen"
        case .backgrounded(.released): return "Screen released"
        case .backgrounded: return "Link lost"
        case .disconnected: return "Disconnected"
        case .failed(let reason): return reason
        }
    }

    private var tint: Color {
        switch state {
        case .ready, .sending, .developing: return .green
        case .awaitingPairingConfirmation: return .yellow
        case .pairingRefused, .failed, .disconnected, .backgrounded: return .red
        case .idle, .scanning, .connecting: return .gray
        }
    }

    private var showsReconnect: Bool {
        switch state {
        case .disconnected, .failed, .pairingRefused, .idle, .backgrounded: return true
        default: return false
        }
    }
}
