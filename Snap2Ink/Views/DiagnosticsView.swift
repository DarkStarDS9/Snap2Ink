import SwiftUI

#if DEBUG
/// What the device said about itself, plus what this app is sending it.
///
/// Exists to make `MANUAL-DEVICE-TESTS.md` executable by one person with a phone and a reader.
/// Several steps ask the tester to record the advertised pixel size, the image cap, or the last
/// `IMAGE_STATUS` — and without this screen none of those are visible from the phone at all. They
/// are readable over a serial cable with the firmware's `CCAP`, but requiring a laptop and a USB
/// lead to run a phone-side checklist is how steps quietly get skipped.
///
/// DEBUG-only, reached by tapping the link status bar. Diagnostics in a shipping camera app would be
/// clutter; during bring-up they are the difference between a checklist that can be followed and one
/// that can't.
struct DiagnosticsView: View {
    @ObservedObject var model: PrintStudioModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Device") {
                    ForEach(model.transport.diagnostics) { entry in
                        LabeledContent(entry.label, value: entry.value)
                    }
                }

                Section("What this app sends") {
                    LabeledContent("Image format", value: "2-bit grey PNG, type 0")
                    LabeledContent("Levels", value: "0, 85, 170, 255")
                    LabeledContent("App id", value: Snap2InkPeer.appId.uuidString.lowercased())
                    LabeledContent("Display name", value: Snap2InkPeer.displayName)
                    LabeledContent("User label", value: Snap2InkPeer.identity().userName)
                }

                Section("Button map") {
                    ForEach(Snap2InkPeer.uiDeclaration.buttons, id: \.button) { entry in
                        LabeledContent(
                            "\(entry.button)".capitalized,
                            value: entry.label.isEmpty ? "\(entry.routing)" : "\(entry.routing) · \"\(entry.label)\""
                        )
                    }
                }

                if let proof = model.proof {
                    Section("Current print") {
                        // The dimensions here must equal the device's advertised screen pixels
                        // above. If they differ, the device will scale and resample the image and
                        // the dither is destroyed — see MANUAL-DEVICE-TESTS.md § 4.
                        LabeledContent("Pixels", value: "\(proof.image.width) × \(proof.image.height)")
                        LabeledContent("Encoded size", value: "\(proof.byteCount) B")
                        LabeledContent("Dither", value: proof.algorithm.displayName)
                        LabeledContent("Style", value: proof.style.displayName)
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif
