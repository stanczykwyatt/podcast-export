import Foundation
import SQLite3

public enum LibraryError: Error, Equatable {
    /// There's no Apple Podcasts library on this Mac yet.
    case notFound
    /// macOS blocked the read. Apple Podcasts' library needs Full Disk Access.
    case noPermission
    /// The library is there but laid out in a way this version doesn't know.
    case unrecognized(String)
}

/// Reads the Apple Podcasts library: the shows, and the episodes you've played, started or saved.
/// Nothing in the library is ever written to. The database is copied to a scratch folder and only
/// the copy is opened, so SQLite never touches the original or the journal Apple Podcasts is
/// writing to. Episode descriptions and transcripts are never read.
public struct PodcastLibrary: Sendable {
    /// Where Apple Podcasts keeps its library on macOS 14 and later, from the home folder.
    public static let relativePath = "Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Documents"
    static let database = "MTLibrary.sqlite"
    /// Far bigger than any real library's database, which holds titles, dates and links.
    static let databaseLimit = 1024 * 1024 * 1024
    /// Longer than any real episode; durations and positions past this are damage.
    public static let longest: Double = 30 * 86400

    public let folder: URL

    public init(folder: URL) {
        self.folder = folder.standardizedFileURL
    }

    public init(home: URL) {
        self.init(folder: home.appendingPathComponent(Self.relativePath, isDirectory: true))
    }

    /// The real home folder, even inside the App Sandbox, where `NSHomeDirectory()` is the container.
    public static var realHome: URL {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }

    // MARK: Reading

    /// Every show and every episode you've played, started or saved. `scratch` is a folder of the
    /// caller's own where the database is copied to be read.
    public func read(scratch: URL) throws -> Library {
        try checkAccess()
        let source = folder.appendingPathComponent(Self.database)
        guard FileManager.default.fileExists(atPath: source.path) else { throw LibraryError.notFound }
        let target = scratch.appendingPathComponent("Podcasts", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            throw LibraryError.unrecognized("Couldn't make a scratch folder: \(error.localizedDescription)")
        }
        // One read of the scratch copy at a time, so the app and the command line tool, or two
        // reads in the app, never replace each other's copy while it's open.
        let library = try FileLock.run(at: target.appendingPathComponent("copy.lock"), wait: true) {
            let copy = try copyDatabase(to: target)
            // The copy holds everything in the library, private feeds included, so it's emptied as
            // soon as it's been read rather than left in the temporary folder.
            defer { empty(target) }
            return try Self.read(database: copy)
        }
        guard let library else { throw LibraryError.unrecognized("Couldn't wait for the scratch copy of the Apple Podcasts database.") }
        return library
    }

    /// The folders nothing may ever be written into: the library, and the group container around
    /// it when it's where Apple Podcasts keeps it.
    public var protectedFolders: [URL] {
        let container = folder.deletingLastPathComponent()
        return container.lastPathComponent == "243LU875E5.groups.com.apple.podcasts" ? [folder, container] : [folder]
    }

