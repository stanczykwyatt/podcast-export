import Foundation

/// A show in Apple Podcasts.
public struct Show: Identifiable, Equatable, Sendable, Codable {
    /// Apple Podcasts' own ID for the show, which stays the same when its title or feed changes.
    public var id: String
    public var title: String
    public var author: String?
    /// The RSS feed other podcast apps follow, if it's a plain web address.
    public var feedURL: String?
    /// The show's website.
    public var webURL: String?
    /// The show's ID in the Apple Podcasts directory, if it's listed there.
    public var appleID: Int64?
    /// Whether you follow it. Shows Apple Podcasts added only because you played something, and
    /// hidden ones, don't count.
    public var following: Bool
    /// When you started following it.
    public var added: Date?
    /// Whether the feed's address looks like it holds a password or a personal key, like the
    /// private feeds that come with a paid membership. Such an address is a secret: it's only
    /// written to the OPML file, never to notes, history or the export record.
    public private(set) var hasPrivateFeed: Bool

    public init(
        id: String, title: String, author: String? = nil, feedURL: String? = nil, webURL: String? = nil,
        appleID: Int64? = nil, following: Bool = true, added: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.feedURL = feedURL
        self.webURL = webURL
        self.appleID = appleID
        self.following = following
        self.added = added
        hasPrivateFeed = feedURL.map(Links.looksPrivate) ?? false
    }

    /// The show's page in the Apple Podcasts directory.
    public var appleURL: String? {
        appleID.map { "https://podcasts.apple.com/podcast/id\($0)" }
    }

    /// The feed's address when it's safe to write anywhere.
    public var publicFeedURL: String? {
        hasPrivateFeed ? nil : feedURL
    }

    /// The show without a private feed's address, for keeping in the export record.
    public var redacted: Show {
        var copy = self
        copy.feedURL = publicFeedURL
        return copy
    }

    /// The show checked again, as it comes back from an export record a version with a weaker
    /// check might have written: a feed that looks private now is dropped.
    var rechecked: Show {
        var copy = self
        if let feed = feedURL, Links.looksPrivate(feed) { copy.hasPrivateFeed = true }
        return copy.redacted
    }
}

/// An episode you've played, started or saved.
public struct Episode: Identifiable, Equatable, Sendable, Codable {
    /// Apple Podcasts' own ID for the episode.
    public var id: String
    public var showID: String
    public var title: String
    /// The ID the show's feed gives the episode, which other podcast apps use to match it.
    public var guid: String?
    public var published: Date?
    /// In seconds, or 0 if Apple Podcasts doesn't know yet.
    public var duration: Double
    /// Where you stopped, in seconds.
    public var position: Double
    public var lastPlayed: Date?
    public var playCount: Int
    /// Played to the end.
    public var finished: Bool
    /// In your Saved episodes (bookmarked, in older versions).
    public var saved: Bool
    public var savedDate: Date?
    /// The episode's own web page.
    public var webURL: String?
    /// The episode's ID in the Apple Podcasts directory.
    public var appleID: Int64?
    public var season: Int?
    public var number: Int?

    public init(
        id: String, showID: String, title: String, guid: String? = nil, published: Date? = nil, duration: Double = 0,
        position: Double = 0, lastPlayed: Date? = nil, playCount: Int = 0, finished: Bool = false, saved: Bool = false,
        savedDate: Date? = nil, webURL: String? = nil, appleID: Int64? = nil, season: Int? = nil, number: Int? = nil
    ) {
        self.id = id
        self.showID = showID
        self.title = title
        self.guid = guid
        self.published = published
        self.duration = duration
        self.position = position
        self.lastPlayed = lastPlayed
        self.playCount = playCount
        self.finished = finished
        self.saved = saved
        self.savedDate = savedDate
        self.webURL = webURL
        self.appleID = appleID
        self.season = season
        self.number = number
    }

    /// Whether you've actually listened to some of it. Marking an episode played without playing
    /// it doesn't count.
    public var listened: Bool {
        lastPlayed != nil || playCount > 0 || position > 0
    }

