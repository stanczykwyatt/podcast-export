import Foundation

/// The `podcast-export` command line tool: list shows and plays, print the OPML, or export it all
/// to a folder. It does the same as the app, for scripts, cron jobs and Shortcuts.
public enum Command: Equatable {
    case shows(json: Bool)
    case history(json: Bool, limit: Int?)
    case opml
    case export(folder: String, options: ExportOptions)
    case help
    case version

    public static let toolVersion = "0.1.0"

    public static let usage = """
        podcast-export \(toolVersion): export your Apple Podcasts shows as OPML, and your listening history.

        Usage:
          podcast-export shows [--json]             Shows you follow or have played, with how much
          podcast-export history [--limit <n>]      Episodes you've played, most recent first
          podcast-export history --json             Every show and episode as JSON
          podcast-export opml                       Print the shows you follow as OPML
          podcast-export export <folder>            Export what's new into <folder>

        Export options:
          --no-markdown      Don't write the overview and show notes
          --no-csv           Don't write Listening History.csv
          --json             Also write Listening History.json
          --markdown-links   Link notes with [Show](<Shows/Show.md>), not Obsidian's [[Shows/Show|Show]]

          --library <folder> Read another Apple Podcasts library folder, like a backup
          --help, --version

        Reading Apple Podcasts needs Full Disk Access for your terminal app, in System Settings →
        Privacy & Security → Full Disk Access. Nothing in Apple Podcasts is ever changed.
        """

    public enum ParseError: Error, Equatable {
        case message(String)
    }

