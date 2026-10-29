import CryptoKit
import Foundation

public struct ExportOptions: Equatable, Sendable {
    /// An overview note and a note for each show.
    public var markdown = true
    public var csv = true
    public var json = false
    public var renderer = Renderer()

    public init(markdown: Bool = true, csv: Bool = true, json: Bool = false, renderer: Renderer = Renderer()) {
        self.markdown = markdown
        self.csv = csv
        self.json = json
        self.renderer = renderer
    }

    public static func == (a: ExportOptions, b: ExportOptions) -> Bool {
        a.markdown == b.markdown && a.csv == b.csv && a.json == b.json && a.renderer.links == b.renderer.links
    }
}

/// What an export did.
public struct ExportReport: Equatable, Sendable {
    public struct Failure: Equatable, Sendable {
        public var file: String
        public var reason: String
    }

    /// Episodes you'd listened to that weren't in the export yet.
    public var newPlays = 0
    /// Shows you follow that weren't in the export yet.
    public var newShows = 0
    /// Files written or brought up to date, from the export folder.
    public var written: [String] = []
    /// Files you've edited, which are left as they are.
    public var kept: [String] = []
    public var failed: [Failure] = []
    /// Shows you follow that have no web feed, like ones only Apple hosts, so other apps can't follow them.
    public var withoutFeed: [String] = []
    /// Shows in the OPML file whose feed address holds a password or key.
    public var privateFeeds = 0
    /// Apple Podcasts listed none or far fewer of the shows you follow than last time, as it does
    /// while it's still loading or syncing, so the last OPML file was kept rather than shrunk, and
    /// no show was marked unfollowed.
    public var keptOPML = false

    public init() {}
}

public enum ExportError: Error, Equatable {
    /// The chosen folder is inside the Apple Podcasts library, which is never written to.
    case insideLibrary
    /// The folder's export record can't be read, so exporting could lose the history it holds.
    case unreadableRecord
    /// The export record was written by a newer version.
    case newerRecord
    /// Another export into the same folder is running, like the app and the command line tool at once.
    case busy
    case cannotWrite(String)
}

/// What's been exported to a folder, kept in the folder itself as `.podcast-export.json`. It holds
/// every show and play exported so far, so history Apple Podcasts later forgets, like after you
/// unfollow a show, stays in the export. And it holds what each file was when it was written, so
/// a file you've edited is never overwritten.
struct ExportRecord: Codable, Equatable {
    static let currentVersion = 1

    struct File: Codable, Equatable {
        /// From the export folder, with its extension.
        var path: String
        /// The SHA-256 of the file as last written, to tell whether you've edited it since.
        var hash: String
        /// The SHA-256 of what it says, leaving out what changes on every write, like the OPML
        /// file's date, so it's only rewritten when something in it changed.
        var source: String
    }

    var version = currentVersion
    /// Without private feed addresses, which only ever go in the OPML file.
    var shows: [String: Show] = [:]
    var episodes: [String: Episode] = [:]
    /// By what the file is: `opml`, `overview`, `csv`, `json`, or `show:` and the show's ID.
    var files: [String: File] = [:]
}

/// Exports the library into a folder: the shows you follow as OPML, an overview note and a note
/// for each show, and your listening history as CSV and JSON. A file you've edited is never
/// overwritten, and nothing is ever deleted.
public struct Exporter: Sendable {
    public static let recordName = ".podcast-export.json"
    static let lockName = ".podcast-export.lock"
    static let opmlName = "Podcasts.opml"
    static let overviewName = "Podcasts.md"
    static let historyName = "Listening History"
    static let showsFolder = "Shows"
    /// Far bigger than any real record or note; anything bigger isn't one of ours.
    static let readLimit = 256 * 1024 * 1024

    public let destination: URL
    public var options: ExportOptions

    public init(destination: URL, options: ExportOptions = ExportOptions()) {
        self.destination = destination.standardizedFileURL
        self.options = options
    }

