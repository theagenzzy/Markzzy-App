import SwiftUI
import AVFoundation
import AppKit

struct VideoLibraryView: View {
    var isActive: Bool = true
    @EnvironmentObject var model: AppModel
    @State private var items: [VideoItem] = []
    @State private var thumbnails: [URL: NSImage] = [:]
    @State private var aspects: [URL: CGFloat] = [:]
    @State private var pendingDelete: VideoItem?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            folderBar
            Divider()
            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(items) { item in
                            VideoCard(
                                item: item,
                                thumbnail: thumbnails[item.url],
                                aspect: aspects[item.url] ?? 16.0 / 9.0,
                                onPreview: { NSWorkspace.shared.open(item.url) },
                                onReveal: { model.revealInFinder(item.url) },
                                onDelete: { pendingDelete = item }
                            )
                            .task { await loadThumbnail(for: item) }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 500, height: 720)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { reload() }
        .onChange(of: isActive) { _, now in
            if now { reload() }
        }
        .onChange(of: model.outputDirectory) { _, _ in reload() }
        .onChange(of: model.state) { _, new in
            if case .done = new { reload() }
        }
        .confirmationDialog(
            model.t(.confirmDeleteVideo),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { item in
            Button(model.t(.deleteAction), role: .destructive) { delete(item) }
            Button(model.t(.cancelAction), role: .cancel) {}
        } message: { item in
            Text(item.name)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            LogoMark(size: 22)
            Text(model.t(.library)).font(.headline)
            Spacer()
            Text("\(items.count) \(items.count == 1 ? model.t(.videoCount) : model.t(.videosCount))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button { reload() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.12))
            )
            .help(model.t(.reload))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var folderBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            Text((model.outputDirectory.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(model.t(.changeFolder)) { chooseFolder() }
                .buttonStyle(.borderless)
                .font(.caption)
            Button {
                model.revealInFinder(model.outputDirectory)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.12))
            )
            .help(model.t(.openFolderInFinder))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.04))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.message = model.t(.selectFolderMessage)
        panel.prompt = model.t(.chooseThisFolder)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.directoryURL = model.outputDirectory
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            model.outputDirectory = url
            reload()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "film")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(model.t(.noRecordingsYet))
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(model.t(.videosAppearHere))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() {
        items = model.listRecordedVideos()
    }

    private func delete(_ item: VideoItem) {
        do {
            try model.deleteVideo(item.url)
            thumbnails[item.url] = nil
            reload()
        } catch {
            NSSound.beep()
        }
    }

    private func loadThumbnail(for item: VideoItem) async {
        if thumbnails[item.url] != nil { return }
        let url = item.url
        struct ThumbnailResult: Sendable { let image: NSImage?; let aspect: CGFloat? }
        let result: ThumbnailResult = await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 480, height: 480)
            let time = CMTime(seconds: 0.1, preferredTimescale: 600)
            do {
                let cg = try await gen.image(at: time).image
                let aspect = CGFloat(cg.width) / CGFloat(max(cg.height, 1))
                return ThumbnailResult(image: NSImage(cgImage: cg, size: .zero), aspect: aspect)
            } catch {
                return ThumbnailResult(image: nil, aspect: nil)
            }
        }.value
        await MainActor.run {
            thumbnails[url] = result.image
            if let a = result.aspect { aspects[url] = a }
        }
    }
}

private struct VideoCard: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let thumbnail: NSImage?
    let aspect: CGFloat
    let onPreview: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.15))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
                Button(action: onPreview) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(radius: 3)
                }
                .buttonStyle(.plain)
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)

            Text(item.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 4) {
                Text(Self.dateFormatter.string(from: item.date))
                Text("·")
                Text(item.sizeFormatted)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                iconButton(icon: "play.fill",  help: model.t(.watchAction), action: onPreview)
                iconButton(icon: "folder",     help: model.t(.showInFinder), action: onReveal)
                Spacer()
                iconButton(icon: "trash",      help: model.t(.deleteAction), tint: .red, action: onDelete)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
        .contextMenu {
            Button(model.t(.watchAction)) { onPreview() }
            Button(model.t(.showInFinder)) { onReveal() }
            Divider()
            Button(model.t(.deleteAction), role: .destructive) { onDelete() }
        }
    }

    private func iconButton(icon: String, help: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .foregroundStyle(tint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(0.12))
        )
        .help(help)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

