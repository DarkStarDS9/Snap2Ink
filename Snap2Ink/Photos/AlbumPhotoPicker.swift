import Photos
import SwiftUI

/// Multi-select grid, scoped to the configured Snap2Ink backup album, for choosing which backed-up
/// prints to resend.
///
/// Replaces a `PHPickerViewController` wrapper: that picker cannot be scoped to one album, so
/// restoring meant the user manually browsing into the right album, out of their whole library,
/// every single time. Being scoped instead means asking for full Photos read access
/// (`NSPhotoLibraryUsageDescription`) rather than the write-only access `PhotoBackupService`'s
/// backup path uses — see `PhotoBackupService.requestReadAuthorization()` — so this view also owns
/// walking the user through that ask, with an explainer step before the system dialog fires.
struct AlbumPhotoPicker: View {
    let onSelection: ([PHAsset]) -> Void
    let onCancel: () -> Void

    @State private var stage: Stage = .checking
    @State private var assets: [PHAsset] = []
    @State private var selectedIDs = Set<String>()

    private enum Stage {
        case checking
        case albumDisabled
        case explainer
        case requesting
        case denied
        case noAlbum
        case empty
        case browsing
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Restore Photos")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    if stage == .browsing {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(confirmTitle) { onSelection(selectedAssets) }
                                .disabled(selectedIDs.isEmpty)
                        }
                    }
                }
        }
        .task { evaluateAuthorization() }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .checking, .requesting:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .albumDisabled:
            ContentUnavailableView {
                Label("No Backup Album", systemImage: "photo.stack")
            } description: {
                Text("Turn on “Save into an album” in Photo Backup settings to browse and resend backups here.")
            }
        case .explainer:
            explainer
        case .denied:
            ContentUnavailableView {
                Label("Photos Access Needed", systemImage: "lock.fill")
            } description: {
                Text("Snap2Ink needs permission to browse your “\(PhotoBackupSettings.albumName())” album. Turn it on in Settings ▸ Snap2Ink ▸ Photos.")
            } actions: {
                Button("Open Settings", action: openSettings)
            }
        case .noAlbum:
            ContentUnavailableView {
                Label("No Backups Yet", systemImage: "photo.stack")
            } description: {
                Text("Once a print is backed up into your “\(PhotoBackupSettings.albumName())” album, it'll show up here to resend.")
            }
        case .empty:
            ContentUnavailableView {
                Label("Album Is Empty", systemImage: "photo.stack")
            } description: {
                Text("There's nothing in your “\(PhotoBackupSettings.albumName())” album yet.")
            }
        case .browsing:
            grid
        }
    }

    private var explainer: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Browse Your Backup Album")
                .font(.title2.weight(.semibold))
            Text("To let you pick a photo to resend without leaving Snap2Ink, the next screen will ask for permission to view your Photos library. Snap2Ink only ever reads photos, and only ever shows you the “\(PhotoBackupSettings.albumName())” album here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Continue") { Task { await requestAuthorization() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 2)], spacing: 2) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    thumbnail(for: asset)
                }
            }
        }
    }

    private func thumbnail(for asset: PHAsset) -> some View {
        let isSelected = selectedIDs.contains(asset.localIdentifier)
        return AssetThumbnailView(asset: asset)
            .aspectRatio(1, contentMode: .fill)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.35))
                    .padding(6)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelected {
                    selectedIDs.remove(asset.localIdentifier)
                } else {
                    selectedIDs.insert(asset.localIdentifier)
                }
            }
    }

    private var confirmTitle: String {
        selectedIDs.isEmpty ? "Send" : "Send (\(selectedIDs.count))"
    }

    private var selectedAssets: [PHAsset] {
        assets.filter { selectedIDs.contains($0.localIdentifier) }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func evaluateAuthorization() {
        guard PhotoBackupSettings.usesAlbum() else {
            stage = .albumDisabled
            return
        }
        switch PhotoBackupService.readAuthorizationStatus() {
        case .notDetermined:
            stage = .explainer
        case .authorized, .limited:
            loadAlbum()
        default:
            stage = .denied
        }
    }

    private func requestAuthorization() async {
        stage = .requesting
        let granted = await PhotoBackupService.requestReadAuthorization()
        if granted {
            loadAlbum()
        } else {
            stage = .denied
        }
    }

    private func loadAlbum() {
        guard let fetchResult = PhotoBackupService.fetchBackupAlbumAssets(albumName: PhotoBackupSettings.albumName()) else {
            stage = .noAlbum
            return
        }
        assets = (0..<fetchResult.count).map { fetchResult.object(at: $0) }
        stage = assets.isEmpty ? .empty : .browsing
    }
}

/// A single grid cell's thumbnail, loaded lazily as it scrolls into view.
private struct AssetThumbnailView: View {
    let asset: PHAsset

    @State private var image: UIImage?

    /// Caching manager shared by all cells so scrolling back to an already-loaded thumbnail is
    /// instant rather than re-fetching from the Photos framework.
    private static let manager = PHCachingImageManager()

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: asset.localIdentifier) {
                image = await Self.loadThumbnail(for: asset)
            }
    }

    /// `.highQualityFormat` delivers exactly once, unlike `.opportunistic`'s low-then-high pair —
    /// important here since `requestImage`'s handler feeds a single-resume continuation.
    private static func loadThumbnail(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            let targetSize = CGSize(width: 200, height: 200)
            manager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
