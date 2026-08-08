import SwiftUI
import UIKit

/// Read-only view over `DebugLog`, for pulling a trace off a phone after a bug happened on it.
///
/// Not `#if DEBUG`: the symptoms this exists to diagnose — a silent stuck reconnect, a send that
/// never resolves — are the ones a TestFlight tester hits in the field, not ones reproduced with a
/// debugger attached. Reached by long-pressing the link status bar, deliberately out of the way of
/// the one-tap DEBUG diagnostics gesture.
struct DebugLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [DebugLog.Entry] = DebugLog.shared.entries
    @State private var isSharing = false

    var body: some View {
        NavigationStack {
            List(entries) { entry in
                Text(entry.formatted)
                    .font(.system(.caption, design: .monospaced))
            }
            .listStyle(.plain)
            .navigationTitle("Debug Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        entries = DebugLog.shared.entries
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isSharing = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $isSharing) {
                ActivityView(text: DebugLog.shared.formattedText)
            }
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
