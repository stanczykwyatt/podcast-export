import Foundation

/// How notes link to each other.
public enum LinkStyle: String, CaseIterable, Codable, Sendable {
    /// `[[Shows/Name|Name]]`, which Obsidian and Logseq follow.
    case obsidian
    /// `[Name](<Shows/Name.md>)`, which works in any Markdown app.
    case markdown
}

/// Turns shows and episodes into the files that are written: OPML for other podcast apps,
/// Markdown notes, and the listening history as CSV and JSON.
public struct Renderer: Sendable {
    public var timeZone: TimeZone
    public var locale: Locale
    public var links: LinkStyle

    /// How many plays the overview lists. Every play is in the show notes and the history files.
    public static let recentLimit = 50

    public init(timeZone: TimeZone = .current, locale: Locale = .current, links: LinkStyle = .obsidian) {
        self.timeZone = timeZone
        self.locale = locale
        self.links = links
    }

    // MARK: OPML

    /// The shows you follow as OPML 2.0, which Overcast, Pocket Casts, Castro, AntennaPod and most
    /// other podcast apps import. Shows without a plain web feed, like ones only Apple hosts, can't
    /// be followed elsewhere and are left out. With no `created` date the head has none, which is
    /// how the exporter tells whether anything changed.
    public func opml(_ shows: [Show], created: Date?) -> String {
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<opml version=\"2.0\">",
            "  <head>",
            "    <title>Podcast subscriptions</title>",
        ]
        if let created { lines.append("    <dateCreated>\(rfc822(created))</dateCreated>") }
        lines.append("  </head>")
        lines.append("  <body>")
        for show in shows.filter({ $0.following && $0.feedURL != nil }).sorted(by: { Library.order($0.title, $1.title) }) {
            let title = Self.xml(show.title)
            var outline = "    <outline type=\"rss\" text=\"\(title)\" title=\"\(title)\" xmlUrl=\"\(Self.xml(show.feedURL ?? ""))\""
            if let web = show.webURL { outline += " htmlUrl=\"\(Self.xml(web))\"" }
            lines.append(outline + "/>")
        }
        lines.append("  </body>")
        lines.append("</opml>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Text for an XML attribute: the five special characters escaped, and anything XML 1.0 can't
    /// hold, or that could make the text read differently, removed.
    static func xml(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\n", "\r", "\t": out += " "
            default:
                let v = scalar.value
                let allowed = (0x20...0xD7FF).contains(v) || (0xE000...0xFFFD).contains(v) || v >= 0x10000
                if allowed && !isHidden(scalar) { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    func rfc822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    // MARK: Markdown

    /// The overview note: every show with how much you've listened, then your latest plays and
    /// saved episodes. `notes` maps show IDs to their notes' paths, without `.md`.
    public func overview(shows: [Show], episodes: [Episode], notes: [String: String]) -> String {
        let stats = ShowStats.all(episodes)
        let byID = Dictionary(shows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let played = episodes.filter(\.listened)
        let following = shows.filter(\.following).count
        let total = played.reduce(0) { $0 + $1.timeListened }
        var lines = ["---"]
        lines.append("title: \"Podcasts\"")
        lines.append("shows-followed: \(following)")
        lines.append("episodes-played: \(played.count)")
        lines.append("hours-listened: \(Self.hours(total))")
        lines.append("source: Apple Podcasts")
        lines.append("tags:")
        lines.append("  - podcasts")
        lines.append("---")
        lines.append("")
        lines.append("# Podcasts")
        lines.append("")
        lines.append([
            Describe.count(following, "show") + " followed", Describe.count(played.count, "episode") + " played",
            Describe.listened(total) + " listened",
        ].joined(separator: " · "))
        lines.append("")

        let listed = shows.filter { notes[$0.id] != nil }.sorted { a, b in
            let (x, y) = (stats[a.id]?.lastPlayed ?? .distantPast, stats[b.id]?.lastPlayed ?? .distantPast)
            return x != y ? x > y : Library.order(a.title, b.title)
        }
        if !listed.isEmpty {
            lines.append("## Shows")
            lines.append("")
            lines.append("| Show | Following | Played | Listened | Last played |")
            lines.append("| --- | --- | --- | --- | --- |")
            for show in listed {
                let stat = stats[show.id] ?? ShowStats([])
                let cells = [
                    link(to: notes[show.id] ?? "", title: show.title, inTable: true),
                    show.following ? "yes" : "no",
                    "\(stat.played)",
                    stat.played > 0 ? Describe.duration(stat.timeListened) : "",
                    stat.lastPlayed.map(day) ?? "",
                ]
                lines.append("| " + cells.joined(separator: " | ") + " |")
            }
            lines.append("")
        }

        let recent = played.sorted(by: Library.recent).prefix(Self.recentLimit)
        if !recent.isEmpty {
            lines.append("## Recently played")
            lines.append("")
            for episode in recent {
                let show = byID[episode.showID]
                var parts = [episode.lastPlayed.map { "**\(day($0))**" } ?? "**Undated**"]
                parts.append(show.map { Self.inline($0.title) } ?? "Unknown show")
                parts.append(episodeLink(episode, show: show))
                parts.append(status(episode))
                lines.append("- " + parts.joined(separator: " · "))
            }
            lines.append("")
        }

        let saved = episodes.filter(\.saved).sorted { ($0.savedDate ?? .distantPast, $0.id) > ($1.savedDate ?? .distantPast, $1.id) }
        if !saved.isEmpty {
            lines.append("## Saved")
            lines.append("")
            for episode in saved {
                var parts = [byID[episode.showID].map { Self.inline($0.title) } ?? "Unknown show", episodeLink(episode, show: byID[episode.showID])]
                if let date = episode.savedDate { parts.append("saved \(day(date))") }
                lines.append("- " + parts.joined(separator: " · "))
            }
            lines.append("")
        }
        if listed.isEmpty && recent.isEmpty && saved.isEmpty {
            lines.append("*Nothing yet. Follow a show or play an episode in Apple Podcasts, and the next export adds it here.*")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// A show's note: its details, how much you've listened, then every episode you've played
    /// and saved.
    public func showNote(_ show: Show, episodes: [Episode]) -> String {
        let mine = episodes.filter { $0.showID == show.id }
        let stats = ShowStats(mine)
        var lines = ["---"]
        lines.append("title: \(Self.yaml(show.title))")
        if let author = show.author { lines.append("author: \(Self.yaml(author))") }
        if let feed = show.publicFeedURL { lines.append("feed: \(Self.yaml(feed))") }
        if let web = show.webURL { lines.append("website: \(Self.yaml(web))") }
        if let apple = show.appleURL { lines.append("apple-podcasts: \(Self.yaml(apple))") }
        lines.append("following: \(show.following)")
        if show.following, let added = show.added { lines.append("following-since: \(day(added))") }
        lines.append("episodes-played: \(stats.played)")
        lines.append("hours-listened: \(Self.hours(stats.timeListened))")
        if let last = stats.lastPlayed { lines.append("last-played: \(day(last))") }
        lines.append("source: Apple Podcasts")
        lines.append("podcast-id: \(Self.yaml(show.id))")
        lines.append("tags:")
        lines.append("  - podcast")
        lines.append("---")
        lines.append("")
        lines.append("# \(Self.heading(show.title))")
        lines.append("")
        var about: [String] = []
        if let author = show.author { about.append("By \(Self.inline(author))") }
        if show.following {
            about.append(show.added.map { "following since \(longDay($0))" } ?? "following")
        } else {
            about.append("not following")
        }
        if show.hasPrivateFeed { about.append("private feed, in the OPML file only") }
        lines.append(Self.capitalized(about.joined(separator: " · ")))
        lines.append("")
        if stats.played > 0 {
            var summary = [Describe.count(stats.played, "episode") + " played", Describe.listened(stats.timeListened) + " listened"]
            if let last = stats.lastPlayed { summary.append("last played \(longDay(last))") }
            lines.append(summary.joined(separator: " · "))
            lines.append("")
        }
        let played = mine.filter(\.listened).sorted(by: Library.recent)
        if !played.isEmpty {
            lines.append("## Played")
            lines.append("")
            for episode in played {
                var parts = [episode.lastPlayed.map { "**\(day($0))**" } ?? "**Undated**", episodeLink(episode, show: show)]
                if episode.duration > 0 { parts.append(Describe.duration(episode.duration)) }
                parts.append(status(episode))
                lines.append("- " + parts.joined(separator: " · "))
            }
            lines.append("")
        }
        let saved = mine.filter(\.saved).sorted { ($0.savedDate ?? .distantPast, $0.id) > ($1.savedDate ?? .distantPast, $1.id) }
        if !saved.isEmpty {
            lines.append("## Saved")
            lines.append("")
            for episode in saved {
                var parts = [episodeLink(episode, show: show)]
                if let published = episode.published { parts.append("published \(day(published))") }
                lines.append("- " + parts.joined(separator: " · "))
            }
            lines.append("")
        }
        if played.isEmpty && saved.isEmpty {
            lines.append("*No episodes played yet.*")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// An episode's title, linked to its web page or its Apple Podcasts page when there is one.
    func episodeLink(_ episode: Episode, show: Show?) -> String {
        let title = Self.inline(episode.title).nonEmpty ?? "Untitled episode"
        guard let url = episode.webURL ?? episode.appleURL(show: show) else { return title }
        return "[\(title)](<\(url)>)"
    }

    /// A link to another note, in the chosen style. In a table, the pipe in an Obsidian link is
    /// escaped so it doesn't end the cell.
    func link(to path: String, title: String, inTable: Bool = false) -> String {
        // Pipes in the title are already escaped, which keeps them from ending a table cell too.
        let text = Self.inline(title)
        switch links {
        case .obsidian: return "[[\(path)\(inTable ? "\\|" : "|")\(text)]]"
        case .markdown: return "[\(text)](<\(path).md>)"
        }
    }

    /// Finished, how far through, or not played.
    func status(_ episode: Episode) -> String {
        if !episode.listened { return "not played" }
        if episode.finished { return episode.playCount > 1 ? "finished, played \(episode.playCount) times" : "finished" }
        guard episode.duration > 0 else { return "started" }
        return "\(Int((episode.progress * 100).rounded(.down)))% played"
    }

    // MARK: History files

    static let csvColumns = [
        "last_played", "show", "episode", "status", "progress_percent", "seconds_listened", "duration_seconds", "play_count",
        "saved", "published", "season", "episode_number", "episode_guid", "episode_url", "apple_podcasts_url",
        "show_feed_url", "podcast_id", "episode_id",
    ]

    /// Every episode you've played or saved, most recent first, as CSV for spreadsheets.
    public func csv(shows: [Show], episodes: [Episode]) -> String {
        let byID = Dictionary(shows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows = [Self.csvColumns.joined(separator: ",")]
        for episode in Self.ordered(episodes) {
            let show = byID[episode.showID]
            let fields: [String] = [
                episode.lastPlayed.map(isoDate) ?? "", show?.title ?? "", episode.title,
                episode.listened ? (episode.finished ? "finished" : "in progress") : "saved",
                episode.listened ? "\(Int((episode.progress * 100).rounded(.down)))" : "",
                episode.listened ? "\(Int(episode.timeListened.rounded()))" : "",
                episode.duration > 0 ? "\(Int(episode.duration.rounded()))" : "", "\(episode.playCount)",
                episode.saved ? "yes" : "no", episode.published.map(isoDate) ?? "",
                episode.season.map(String.init) ?? "", episode.number.map(String.init) ?? "", episode.guid ?? "",
                episode.webURL ?? "", episode.appleURL(show: show) ?? "", show?.publicFeedURL ?? "", episode.showID, episode.id,
            ]
            rows.append(fields.map(Self.csvField).joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    /// One CSV field, quoted. Text a spreadsheet would run as a formula gets a leading apostrophe,
    /// so an episode title can't become one.
    static func csvField(_ value: String) -> String {
        var text = visible(value).replacingOccurrences(of: "\n", with: " ")
        if let first = text.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first), Double(text) == nil {
            text = "'" + text
        }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Every show and episode, as JSON for scripts and other apps. Private feed addresses are left out.
    public func json(shows: [Show], episodes: [Episode]) -> String {
        let stats = ShowStats.all(episodes)
        let byID = Dictionary(shows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let file = HistoryFile(
            shows: shows.sorted { Library.order($0.title, $1.title) }.map { show in
                let stat = stats[show.id] ?? ShowStats([])
                return .init(
                    id: show.id, title: show.title, author: show.author, feedURL: show.publicFeedURL, privateFeed: show.hasPrivateFeed,
                    website: show.webURL, applePodcastsURL: show.appleURL, appleID: show.appleID, following: show.following,
                    followingSince: show.following ? show.added.map(isoDate) : nil, episodesPlayed: stat.played,
                    secondsListened: Int(stat.timeListened.rounded()), lastPlayed: stat.lastPlayed.map(isoDate)
                )
            },
            episodes: Self.ordered(episodes).map { episode in
                .init(
                    id: episode.id, podcastID: episode.showID, show: byID[episode.showID]?.title, title: episode.title, guid: episode.guid,
                    published: episode.published.map(isoDate), durationSeconds: episode.duration > 0 ? Int(episode.duration.rounded()) : nil,
                    positionSeconds: Int(episode.position.rounded()), progressPercent: Int((episode.progress * 100).rounded(.down)),
                    finished: episode.finished, playCount: episode.playCount, lastPlayed: episode.lastPlayed.map(isoDate),
                    saved: episode.saved, savedDate: episode.savedDate.map(isoDate), website: episode.webURL,
                    applePodcastsURL: episode.appleURL(show: byID[episode.showID]), season: episode.season, number: episode.number
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(file)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Played episodes most recent first, then saved ones that haven't been played.
    static func ordered(_ episodes: [Episode]) -> [Episode] {
        episodes.filter(\.listened).sorted(by: Library.recent)
            + episodes.filter { !$0.listened }.sorted { ($0.savedDate ?? .distantPast, $0.id) > ($1.savedDate ?? .distantPast, $1.id) }
    }

    // MARK: Dates

    func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// A day, like 2026-04-30, which sorts in order.
    public func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// A day in words, like April 30, 2026.
    func longDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// Hours with one decimal, for front matter.
    static func hours(_ seconds: Double) -> String {
        String(format: "%.1f", (seconds / 3600 * 10).rounded() / 10)
    }

    // MARK: Text

    /// A double-quoted YAML string, safe for any title.
    static func yaml(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:
                // Control and invisible formatting characters are written as escapes, so nothing
                // hides in the front matter. YAML reads them back as they were.
                if [.control, .format, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory) {
                    out += scalar.value > 0xFFFF ? String(format: "\\U%08X", scalar.value) : String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// A title on one line, for a Markdown heading.
    static func heading(_ title: String) -> String {
        inline(title).nonEmpty ?? "Untitled show"
    }

    /// Text on one line, escaped for Markdown.
    static func inline(_ text: String) -> String {
        escape(visible(text).components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces))
    }

    static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Escapes what Markdown would otherwise read as formatting or HTML, so titles come out as
    /// written. Only characters that can start formatting are escaped, to keep the text readable.
    static func escape(_ text: String) -> String {
        let characters = Array(visible(text))
        var out = ""
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let previous = index > 0 ? characters[index - 1] : nil
            // Single characters that start formatting, and the pairs Obsidian reads as comments,
            // highlights and strikethrough. An ampersand only when it could start an entity.
            let pair = "%=~".contains(character) && (next == character || previous == character)
            let entity = character == "&" && Self.startsEntity(characters[(index + 1)...])
            if "\\`*_<>[]#$|".contains(character) || pair || entity { out.append("\\") }
            out.append(character)
        }
        return out
    }

    /// Whether what follows an ampersand would make it an HTML entity, like `&amp;` or `&#38;`.
    static func startsEntity(_ rest: ArraySlice<Character>) -> Bool {
        let name = rest.prefix(12).prefix { $0.isLetter || $0.isNumber || $0 == "#" }
        return !name.isEmpty && rest.dropFirst(name.count).first == ";"
    }

    /// Text without control characters or the invisible marks that flip its direction, which
    /// could make words read differently from what's there.
    static func visible(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isHidden(scalar) || scalar == "\n" {
            out.append(scalar)
        }
        return String(out)
    }

    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
            || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
            || scalar.value == 0x200E || scalar.value == 0x200F || scalar.value == 0x061C
    }

    // MARK: File names

    /// A name that's safe as a file name on any Mac, and inside an Obsidian `[[link]]`.
    public static func safeName(_ name: String, fallback: String = "Untitled show") -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            if "/\\:*?\"<>|[]#^".unicodeScalars.contains(scalar) || isHidden(scalar) {
                out += " "
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        var cleaned = out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        // File names are limited to 255 bytes, and a number and an extension come too.
        while cleaned.utf8.count > 180 { cleaned.removeLast() }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? fallback : cleaned
    }
}

/// The layout of `Listening History.json`.
struct HistoryFile: Codable {
    struct ShowEntry: Codable {
        var id: String
        var title: String
        var author: String?
        var feedURL: String?
        var privateFeed: Bool
        var website: String?
        var applePodcastsURL: String?
        var appleID: Int64?
        var following: Bool
        var followingSince: String?
        var episodesPlayed: Int
        var secondsListened: Int
        var lastPlayed: String?

        enum CodingKeys: String, CodingKey {
            case id, title, author, website, following
            case feedURL = "feed_url", privateFeed = "private_feed", applePodcastsURL = "apple_podcasts_url", appleID = "apple_id"
            case followingSince = "following_since", episodesPlayed = "episodes_played", secondsListened = "seconds_listened"
            case lastPlayed = "last_played"
        }
    }

    struct EpisodeEntry: Codable {
        var id: String
        var podcastID: String
        var show: String?
        var title: String
        var guid: String?
        var published: String?
        var durationSeconds: Int?
        var positionSeconds: Int
        var progressPercent: Int
        var finished: Bool
        var playCount: Int
        var lastPlayed: String?
        var saved: Bool
        var savedDate: String?
        var website: String?
        var applePodcastsURL: String?
        var season: Int?
        var number: Int?

        enum CodingKeys: String, CodingKey {
            case id, show, title, guid, published, finished, saved, website, season
            case podcastID = "podcast_id", durationSeconds = "duration_seconds", positionSeconds = "position_seconds"
            case progressPercent = "progress_percent", playCount = "play_count", lastPlayed = "last_played"
            case savedDate = "saved_date", applePodcastsURL = "apple_podcasts_url", number = "episode_number"
        }
    }

    var format = "podcast-export history 1"
    var shows: [ShowEntry]
    var episodes: [EpisodeEntry]
}
