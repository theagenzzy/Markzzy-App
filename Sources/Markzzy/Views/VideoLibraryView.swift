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
    @State private var isSelecting: Bool = false
    @State private var selected: Set<URL> = []
    @State private var pendingBulkDelete: Bool = false

    private enum LibraryFormat: Int, CaseIterable, Hashable {
        case youtube, reel, post

        var titleKey: LKey {
            switch self {
            case .youtube: .formatYouTube
            case .reel:    .formatReel
            case .post:    .formatSquare
            }
        }

        var columns: [GridItem] {
            switch self {
            case .youtube, .post:
                return [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ]
            case .reel:
                return [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                ]
            }
        }

        static func from(aspect: CGFloat) -> LibraryFormat {
            if aspect >= 1.3 { return .youtube }
            if aspect <= 0.75 { return .reel }
            return .post
        }
    }

    @State private var filter: LibraryFormat = .youtube

    private func format(for item: VideoItem) -> LibraryFormat {
        guard let a = aspects[item.url] else { return .youtube }
        return .from(aspect: a)
    }

    private func items(in fmt: LibraryFormat) -> [VideoItem] {
        items.filter { format(for: $0) == fmt }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            folderBar
            Divider()
            if items.isEmpty {
                emptyState
            } else {
                formatTabs
                Divider()
                let visible = items(in: filter)
                if visible.isEmpty {
                    emptyFilterState
                } else {
                    ScrollView {
                        LazyVGrid(columns: filter.columns, spacing: 12) {
                            ForEach(visible) { item in
                                VideoCard(
                                    item: item,
                                    thumbnail: thumbnails[item.url],
                                    aspect: aspects[item.url] ?? 16.0 / 9.0,
                                    selectable: isSelecting,
                                    isSelected: selected.contains(item.url),
                                    onPreview: { handleTap(item) },
                                    onReveal: { model.revealInFinder(item.url) },
                                    onDelete: { pendingDelete = item }
                                )
                                .task { await loadThumbnail(for: item) }
                            }
                        }
                        .padding(16)
                    }
                }
                if isSelecting {
                    Divider()
                    selectionBar
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

    private var formatTabs: some View {
        HStack(spacing: 8) {
            Picker("", selection: $filter) {
                ForEach(LibraryFormat.allCases, id: \.rawValue) { fmt in
                    Text(model.t(fmt.titleKey)).tag(fmt)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var emptyFilterState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(model.t(.noRecordingsYet))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            LogoMark(size: 22)
            Text(model.t(.library)).font(.headline)
            Spacer()
            if !isSelecting {
                Text("\(items.count) \(items.count == 1 ? model.t(.videoCount) : model.t(.videosCount))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                isSelecting.toggle()
                if !isSelecting { selected.removeAll() }
            } label: {
                Text(isSelecting ? model.t(.doneAction) : model.t(.selectAction))
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            .disabled(items.isEmpty)
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
            AccountMenu()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("\(selected.count) \(selected.count == 1 ? model.t(.videoCount) : model.t(.videosCount))")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button(model.t(.cancelAction)) {
                isSelecting = false
                selected.removeAll()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(role: .destructive) {
                pendingBulkDelete = true
            } label: {
                Text(String(format: model.t(.deleteCountAction), selected.count))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .confirmationDialog(
            String(format: model.t(.confirmDeleteVideos), selected.count),
            isPresented: $pendingBulkDelete,
            titleVisibility: .visible
        ) {
            Button(model.t(.deleteAction), role: .destructive) {
                bulkDelete()
            }
            Button(model.t(.cancelAction), role: .cancel) {}
        }
    }

    private func handleTap(_ item: VideoItem) {
        if isSelecting {
            if selected.contains(item.url) { selected.remove(item.url) }
            else { selected.insert(item.url) }
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func bulkDelete() {
        let urls = selected
        for u in urls {
            try? model.deleteVideo(u)
            thumbnails[u] = nil
            aspects[u] = nil
        }
        selected.removeAll()
        isSelecting = false
        reload()
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
    var selectable: Bool = false
    var isSelected: Bool = false
    let onPreview: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
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
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if !selectable {
                    Button(action: onPreview) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white.opacity(0.92))
                            .shadow(radius: 3)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if selectable {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.85))
                        .background(
                            Circle().fill(.black.opacity(0.35))
                                .blur(radius: 2)
                        )
                        .padding(8)
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
            .onTapGesture { onPreview() }

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

            if !selectable {
                HStack(spacing: 6) {
                    iconButton(icon: "play.fill",  help: model.t(.watchAction), action: onPreview)
                    iconButton(icon: "folder",     help: model.t(.showInFinder), action: onReveal)
                    Spacer()
                    iconButton(icon: "trash",      help: model.t(.deleteAction), tint: .red, action: onDelete)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06))
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