    /// How far through you are, from 0 to 1.
    public var progress: Double {
        if finished { return 1 }
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    /// Roughly how long you've listened: the whole episode once finished, or up to where you stopped.
    public var timeListened: Double {
        guard listened else { return 0 }
        return finished ? duration : min(position, duration > 0 ? duration : position)
    }

    /// The episode's page in the Apple Podcasts directory, which needs the show's ID too.
    public func appleURL(show: Show?) -> String? {
        guard let appleID, let showID = show?.appleID else { return nil }
        return "https://podcasts.apple.com/podcast/id\(showID)?i=\(appleID)"
    }
}

/// What Apple Podcasts holds: the shows, and the episodes you've played, started or saved.
public struct Library: Equatable, Sendable {
    public var shows: [Show]
    public var episodes: [Episode]

    public init(shows: [Show] = [], episodes: [Episode] = []) {
        self.shows = shows
        self.episodes = episodes
    }

    /// The shows you follow, by title.
    public var following: [Show] {
        shows.filter(\.following).sorted { Self.order($0.title, $1.title) }
    }

    /// The episodes you've listened to, most recent first.
    public var history: [Episode] {
        episodes.filter(\.listened).sorted(by: Self.recent)
    }

    public var saved: [Episode] {
        episodes.filter(\.saved).sorted { ($0.savedDate ?? .distantPast, $0.id) > ($1.savedDate ?? .distantPast, $1.id) }
    }

    public func show(_ id: String) -> Show? {
        shows.first { $0.id == id }
    }

    /// Titles in the order Finder sorts them: ignoring case and with numbers in order.
    static func order(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    /// Most recently played first, then by ID so the order never changes between runs.
    static func recent(_ a: Episode, _ b: Episode) -> Bool {
        (a.lastPlayed ?? .distantPast, a.id) > (b.lastPlayed ?? .distantPast, b.id)
    }
}

/// How much you've listened to a show.
public struct ShowStats: Equatable, Sendable {
    public var played = 0
    public var finished = 0
    public var saved = 0
    /// In seconds, roughly.
    public var timeListened: Double = 0
    public var firstPlayed: Date?
    public var lastPlayed: Date?

    public init(_ episodes: [Episode]) {
        for episode in episodes {
            if episode.saved { saved += 1 }
            guard episode.listened else { continue }
            played += 1
            if episode.finished { finished += 1 }
            timeListened += episode.timeListened
            if let date = episode.lastPlayed {
                firstPlayed = min(firstPlayed ?? date, date)
                lastPlayed = max(lastPlayed ?? date, date)
            }
        }
    }

    /// Every show's stats, by show ID.
    public static func all(_ episodes: [Episode]) -> [String: ShowStats] {
        Dictionary(grouping: episodes, by: \.showID).mapValues(ShowStats.init)
    }
}

/// Web addresses from the library, which are checked before they're written anywhere.
public enum Links {
    /// The address if it's a plain http or https link with a host, or nil.
    public static func web(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value.utf8.count <= 4096,
              !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || " <>\"`{}|\\^".unicodeScalars.contains($0) || Renderer.isHidden($0) }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        return value
    }

    /// Words that mark a query item as a password or key.
    static let secretWords = ["key", "token", "auth", "secret", "sig", "pass", "access", "session", "private", "credential"]
    /// Words that mark a part of the path as a members' feed.
    static let memberWords = ["private", "premium", "member", "patron", "supporter", "subscriber", "token", "auth", "secret", "bonus"]

    /// Whether the address holds a user name or password, a query item that looks like a key, or a
    /// path with a members' word or a long random-looking part, like a personal token. It errs on
    /// the side of private: a public feed taken for a private one only stays out of the notes.
    public static func looksPrivate(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else { return true }
        if components.user != nil || components.password != nil { return true }
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            if secretWords.contains(where: name.contains) || name == "id" && (item.value?.count ?? 0) >= 16 { return true }
        }
        let parts = components.path.lowercased().split(separator: "/").map { String($0.split(separator: ".").first ?? "") }
        if parts.contains(where: { part in memberWords.contains(where: part.contains) }) { return true }
        // Directories that say they're public, as some hosts' show IDs sit under, are left alone.
        if parts.contains("public") { return false }
        return parts.contains(where: looksRandom)
    }

    /// A long run of letters and digits mixed together, like a key or a UUID, rather than a word or a number.
    static func looksRandom(_ part: String) -> Bool {
        let core = part.filter { $0 != "-" && $0 != "_" }
        guard core.count >= 20, core.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        return core.contains(where: \.isLetter) && core.contains(where: \.isNumber)
    }
}