    /// Exports what's new or changed since the last run. Nothing is written inside any of the
    /// `protected` folders, like the Apple Podcasts library.
    public func export(_ library: Library, protected: [URL] = [], now: Date = Date()) throws -> ExportReport {
        if protected.contains(where: { Self.isInside(destination, $0) }) { throw ExportError.insideLibrary }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let report = try FileLock.run(at: destination.appendingPathComponent(Self.lockName), wait: false) {
                try run(library, protected: protected, now: now)
            }
            guard let report else { throw ExportError.busy }
            return report
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.cannotWrite(error.localizedDescription)
        }
    }

    /// How many episodes you've listened to that aren't in the export yet. Throws if the folder's
    /// record can't be read.
    public func newPlays(_ library: Library) throws -> Int {
        let record = try loadRecord()
        let known = record.episodes
        return Self.matched(library, to: record).episodes.filter { $0.listened && known[$0.id]?.listened != true }.count
    }

    private func run(_ library: Library, protected: [URL], now: Date) throws -> ExportReport {
        var record = try loadRecord()
        var report = ExportReport()
        // A shrunken library only counts as one while the last OPML file is still there. Delete it
        // and the next export takes the library as it is.
        let opmlThere = record.files["opml"].map { FileManager.default.fileExists(atPath: destination.appendingPathComponent($0.path).path) } ?? false
        let incomplete = opmlThere && Self.looksIncomplete(library, comparedTo: record)
        Self.merge(Self.matched(library, to: record), into: &record, incomplete: incomplete, report: &report)
        let renderer = options.renderer
        let shows = Array(record.shows.values), episodes = Array(record.episodes.values)
        var taken = Set(record.files.values.map { $0.path.lowercased() })

        // Every show you follow or have played or saved has a note. Their paths are settled
        // first, so the overview can link to them.
        var notes: [String: String] = [:]
        var noted: [Show] = []
        if options.markdown {
            let stats = ShowStats.all(episodes)
            noted = shows.filter { $0.following || (stats[$0.id]?.played ?? 0) > 0 || (stats[$0.id]?.saved ?? 0) > 0 }
                .sorted { ($0.title.lowercased(), $0.id) < ($1.title.lowercased(), $1.id) }
            for show in noted {
                let path = record.files["show:\(show.id)"]?.path
                    ?? Self.unique(Self.showsFolder + "/" + Renderer.safeName(show.title), ext: "md", in: destination, taken: &taken)
                notes[show.id] = String(path.dropLast(3))
            }
        }
        var files = Writer(destination: destination, protected: protected, record: record, taken: taken)

        // The OPML file is made from the library itself, since it's the one place a private
        // feed's address is written.
        let following = library.following
        report.withoutFeed = following.filter { $0.feedURL == nil }.map(\.title)
        report.privateFeeds = following.filter { $0.feedURL != nil && $0.hasPrivateFeed }.count
        if incomplete {
            report.keptOPML = true
        } else {
            files.write(key: "opml", path: Self.opmlName, content: renderer.opml(library.shows, created: now),
                        source: renderer.opml(library.shows, created: nil), recreate: true, report: &report)
        }
        if options.markdown {
            let overview = renderer.overview(shows: shows, episodes: episodes, notes: notes)
            files.write(key: "overview", path: Self.overviewName, content: overview, source: overview, recreate: true, report: &report)
            for show in noted {
                let note = renderer.showNote(show, episodes: episodes)
                files.write(key: "show:\(show.id)", path: (notes[show.id] ?? show.id) + ".md", content: note, source: note,
                            recreate: false, settled: true, report: &report)
            }
        }
        if options.csv {
            let csv = renderer.csv(shows: shows, episodes: episodes)
            files.write(key: "csv", path: Self.historyName + ".csv", content: csv, source: csv, recreate: true, report: &report)
        }
        if options.json {
            let json = renderer.json(shows: shows, episodes: episodes)
            files.write(key: "json", path: Self.historyName + ".json", content: json, source: json, recreate: true, report: &report)
        }
        try saveRecord(files.record)
        return report
    }

    // MARK: Merging

    /// Whether the library looks like Apple Podcasts hasn't finished loading or syncing it: no
    /// shows at all when the export had some, or fewer than half the shows you followed last time.
    static func looksIncomplete(_ library: Library, comparedTo record: ExportRecord) -> Bool {
        if library.shows.isEmpty && !record.shows.isEmpty { return true }
        let before = record.shows.values.filter(\.following).count
        return before >= 4 && library.following.count * 2 < before
    }

    /// The library with its IDs changed to the ones already in the record where it's clearly the
    /// same show or episode under a new ID, as after moving to a new Mac or Apple Podcasts
    /// rebuilding its library: a show with the same Apple Podcasts ID or feed, and an episode of
    /// that show with the same feed ID. Only shows and episodes the library no longer has under
    /// their old IDs are matched, so two that are both there are never merged.
    static func matched(_ library: Library, to record: ExportRecord) -> Library {
        let present = Set(library.shows.map(\.id))
        var orphans = record.shows.values.filter { !present.contains($0.id) }
        var renamed: [String: String] = [:]
        var library = library
        for index in library.shows.indices where record.shows[library.shows[index].id] == nil {
            let show = library.shows[index]
            let match = orphans.firstIndex { old in
                (show.appleID != nil && old.appleID == show.appleID) || (show.publicFeedURL != nil && old.feedURL == show.publicFeedURL)
            }
            guard let match else { continue }
            renamed[show.id] = orphans[match].id
            library.shows[index].id = orphans.remove(at: match).id
        }
        let current = Set(library.episodes.map(\.id))
        var byGUID: [String: String] = [:]
        for old in record.episodes.values where !current.contains(old.id) {
            if let guid = old.guid { byGUID[old.showID + "\u{1F}" + guid] = old.id }
        }
        for index in library.episodes.indices {
            if let id = renamed[library.episodes[index].showID] { library.episodes[index].showID = id }
            let episode = library.episodes[index]
            guard record.episodes[episode.id] == nil, let guid = episode.guid,
                  let old = byGUID.removeValue(forKey: episode.showID + "\u{1F}" + guid) else { continue }
            library.episodes[index].id = old
        }
        return library
    }

    /// Adds the library to what's been exported before. Nothing exported is ever dropped: a play
    /// keeps its latest date and highest count, and a finished episode stays finished, even if
    /// Apple Podcasts later forgets it. Saved is the one state that's undone, when an episode
    /// leaves your saved episodes. An `incomplete` library, one Apple Podcasts is still loading,
    /// adds what it has but undoes nothing.
    static func merge(_ library: Library, into record: inout ExportRecord, incomplete: Bool = false, report: inout ExportReport) {
        if !incomplete && !(library.shows.isEmpty && !record.shows.isEmpty) {
            let present = Set(library.shows.map(\.id))
            for id in record.shows.keys where !present.contains(id) { record.shows[id]?.following = false }
            // No episodes at all, when some were saved, is the library still loading too.
            if !library.episodes.isEmpty {
                let current = Set(library.episodes.map(\.id))
                for id in record.episodes.keys where !current.contains(id) { record.episodes[id]?.saved = false }
            }
        }
        for show in library.shows {
            var merged = show.redacted
            if let old = record.shows[show.id] {
                merged.added = show.added ?? old.added
                merged.appleID = show.appleID ?? old.appleID
            } else if show.following {
                report.newShows += 1
            }
            record.shows[show.id] = merged
        }
        for episode in library.episodes {
            guard let old = record.episodes[episode.id] else {
                record.episodes[episode.id] = episode
                if episode.listened { report.newPlays += 1 }
                continue
            }
            if episode.listened && !old.listened { report.newPlays += 1 }
            var merged = episode
            merged.lastPlayed = [old.lastPlayed, episode.lastPlayed].compactMap { $0 }.max()
            merged.playCount = max(old.playCount, episode.playCount)
            merged.finished = old.finished || episode.finished
            if !episode.listened && old.listened { merged.position = old.position }
            if episode.duration <= 0 { merged.duration = old.duration }
            merged.guid = episode.guid ?? old.guid
            merged.published = episode.published ?? old.published
            merged.webURL = episode.webURL ?? old.webURL
            merged.appleID = episode.appleID ?? old.appleID
            merged.season = episode.season ?? old.season
            merged.number = episode.number ?? old.number
            record.episodes[episode.id] = merged
        }
    }

    // MARK: Writing files

    /// Writes files into the export folder, never over one you've edited.
    struct Writer {
        let destination: URL
        let protected: [URL]
        var record: ExportRecord
        var taken: Set<String>

        /// Writes `content` as the file known by `key`. A new file goes at `path`, or the next free
        /// name beside it if something is already there. A file written before is rewritten only
        /// if what it says changed and it's exactly as it was written; one you've edited is left
        /// alone. With `recreate`, a file you've deleted is written again, as the OPML and history
        /// files are; show notes you delete stay deleted. A `settled` path is already known to be free.
        mutating func write(
            key: String, path: String, content: String, source: String, recreate: Bool, settled: Bool = false, report: inout ExportReport
        ) {
            let data = Data(content.utf8)
            let made = Exporter.hash(Data(source.utf8))
            do {
                if let entry = record.files[key] {
                    let url = destination.appendingPathComponent(entry.path)
                    try checkWritable(url.deletingLastPathComponent())
                    if FileManager.default.fileExists(atPath: url.path) {
                        guard entry.source != made else { return }
                        guard let existing = Exporter.readLimited(url), Exporter.hash(existing) == entry.hash else {
                            // Said once for each change it would have made, not on every run after.
                            record.files[key]?.source = made
                            report.kept.append(entry.path)
                            return
                        }
                        try data.write(to: url, options: .atomic)
                    } else {
                        guard recreate else { return }
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: url, options: .withoutOverwriting)
                    }
                    record.files[key] = .init(path: entry.path, hash: Exporter.hash(data), source: made)
                    report.written.append(entry.path)
                } else {
                    let ext = (path as NSString).pathExtension
                    // A show note's path was settled already; anything else finds its own free name.
                    let free = settled ? path : Exporter.unique(String(path.dropLast(ext.count + 1)), ext: ext, in: destination, taken: &taken)
                    let url = destination.appendingPathComponent(free)
                    try checkWritable(url.deletingLastPathComponent())
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .withoutOverwriting)
                    record.files[key] = .init(path: free, hash: Exporter.hash(data), source: made)
                    report.written.append(free)
                }
            } catch {
                report.failed.append(.init(file: record.files[key]?.path ?? path, reason: error.localizedDescription))
            }
        }

        /// Makes sure `folder` is inside the export folder and outside every protected one, after
        /// following links, before anything is written there.
        private func checkWritable(_ folder: URL) throws {
            guard Exporter.isInside(folder, destination), !protected.contains(where: { Exporter.isInside(folder, $0) }) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "Its folder is outside the export folder or inside Apple Podcasts."])
            }
        }
    }

    /// `base` with `ext`, or with a number added if a file of yours or another export's file
    /// already has that name. Names are compared ignoring case, as the Mac does.
    static func unique(_ base: String, ext: String, in destination: URL, taken: inout Set<String>) -> String {
        var number = 1
        while true {
            let name = (number == 1 ? base : "\(base) (\(number))") + "." + ext
            if !taken.contains(name.lowercased()) && !FileManager.default.fileExists(atPath: destination.appendingPathComponent(name).path) {
                taken.insert(name.lowercased())
                return name
            }
            number += 1
        }
    }

    // MARK: Saving OPML on its own

    /// Writes the shows you follow as OPML to a file you chose in a save dialog, replacing it if
    /// you said to. Never inside a protected folder.
    public static func saveOPML(_ library: Library, to url: URL, protected: [URL], renderer: Renderer = Renderer(), now: Date = Date()) throws {
        guard !protected.contains(where: { isInside(url, $0) }) else { throw ExportError.insideLibrary }
        do {
            try Data(renderer.opml(library.shows, created: now).utf8).write(to: url, options: .atomic)
        } catch {
            throw ExportError.cannotWrite(error.localizedDescription)
        }
    }

    // MARK: Record

    var recordURL: URL { destination.appendingPathComponent(Self.recordName) }

    func loadRecord() throws -> ExportRecord {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return ExportRecord() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = Self.readLimited(recordURL) else { throw ExportError.unreadableRecord }
        if let version = try? decoder.decode(Version.self, from: data).version, version > ExportRecord.currentVersion {
            throw ExportError.newerRecord
        }
        guard var record = try? decoder.decode(ExportRecord.self, from: data),
              record.files.values.allSatisfy({ Self.isSafePath($0.path) }),
              record.shows.allSatisfy({ $0.key == $0.value.id }), record.episodes.allSatisfy({ $0.key == $0.value.id })
        else { throw ExportError.unreadableRecord }
        record.shows = record.shows.mapValues(\.rechecked)
        return record
    }

    private struct Version: Decodable {
        var version: Int
    }

    func saveRecord(_ record: ExportRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(record).write(to: recordURL, options: .atomic)
        } catch {
            throw ExportError.cannotWrite(error.localizedDescription)
        }
    }

    /// Whether a path from the record stays inside the export folder: a file name, or a folder
    /// and a file name, with nothing that climbs out or hides.
    static func isSafePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !path.contains("\0"), !path.contains("\\") else { return false }
        return parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") }
    }

    // MARK: Helpers

    static func readLimited(_ url: URL) -> Data? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= readLimit else { return nil }
        return try? Data(contentsOf: url)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `url` is `folder` or inside it, after following symbolic links.
    public static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = resolved(url).lowercased(), base = resolved(folder).lowercased()
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// The path with every link followed, including links above a folder that doesn't exist yet.
    static func resolved(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var path = existing.resolvingSymlinksInPath().path
        for component in rest { path = (path as NSString).appendingPathComponent(component) }
        return path
    }
}
