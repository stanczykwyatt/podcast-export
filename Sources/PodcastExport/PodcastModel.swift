import AppKit
import Observation
import PodcastCore

/// What the app knows about your podcasts, shared by the menu and the window. The library is read
/// off the main thread, and only again once Apple Podcasts has changed it.
@MainActor
@Observable
final class PodcastModel {
    enum Status: Equatable {
        case loading
        case ready
        case problem(LibraryError)
    }

    private(set) var status: Status = .loading
    private(set) var library = Library()
    private(set) var stats: [String: ShowStats] = [:]
    /// Episodes you've listened to that aren't in the export folder yet.
    private(set) var pending = 0
    private(set) var isExporting = false
    /// Why the last export stopped, if it did.
    private(set) var exportProblem: String?
    private(set) var failures: [ExportReport.Failure] = []
    /// Files you've edited that the last export left alone.
    private(set) var kept: [String] = []
    /// The last export kept the OPML file because Apple Podcasts listed far fewer shows than before.
    private(set) var keptOPML = false
    private(set) var folder: ExportFolder?
    /// The show shown in the window.
    var selection: String?

    /// Called after each export with what it did.
    var onExport: ((ExportReport) -> Void)?

    let source: PodcastLibrary
    let preferences: Preferences
    private let scratch: URL
    private var lastChange: Date?
    private var loading: Task<Void, Never>?

    init(source: PodcastLibrary, preferences: Preferences, scratch: URL, folder: ExportFolder? = nil) {
        self.source = source
        self.preferences = preferences
        self.scratch = scratch
        if let folder {
            self.folder = folder
        } else if let bookmark = preferences.folderBookmark, let resolved = ExportFolder.resolve(bookmark) {
            self.folder = resolved.folder
            if let refreshed = resolved.refreshed { preferences.folderBookmark = refreshed }
        }
    }

    var following: Int { library.following.count }
    var played: Int { library.history.count }
    var timeListened: Double { library.episodes.reduce(0) { $0 + $1.timeListened } }
    var lastExport: (date: Date, summary: String)? { preferences.lastExport }

    // MARK: Reading

    /// Reads the library again if Apple Podcasts has changed it since last time, or `force` is set.
    /// Returns whether it was read.
    @discardableResult
    func reload(force: Bool = false) async -> Bool {
        while let loading {
            await loading.value
            if !force { return false }
        }
        let change = source.lastChange()
        if !force, status == .ready, change == lastChange { return false }
        // The task clears itself before it finishes, so anyone waiting on it finds it gone and
        // never waits on a finished task again.
        let task = Task {
            await read(change: change)
            loading = nil
        }
        loading = task
        await task.value
        return true
    }

    private func read(change: Date?) async {
        let source = source, scratch = scratch
        let result = await Task.detached(priority: .utility) { () -> Result<Library, LibraryError> in
            do {
                return .success(try source.read(scratch: scratch))
            } catch let error as LibraryError {
                return .failure(error)
            } catch {
                return .failure(.unrecognized(error.localizedDescription))
            }
        }.value
        switch result {
        case .success(let library):
            self.library = library
            stats = ShowStats.all(library.episodes)
            status = .ready
            lastChange = change
            if let selection, library.show(selection) == nil { self.selection = nil }
        case .failure(let error):
            status = .problem(error)
            lastChange = nil
        }
        await refreshPending()
    }

    /// Counts what's new against the export record, off the main thread, since a long history
    /// makes for a big record.
    private func refreshPending() async {
        guard let folder, status == .ready else {
            pending = 0
            return
        }
        let library = library
        let result = await Task.detached(priority: .utility) { () -> Result<Int, ExportError> in
            folder.access { url in
                do {
                    return .success(try Exporter(destination: url).newPlays(library))
                } catch let error as ExportError {
                    return .failure(error)
                } catch {
                    return .failure(.cannotWrite(error.localizedDescription))
                }
            }
        }.value
        switch result {
        case .success(let count):
            pending = count
        case .failure(let error):
            pending = 0
            exportProblem = Describe.problem(error)
        }
    }

    // MARK: Exporting

    func setFolder(_ url: URL) async {
        exportProblem = nil
        failures = []
        kept = []
        folder = ExportFolder(url: url, scoped: false)
        // Reopened from the bookmark, so later exports work after a relaunch the same way.
        if let bookmark = ExportFolder.bookmark(for: url), let resolved = ExportFolder.resolve(bookmark) {
            preferences.folderBookmark = bookmark
            folder = resolved.folder
        } else {
            exportProblem = "macOS didn't let Podcast Export remember this folder, so you'll need to choose it again after Podcast Export quits."
        }
        await refreshPending()
    }

    /// Exports what's new into the folder. Returns nil if there's no folder, the library can't be
    /// read, or an export is already running.
    @discardableResult
    func export(now: Date = Date()) async -> ExportReport? {
        guard let folder, status == .ready, !isExporting else { return nil }
        isExporting = true
        exportProblem = nil
        failures = []
        let library = library, options = preferences.options, protected = source.protectedFolders
        let result = await Task.detached(priority: .utility) { () -> Result<ExportReport, ExportError> in
            folder.access { url in
                do {
                    return .success(try Exporter(destination: url, options: options).export(library, protected: protected, now: now))
                } catch let error as ExportError {
                    return .failure(error)
                } catch {
                    return .failure(.cannotWrite(error.localizedDescription))
                }
            }
        }.value
        isExporting = false
        await refreshPending()
        switch result {
        case .success(let report):
            failures = report.failed
            kept = report.kept
            keptOPML = report.keptOPML
            preferences.lastExport = (now, Describe.summary(report))
            onExport?(report)
            return report
        case .failure(let error):
            exportProblem = Describe.problem(error)
            return nil
        }
    }

    /// Writes the shows you follow as OPML to a file you picked in a save dialog.
    func saveOPML(to url: URL, now: Date = Date()) -> String? {
        do {
            try Exporter.saveOPML(library, to: url, protected: source.protectedFolders, now: now)
            return nil
        } catch let error as ExportError {
            return Describe.problem(error)
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Copying

    /// Puts a show's feed address on the clipboard, to follow it in another app. A private feed is
    /// marked as concealed, which tells clipboard managers not to keep it.
    @discardableResult
    func copyFeed(_ show: Show, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let feed = show.feedURL else { return false }
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.declareTypes(show.hasPrivateFeed ? [.string, concealed] : [.string], owner: nil)
        if show.hasPrivateFeed { pasteboard.setString("", forType: concealed) }
        return pasteboard.setString(feed, forType: .string)
    }
}
