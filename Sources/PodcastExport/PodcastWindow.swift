import AppKit
import PodcastCore
import SwiftUI

/// The main window: every show you follow or have played, searchable, with each one's episodes,
/// how far you got, and how much you've listened.
struct PodcastView: View {
    @Bindable var model: PodcastModel
    var home = PodcastLibrary.realHome
    var now: () -> Date = Date.init
    var export: () -> Void = {}
    var chooseFolder: () -> Void = {}
    var openPrivacySettings: () -> Void = {}
    /// The selected show's color. Your accent color in the app; a fixed blue in the screenshots.
    var selectionColor = Color.accentColor
    var renderer = Renderer()

    @State var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch model.status {
            case .loading:
                ProgressView("Reading Apple Podcasts…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .problem(let error):
                problem(error)
            case .ready:
                // Searched once per redraw and shared by the list and the episodes.
                let shown = Search.run(query, in: model.library)
                if shown.isEmpty && query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView {
                        Label("No shows yet", systemImage: "list.bullet.circle")
                    } description: {
                        Text("Shows you follow in Apple Podcasts, and episodes you play, on this Mac or synced from your iPhone, show up here.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        list(shown).frame(width: 300)
                        Divider()
                        detail(selected(in: shown)).frame(maxWidth: .infinity)
                    }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 440)
        // The window draws this anyway; drawing it here too keeps off-screen renders right in dark mode.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status == .ready ? Describe.count(model.following, "show") + " followed" : "Podcast Export")
                    .font(.title2.weight(.semibold))
                if model.status == .ready {
                    Text("\(Describe.count(model.played, "episode")) played · \(Describe.listened(model.timeListened)) listened")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if model.status == .ready {
                search
            }
            if model.folder == nil {
                Button("Choose Export Folder…", action: chooseFolder)
                    .disabled(model.status != .ready)
            } else {
                Button(action: export) {
                    Text(model.isExporting ? "Exporting…" : model.pending > 0 ? "Export \(Describe.count(model.pending, "New Play"))" : "Export Now")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.status != .ready || model.isExporting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search shows and episodes", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 250)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let problem = model.exportProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if let folder = model.folder {
                Label("Exporting to \(Describe.path(folder.url, home: home))", systemImage: "folder")
                if let last = model.lastExport {
                    Text("· last export \(Describe.relative(last.date, now: now()))")
                }
            } else {
                Label("Choose a folder, like one in your Obsidian vault, to export to.", systemImage: "folder.badge.plus")
            }
            Spacer()
            Text("Read-only: Apple Podcasts is never changed.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func problem(_ error: LibraryError) -> some View {
        if error == .noPermission {
            ContentUnavailableView {
                Label("Turn on Full Disk Access", systemImage: "lock.shield")
            } description: {
                Text("macOS keeps Apple Podcasts' library private. Turn on Podcast Export in System Settings → Privacy & Security → Full Disk Access, then come back here. The App Sandbox still keeps it to Apple Podcasts' library, read-only, and the folder you choose.")
            } actions: {
                Button("Open Privacy & Security Settings…", action: openPrivacySettings)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Can't read Apple Podcasts", systemImage: "exclamationmark.circle")
            } description: {
                Text(Describe.problem(error))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: The list

    private func selected(in shown: [Search.Result]) -> Search.Result? {
        if let id = model.selection, let match = shown.first(where: { $0.show.id == id }) { return match }
        return shown.first
    }

    private func list(_ shown: [Search.Result]) -> some View {
        let current = selected(in: shown)?.show.id
        return ScrollView {
            VStack(spacing: 2) {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(shown.isEmpty ? "Nothing matches \"\(query)\"" : "\(Describe.count(shown.count, "show")) \(shown.count == 1 ? "matches" : "match") \"\(query)\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                ForEach(shown, id: \.show.id) { result in
                    row(result, selected: result.show.id == current)
                }
            }
            .padding(8)
        }
    }

    private func row(_ result: Search.Result, selected: Bool) -> some View {
        let show = result.show
        let stat = model.stats[show.id] ?? ShowStats([])
        var details = ["\(stat.played) played"]
        if stat.played > 0 { details.append(Describe.duration(stat.timeListened)) }
        if !show.following { details.append("not following") }
        return Button {
            model.selection = show.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(show.title).font(.body.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    if show.following && show.feedURL == nil {
                        Image(systemName: "exclamationmark.circle").help("No public feed, so other apps can't follow it")
                    } else if show.hasPrivateFeed {
                        Image(systemName: "key").help("A private feed: keep the OPML file to yourself")
                    }
                }
                Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                if !query.isEmpty, !result.showMatches, let episode = result.episodes.first {
                    Text(highlighted(episode.title, around: query))
                        .font(.caption)
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? selectionColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: The show

    @ViewBuilder
    private func detail(_ result: Search.Result?) -> some View {
        if let result {
            let show = result.show
            let stat = model.stats[show.id] ?? ShowStats([])
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(show.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text(subtitle(show)).font(.callout).foregroundStyle(.secondary)
                        if stat.played > 0 {
                            Text(summary(stat)).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 12)
                    if show.feedURL != nil {
                        Button("Copy Feed Address") { model.copyFeed(show) }
                            .help(show.hasPrivateFeed ? "This feed's address holds a personal key. Paste it only into your own podcast app." : "Paste it into another podcast app to follow the show there.")
                    }
                }
                .padding(16)
                Divider()
                if result.episodes.isEmpty {
                    ContentUnavailableView {
                        Label("No episodes played yet", systemImage: "circle.dashed")
                    } description: {
                        Text("Episodes you play or save in Apple Podcasts show up here, and in the show's exported note.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(result.episodes) { episode in
                                episodeRow(episode)
                                Divider().opacity(0.5)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
                }
            }
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    private func episodeRow(_ episode: Episode) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(episode.lastPlayed.map(renderer.day) ?? "")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if episode.saved {
                        Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(.secondary).help("Saved")
                    }
                    Text(highlighted(episode.title, around: query)).lineLimit(2).textSelection(.enabled)
                }
                if episode.duration > 0 || episode.published != nil {
                    Text([episode.published.map { "Published \(renderer.day($0))" }, episode.duration > 0 ? Describe.duration(episode.duration) : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            progress(episode)
        }
        .padding(.vertical, 8)
    }

    /// How far through: a short bar and the words for it.
    private func progress(_ episode: Episode) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(Describe.status(episode)).font(.caption).foregroundStyle(.secondary)
            if episode.listened {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(episode.finished ? Color.secondary.opacity(0.7) : selectionColor)
                        .frame(width: max(4, 72 * episode.progress))
                }
                .frame(width: 72, height: 4)
            }
        }
        .frame(width: 96, alignment: .trailing)
    }

    private func subtitle(_ show: Show) -> String {
        var parts: [String] = []
        if let author = show.author { parts.append(author) }
        if show.following {
            if let added = show.added {
                let formatter = DateFormatter()
                formatter.dateStyle = .long
                formatter.timeStyle = .none
                parts.append("following since \(formatter.string(from: added))")
            } else {
                parts.append("following")
            }
        } else {
            parts.append("not following")
        }
        if show.following && show.feedURL == nil { parts.append("no public feed") }
        return parts.joined(separator: " · ")
    }

    private func summary(_ stat: ShowStats) -> String {
        var parts = ["\(Describe.count(stat.played, "episode")) played", "\(Describe.listened(stat.timeListened)) listened"]
        if let last = stat.lastPlayed { parts.append("last played \(Describe.relative(last, now: now()))") }
        return parts.joined(separator: " · ")
    }

    /// The text with the searched words in bold and tinted.
    private func highlighted(_ text: String, around query: String) -> AttributedString {
        var out = AttributedString()
        var cursor = text.startIndex
        for range in Search.ranges(of: query, in: text) where range.lowerBound >= cursor {
            out += AttributedString(text[cursor..<range.lowerBound])
            var match = AttributedString(text[range])
            match.font = .body.bold()
            match.backgroundColor = Color.yellow.opacity(0.35)
            out += match
            cursor = range.upperBound
        }
        out += AttributedString(text[cursor...])
        return out
    }
}

/// The window, made the first time it's opened and kept for next time.
@MainActor
final class PodcastWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let makeView: () -> PodcastView
    /// Called when you close the window.
    var onClose: (() -> Void)?
    /// Called when the window comes to the front.
    var onActivate: (() -> Void)?

    init(makeView: @escaping () -> PodcastView) {
        self.makeView = makeView
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onActivate?()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: makeView()))
        window.title = "Podcast Export"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 900, height: 600))
        if !window.setFrameUsingName("PodcastWindow") {
            window.center()
        }
        window.setFrameAutosaveName("PodcastWindow")
        return window
    }
}
