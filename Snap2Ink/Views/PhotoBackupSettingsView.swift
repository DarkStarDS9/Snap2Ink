import SwiftUI

/// Configuration for backing up prints' originals to Photos — see `PhotoBackupSettings` and
/// `PhotoBackupService`.
///
/// Snap2Ink's first real settings screen. Everything else in the app is deliberately one studio
/// screen (see `StudioView`'s "no navigation stack" doctrine), but a permission-gated, opt-in
/// feature with a couple of knobs needs somewhere to live that isn't a sheet the user stumbles
/// into by accident — presented the same way as `DiagnosticsView`/`DebugLogView` to keep that
/// "sheet, not a pushed screen" shape intact.
struct PhotoBackupSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isEnabled = PhotoBackupSettings.isEnabled()
    @State private var usesAlbum = PhotoBackupSettings.usesAlbum()
    @State private var albumName = PhotoBackupSettings.albumName()
    @State private var deniedMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Back up photos to Photos", isOn: $isEnabled)
                        .onChange(of: isEnabled) { _, newValue in handleToggle(newValue) }
                } footer: {
                    Text("Saves the original photo behind every print, so you can resend it later with the same dithering.")
                }

                if isEnabled {
                    Section {
                        Toggle("Save into an album", isOn: $usesAlbum)
                            .onChange(of: usesAlbum) { _, newValue in PhotoBackupSettings.setUsesAlbum(newValue) }
                        if usesAlbum {
                            TextField("Album name", text: $albumName)
                                .onChange(of: albumName) { _, newValue in
                                    PhotoBackupSettings.setAlbumName(newValue)
                                }
                        }
                    } footer: {
                        Text(usesAlbum
                            ? "Photos are added to this album, which is created the first time it's needed."
                            : "Photos are saved straight to your camera roll, with no album.")
                    }
                }
            }
            .navigationTitle("Photo Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Photos Access Needed",
                isPresented: Binding(
                    get: { deniedMessage != nil },
                    set: { if !$0 { deniedMessage = nil } }
                ),
                presenting: deniedMessage
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
        }
    }

    private func handleToggle(_ newValue: Bool) {
        guard newValue else {
            PhotoBackupSettings.setEnabled(false)
            return
        }
        Task {
            let granted = await PhotoBackupService.requestAddOnlyAuthorization()
            if granted {
                PhotoBackupSettings.setEnabled(true)
            } else {
                isEnabled = false
                PhotoBackupSettings.setEnabled(false)
                deniedMessage = "Snap2Ink can't save to Photos without permission. Turn it on in Settings ▸ Snap2Ink ▸ Photos."
            }
        }
    }
}