    /// Empties the scratch copy and its log and index, leaving the files for the next read to fill.
    private func empty(_ target: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? Data().write(to: target.appendingPathComponent(Self.database + suffix))
        }
    }

    /// Throws `noPermission` if macOS won't let the library be read, and `notFound` if it isn't there.
    public func checkAccess() throws {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw LibraryError.notFound
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw LibraryError.noPermission
        } catch {
            let code = ((error as NSError).underlyingErrors.first as NSError?)?.code ?? (error as NSError).code
            if code == Int(EPERM) || code == Int(EACCES) { throw LibraryError.noPermission }
            if code == Int(ENOENT) { throw LibraryError.notFound }
            throw LibraryError.unrecognized(error.localizedDescription)
        }
    }

    /// Copies the database and its write-ahead log into `target`, where SQLite may write freely.
    /// The log holds everything since Apple Podcasts last folded it in, often the latest plays, so
    /// it has to come too. The two are read as a pair: if Apple Podcasts folded the log in or
    /// started a new one while they were being read, they're read again. The shared-memory index
    /// is left empty for SQLite to rebuild, since one copied mid-write might not match the log.
    func copyDatabase(to target: URL) throws -> URL {
        do {
            let copy = target.appendingPathComponent(Self.database)
            let log = folder.appendingPathComponent(Self.database + "-wal")
            var pair: (main: Data, log: Data)?
            for attempt in 0..<4 where pair == nil {
                // A moment between tries, so Apple Podcasts can finish saving.
                if attempt > 0 { usleep(250_000) }
                let before = snapshotStamp()
                let main = try readLimited(folder.appendingPathComponent(Self.database))
                let logData = FileManager.default.fileExists(atPath: log.path) ? try readLimited(log) : Data()
                if snapshotStamp() == before { pair = (main, logData) }
            }
            guard let (main, logData) = pair else {
                throw LibraryError.unrecognized("Apple Podcasts was busy saving. Try again in a moment.")
            }
            try main.write(to: copy, options: .atomic)
            try logData.write(to: target.appendingPathComponent(Self.database + "-wal"), options: .atomic)
            try Data().write(to: target.appendingPathComponent(Self.database + "-shm"), options: .atomic)
            return copy
        } catch let error as LibraryError {
            throw error
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw LibraryError.noPermission
        } catch {
            throw LibraryError.unrecognized("Couldn't copy the Apple Podcasts database: \(error.localizedDescription)")
        }
    }

    /// What changes when Apple Podcasts rewrites its database or starts a new log: the database's
    /// size and date, and the log's header, which holds a counter and salts that change each time.
    /// Pages added to the end of the log don't count, since a copy cut short there is still sound.
    func snapshotStamp() -> String {
        let main = try? folder.appendingPathComponent(Self.database).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var stamp = "\(main?.fileSize ?? -1) \(main?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)"
        if let handle = try? FileHandle(forReadingFrom: folder.appendingPathComponent(Self.database + "-wal")) {
            stamp += " " + ((try? handle.read(upToCount: 32)) ?? Data()).base64EncodedString()
            try? handle.close()
        }
        return stamp
    }

    private func readLimited(_ url: URL) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.databaseLimit else { throw LibraryError.unrecognized("The Apple Podcasts database is unexpectedly large.") }
        return try Data(contentsOf: url)
    }

    /// When the library last changed, from file dates alone, to tell cheaply whether there's
    /// anything new.
    public func lastChange() -> Date? {
        let key = URLResourceKey.contentModificationDateKey
        let urls = [folder, folder.appendingPathComponent(Self.database), folder.appendingPathComponent(Self.database + "-wal")]
        return urls.compactMap { try? $0.resourceValues(forKeys: [key]).contentModificationDate }.max()
    }

    // MARK: The database

    /// Reads the shows and episodes from a copy of the database.
    static func read(database url: URL) throws -> Library {
        let database = try SQLiteDatabase(url)
        let (shows, ids) = try readShows(database)
        let episodes = try readEpisodes(database, showIDs: ids, knownShows: Set(shows.map(\.id)))
        return Library(shows: shows.sorted { Library.order($0.title, $1.title) }, episodes: episodes)
    }

    /// The shows, and each row number's show ID, which episodes point to.
    static func readShows(_ database: SQLiteDatabase) throws -> (shows: [Show], ids: [Int64: String]) {
        let columns = try database.columns(of: "ZMTPODCAST")
        guard !columns.isEmpty else { throw LibraryError.unrecognized("The Apple Podcasts database has no shows table.") }
        for required in ["Z_PK", "ZTITLE", "ZFEEDURL", "ZSUBSCRIBED"] where !columns.contains(required) {
            throw LibraryError.unrecognized("The Apple Podcasts database has no \(required) column.")
        }
        func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        let query = """
            SELECT Z_PK, \(column("ZUUID")), ZTITLE, \(column("ZAUTHOR")), ZFEEDURL, \(column("ZUPDATEDFEEDURL")),
                   \(column("ZWEBPAGEURL")), \(column("ZSTORECOLLECTIONID")), ZSUBSCRIBED, \(column("ZISIMPLICITLYFOLLOWED")),
                   \(column("ZHIDDEN")), \(column("ZADDEDDATE"))
            FROM ZMTPODCAST ORDER BY Z_PK
            """
        var shows: [Show] = []
        var ids: [Int64: String] = [:]
        try database.each(query) { row in
            let pk = row.int(0)
            // The first of two rows with one ID wins, so each show is exported once, with the
            // episodes of both.
            let id = cleanID(row.text(1)) ?? "show-\(pk)"
            let duplicate = ids.values.contains(id)
            ids[pk] = id
            guard !duplicate else { return }
            let title = row.text(2)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let following = row.int(8) == 1 && row.int(9) != 1 && row.int(10) != 1
            shows.append(Show(
                id: id,
                title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled show",
                author: row.text(3)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                feedURL: Links.web(row.text(4)) ?? Links.web(row.text(5)),
                webURL: Links.web(row.text(6)),
                appleID: row.optionalInt(7).flatMap { $0 > 0 ? $0 : nil },
                following: following,
                added: date(row.double(11))
            ))
        }
        return (shows, ids)
    }

    /// The episodes you've listened to some of, or saved. Others are never read.
    static func readEpisodes(_ database: SQLiteDatabase, showIDs: [Int64: String], knownShows: Set<String>) throws -> [Episode] {
        let columns = try database.columns(of: "ZMTEPISODE")
        guard !columns.isEmpty else { throw LibraryError.unrecognized("The Apple Podcasts database has no episodes table.") }
        for required in ["Z_PK", "ZTITLE", "ZLASTDATEPLAYED"] where !columns.contains(required) {
            throw LibraryError.unrecognized("The Apple Podcasts database has no \(required) column.")
        }
        guard columns.contains("ZPODCAST") || columns.contains("ZPODCASTUUID") else {
            throw LibraryError.unrecognized("The Apple Podcasts database doesn't say which show an episode is from.")
        }
        func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        // Only episodes with some sign of listening or saving, so a library holding every
        // episode of every show isn't read in full.
        var signs = ["ZLASTDATEPLAYED > 0"]
        for name in ["ZPLAYCOUNT", "ZPLAYHEAD", "ZSAVED", "ZISBOOKMARKED"] where columns.contains(name) {
            signs.append("\(name) > 0")
        }
        let query = """
            SELECT Z_PK, \(column("ZUUID")), \(column("ZPODCAST")), \(column("ZPODCASTUUID")), ZTITLE, \(column("ZGUID")),
                   \(column("ZPUBDATE")), \(column("ZDURATION")), \(column("ZPLAYHEAD")), ZLASTDATEPLAYED, \(column("ZPLAYCOUNT")),
                   \(column("ZHASBEENPLAYED")), \(column("ZSAVED")), \(column("ZISBOOKMARKED")), \(column("ZLASTBOOKMARKEDDATE")),
                   \(column("ZWEBPAGEURL")), \(column("ZSTORETRACKID")), \(column("ZSEASONNUMBER")), \(column("ZEPISODENUMBER"))
            FROM ZMTEPISODE WHERE \(signs.joined(separator: " OR ")) ORDER BY Z_PK
            """
        var episodes: [Episode] = []
        var seen = Set<String>()
        try database.each(query) { row in
            let pk = row.int(0)
            // An episode whose show isn't in the library can't be placed, so it's left out.
            guard let showID = row.optionalInt(2).flatMap({ showIDs[$0] }) ?? cleanID(row.text(3)).flatMap({ knownShows.contains($0) ? $0 : nil }) else { return }
            let guid = row.text(5)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty.map { String($0.prefix(512)) }
            let id = cleanID(row.text(1)) ?? "episode-\(pk)"
            guard seen.insert(id).inserted else { return }
            let duration = seconds(row.double(7))
            let playCount = Int(min(max(row.optionalInt(10) ?? 0, 0), 100_000))
            let bookmarked = (row.optionalInt(13) ?? 0) > 0
            episodes.append(Episode(
                id: id,
                showID: showID,
                title: row.text(4)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Untitled episode",
                guid: guid,
                published: date(row.double(6)),
                duration: duration,
                position: seconds(row.double(8)),
                lastPlayed: date(row.double(9)),
                playCount: playCount,
                finished: (row.optionalInt(11) ?? 0) > 0 || playCount > 0,
                saved: (row.optionalInt(12) ?? 0) > 0 || bookmarked,
                savedDate: date(row.double(14)),
                webURL: Links.web(row.text(15)),
                appleID: row.optionalInt(16).flatMap { $0 > 0 ? $0 : nil },
                season: smallNumber(row.optionalInt(17)),
                number: smallNumber(row.optionalInt(18))
            ))
        }
        return episodes.sorted(by: Library.recent)
    }

    // MARK: Values

    /// A Core Data date, counted in seconds from the start of 2001, or nil if it's missing or far
    /// outside any real date. Zero, the very start of 2001, is how an empty date is sometimes stored.
    static func date(_ value: Double?) -> Date? {
        guard let value, value.isFinite, value > 0, value < 1e10 else { return nil }
        return Date(timeIntervalSinceReferenceDate: value)
    }

    static func seconds(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return min(max(value, 0), longest)
    }

    /// Season and episode numbers, which are small and positive when they're set at all.
    static func smallNumber(_ value: Int64?) -> Int? {
        guard let value, value > 0, value < 100_000 else { return nil }
        return Int(value)
    }

    /// An ID from the database, kept only if it's letters, digits, dashes and dots, so it's safe in
    /// file names, front matter and the export record.
    static func cleanID(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 128,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })
        else { return nil }
        return value
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Just enough of SQLite to read a few columns.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(_ url: URL) throws {
        // The copy is ours, so SQLite may write to it while folding in the log.
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK else {
            sqlite3_close(handle)
            throw LibraryError.unrecognized("Couldn't open the Apple Podcasts database (SQLite error \(status)).")
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    struct Row {
        let statement: OpaquePointer?

        func text(_ column: Int32) -> String? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL, let text = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: text)
        }

        func double(_ column: Int32) -> Double? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
        }

        func int(_ column: Int32) -> Int64 {
            sqlite3_column_int64(statement, column)
        }

        func optionalInt(_ column: Int32) -> Int64? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
        }
    }

    func each(_ query: String, _ body: (Row) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_finalize(statement)
            throw LibraryError.unrecognized("Couldn't read the Apple Podcasts database: \(message)")
        }
        defer { sqlite3_finalize(statement) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else {
                throw LibraryError.unrecognized("Couldn't read the Apple Podcasts database (SQLite error \(status)).")
            }
            try body(Row(statement: statement))
        }
    }

    /// The table's column names, or none if there's no such table.
    func columns(of table: String) throws -> Set<String> {
        var names = Set<String>()
        try each("PRAGMA table_info(\(table))") { row in
            if let name = row.text(1) { names.insert(name) }
        }
        return names
    }
}