    /// The command, and the library folder if one was given.
    public static func parse(_ arguments: [String]) throws -> (Command, library: String?) {
        var rest: [String] = []
        var library: String?
        var limit: Int?
        var flags = Set<String>()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--library" || argument == "--limit" {
                guard index + 1 < arguments.count else { throw ParseError.message("\(argument) needs a value.") }
                let value = arguments[index + 1]
                if argument == "--library" {
                    library = value
                } else {
                    guard let number = Int(value), number > 0 else { throw ParseError.message("--limit needs a number above 0.") }
                    limit = number
                    flags.insert(argument)
                }
                index += 2
                continue
            }
            if argument.hasPrefix("--") { flags.insert(argument) } else if argument == "-h" { flags.insert("--help") } else { rest.append(argument) }
            index += 1
        }
        if flags.contains("--help") { return (.help, library) }
        if flags.contains("--version") { return (.version, library) }
        guard let name = rest.first else { return (.help, library) }

        func allow(_ allowed: Set<String>) throws {
            if let unknown = flags.subtracting(allowed).sorted().first {
                throw ParseError.message("Unknown option \(unknown) for \(name). See podcast-export --help.")
            }
        }
        switch name {
        case "shows":
            try allow(["--json"])
            guard rest.count == 1 else { throw ParseError.message("shows takes no arguments.") }
            return (.shows(json: flags.contains("--json")), library)
        case "history":
            try allow(["--json", "--limit"])
            guard rest.count == 1 else { throw ParseError.message("history takes no arguments.") }
            return (.history(json: flags.contains("--json"), limit: limit), library)
        case "opml":
            try allow([])
            guard rest.count == 1 else { throw ParseError.message("opml takes no arguments. To save it, use podcast-export opml > Podcasts.opml") }
            return (.opml, library)
        case "export":
            try allow(["--no-markdown", "--no-csv", "--json", "--markdown-links"])
            guard rest.count == 2 else { throw ParseError.message("export needs one folder to export into.") }
            let options = ExportOptions(
                markdown: !flags.contains("--no-markdown"),
                csv: !flags.contains("--no-csv"),
                json: flags.contains("--json"),
                renderer: Renderer(links: flags.contains("--markdown-links") ? .markdown : .obsidian)
            )
            return (.export(folder: rest[1], options: options), library)
        default:
            throw ParseError.message("Unknown command \(name). See podcast-export --help.")
        }
    }

    /// Runs the tool. Returns the exit status: 0 on success, 1 when something failed, 2 for a mistake in the arguments.
    public static func run(
        _ arguments: [String], home: URL = PodcastLibrary.realHome, workingDirectory: URL,
        scratch: URL = FileManager.default.temporaryDirectory.appendingPathComponent("podcast-export", isDirectory: true),
        renderer: Renderer = Renderer(), now: Date = Date(),
        out rawOut: (String) -> Void, err rawErr: (String) -> Void
    ) -> Int32 {
        // Titles come from the shows' feeds, so nothing in them reaches the terminal that it would
        // read as a command, like an escape sequence that sets the clipboard.
        func out(_ text: String) { rawOut(Renderer.visible(text)) }
        func err(_ text: String) { rawErr(Renderer.visible(text)) }
        let command: Command, libraryPath: String?
        do {
            (command, libraryPath) = try parse(arguments)
        } catch ParseError.message(let message) {
            err(message)
            return 2
        } catch {
            return 2
        }
        func resolve(_ path: String) -> URL {
            let expanded = path == "~" ? home.path : path.hasPrefix("~/") ? home.path + path.dropFirst(1) : path
            return URL(fileURLWithPath: expanded, relativeTo: workingDirectory).standardizedFileURL
        }
        let source = libraryPath.map { PodcastLibrary(folder: resolve($0)) } ?? PodcastLibrary(home: home)

        switch command {
        case .help:
            out(usage)
            return 0
        case .version:
            out("podcast-export \(toolVersion)")
            return 0
        default:
            break
        }

        let library: Library
        do {
            library = try source.read(scratch: scratch)
        } catch let error as LibraryError {
            err(error == .noPermission
                ? "Your terminal needs Full Disk Access to read Apple Podcasts. Turn it on in System Settings → Privacy & Security → Full Disk Access, then open a new terminal window."
                : Describe.problem(error))
            return 1
        } catch {
            err(error.localizedDescription)
            return 1
        }
        let stats = ShowStats.all(library.episodes)

        switch command {
        case .shows(let json):
            let shows = library.shows.filter { $0.following || (stats[$0.id]?.played ?? 0) > 0 }
            if json {
                let items = shows.map { show in
                    let stat = stats[show.id] ?? ShowStats([])
                    return [
                        "id": show.id, "title": show.title, "author": show.author as Any? ?? NSNull(),
                        "feed_url": show.publicFeedURL as Any? ?? NSNull(), "private_feed": show.hasPrivateFeed,
                        "following": show.following, "episodes_played": stat.played,
                        "seconds_listened": Int(stat.timeListened.rounded()),
                        "last_played": stat.lastPlayed.map(renderer.isoDate) as Any? ?? NSNull(),
                    ] as [String: Any]
                }
                let data = (try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("[]".utf8)
                out(String(decoding: data, as: UTF8.self))
                return 0
            }
            if shows.isEmpty {
                out("No shows.")
                return 0
            }
            for show in shows {
                let stat = stats[show.id] ?? ShowStats([])
                var marks = [Describe.count(stat.played, "played", "played")]
                if stat.played > 0 { marks.append(Describe.duration(stat.timeListened)) }
                if !show.following { marks.append("not following") }
                if show.feedURL == nil { marks.append("no public feed") } else if show.hasPrivateFeed { marks.append("private feed") }
                out("\(show.title)  (\(marks.joined(separator: ", ")))")
            }
            return 0

        case .history(let json, let limit):
            if json {
                out(renderer.json(shows: library.shows, episodes: library.episodes))
                return 0
            }
            let history = library.history.prefix(limit ?? .max)
            if history.isEmpty {
                out("No episodes played yet.")
                return 0
            }
            for episode in history {
                let show = library.show(episode.showID)?.title ?? "Unknown show"
                let when = episode.lastPlayed.map(renderer.day) ?? "undated   "
                out("\(when)  \(show) · \(episode.title)  (\(renderer.status(episode)))")
            }
            return 0

        case .opml:
            // print adds the last line break back.
            out(String(renderer.opml(library.shows, created: now).dropLast()))
            let missing = library.following.filter { $0.feedURL == nil }
            if !missing.isEmpty {
                err("Left out \(Describe.count(missing.count, "show")) with no public feed: \(missing.map(\.title).joined(separator: ", ")).")
            }
            return 0

        case .export(let folder, var options):
            options.renderer = Renderer(timeZone: renderer.timeZone, locale: renderer.locale, links: options.renderer.links)
            let exporter = Exporter(destination: resolve(folder), options: options)
            do {
                // Never into the library being read, or the real one when reading a copy.
                let protected = source.protectedFolders + PodcastLibrary(home: home).protectedFolders
                let report = try exporter.export(library, protected: protected, now: now)
                out(Describe.summary(report) + ".")
                for path in report.written { out("  + \(path)") }
                for path in report.kept { out("  = \(path): you've edited it, so it was left as it is") }
                if report.keptOPML {
                    out("  = \(Exporter.opmlName): Apple Podcasts lists far fewer shows you follow than last time, as it does while it's still loading or syncing, so the last one was kept. If you did unfollow them, delete it and export again.")
                }
                for title in report.withoutFeed { out("  … \(title): no public feed, so it isn't in the OPML file") }
                if report.privateFeeds > 0 {
                    out("  ! \(Exporter.opmlName) holds \(Describe.count(report.privateFeeds, "private feed")). Treat it like a password.")
                }
                for failure in report.failed { err("  ! \(failure.file): \(failure.reason)") }
                return report.failed.isEmpty ? 0 : 1
            } catch let error as ExportError {
                err(Describe.problem(error))
                return 1
            } catch {
                err(error.localizedDescription)
                return 1
            }

        case .help, .version:
            return 0
        }
    }
}
