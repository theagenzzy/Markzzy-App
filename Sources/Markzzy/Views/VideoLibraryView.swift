import SwiftUI
import AVFoundation
import AppKit

struct VideoLibraryView: View {
    var isActive: Bool = true
    @EnvironmentObject var model: AppModel
    @State private var items: [VideoItem] = []
    @State private var thumbnails: [URL: NSImage] = [:]
    @State private var aspects: [URL: CGFloat] = [:]
    /// Duration in seconds, lazily loaded per video. Shown next to size in
    /// the card so the user can tell a 30 s clip from a 5 min one without
    /// opening it.
    @State private var durations: [URL: TimeInterval] = [:]
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
                                    duration: durations[item.url],
                                    // 3-column reels grid is too narrow
                                    // (~150 px) for icon + label buttons.
                                    // YouTube/Post stay with text.
                                    compact: filter == .reel,
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
        // Only scan the output directory when the Library tab is actually
        // visible. Without this guard, .onAppear fires for the offscreen
        // VideoLibraryView during cold launch (the ZStack instantiates all
        // tabs), adding ~100-300 ms of synchronous FileManager I/O to the
        // first paint.
        .onAppear { if isActive { reload() } }
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
        // Each tab shows the format name + a count of matching recordings,
        // so the user immediately sees "YouTube has 2, Reels 1, Post 0"
        // and doesn't waste a click on an empty filter.
        HStack(spacing: 8) {
            Picker("", selection: $filter) {
                ForEach(LibraryFormat.allCases, id: \.rawValue) { fmt in
                    let count = items(in: fmt).count
                    Text("\(model.t(fmt.titleKey)) (\(count))").tag(fmt)
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
                .help(model.t(.libraryAccountTooltip))
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
            selected.count == 1
                ? model.t(.confirmDeleteVideo)
                : String(format: model.t(.confirmDeleteVideos), selected.count),
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
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "film.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor)
            }
            Text(model.t(.libraryEmptyHeadline))
                .font(.headline)
            Text(model.t(.libraryEmptySubcopy))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 32)
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
        struct ThumbnailResult: Sendable { let image: NSImage?; let aspect: CGFloat?; let duration: TimeInterval? }
        let result: ThumbnailResult = await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 480, height: 480)
            let time = CMTime(seconds: 0.1, preferredTimescale: 600)
            // Read duration alongside the thumbnail in the same detached
            // task so we touch the asset's tracks once instead of twice.
            // Fail-soft: if duration load throws we just skip showing it,
            // never block the thumbnail render.
            let duration: TimeInterval? = (try? await asset.load(.duration))
                .map { CMTimeGetSeconds($0) }
                .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            do {
                let cg = try await gen.image(at: time).image
                let aspect = CGFloat(cg.width) / CGFloat(max(cg.height, 1))
                return ThumbnailResult(image: NSImage(cgImage: cg, size: .zero), aspect: aspect, duration: duration)
            } catch {
                return ThumbnailResult(image: nil, aspect: nil, duration: duration)
            }
        }.value
        await MainActor.run {
            thumbnails[url] = result.image
            if let a = result.aspect { aspects[url] = a }
            if let d = result.duration { durations[url] = d }
        }
    }
}

private struct VideoCard: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let thumbnail: NSImage?
    let aspect: CGFloat
    var duration: TimeInterval? = nil
    /// True for the 3-column reels grid where there's no room for text
    /// labels — falls back to icon-only buttons with tooltips.
    var compact: Bool = false
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

            // Friendly headline: "Recording · Apr 23, 22:03" instead of
            // the raw "Markzzy-2026-04-23-220320.mp4" filename. Real
            // filename remains in the tooltip + context menu for power
            // users who care about the exact path.
            Text(String(format: model.t(.libraryRecordingTitleFormat),
                        Self.dateFormatter.string(from: item.date)))
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.name)

            // Metadata row: duration · size. Skip duration if AVAsset
            // hasn't loaded yet — a missing dot beats a bogus "0:00".
            HStack(spacing: 4) {
                if let d = duration {
                    Text(Self.formatDuration(d))
                    Text("·")
                }
                Text(item.sizeFormatted)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if !selectable {
                HStack(spacing: 6) {
                    labeledButton(icon: "play.fill",
                                  label: model.t(.libraryActionPlay),
                                  action: onPreview)
                    labeledButton(icon: "folder",
                                  label: model.t(.libraryActionShowInFinder),
                                  action: onReveal)
                    Spacer(minLength: 4)
                    labeledButton(icon: "trash",
                                  label: model.t(.libraryActionDelete),
                                  tint: .red,
                                  action: onDelete)
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

    /// Small action button. In wide cards (2-column youtube/post grids)
    /// shows icon + text label. In narrow cards (3-column reels grid)
    /// drops the label and relies on the tooltip — there's no room for
    /// text without truncation or wrapping.
    private func labeledButton(icon: String, label: String,
                               tint: Color = .primary,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                if !compact {
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, compact ? 6 : 7)
            .padding(.vertical, 4)
            .foregroundStyle(tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(tint == .red
                      ? Color.red.opacity(0.12)
                      : Color.secondary.opacity(0.12))
        )
        .help(label)
    }

    /// Locale-aware compact format: "Apr 23, 22:03" in English (24h
    /// locales) or "23 abr, 22:03" in Spanish. `setLocalizedDateFormat`
    /// drops the year automatically + respects the user's clock style
    /// (12h vs 24h). `.medium` was returning the year + "at" filler
    /// which made every title overflow the 245 px card width in 2-col
    /// grids.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd jm")
        return f
    }()

    /// "1:23" for under an hour, "1:02:34" past it. Matches Quick Time
    /// Player's display so users feel at home.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }
}

