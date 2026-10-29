import Foundation

/// Finds shows and episodes by title, which Apple Podcasts' library can't do across your history.
public enum Search {
    public struct Result: Equatable, Sendable {
        public var show: Show
        /// Whether the show's own title or author has every word.
        public var showMatches: Bool
        /// The show's played and saved episodes with every word in their title, or all of them
        /// when the show itself matches or there's no query.
        public var episodes: [Episode]
    }

    /// Shows whose title or author, or one of whose episodes' titles, contains every word of
    /// `query`, ignoring case and accents. Shows come most recently played first.
    public static func run(_ query: String, in library: Library) -> [Result] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let byShow = Dictionary(grouping: library.episodes, by: \.showID)
        let stats = ShowStats.all(library.episodes)
        let shows = library.shows.filter { $0.following || byShow[$0.id] != nil }.sorted { a, b in
            let (x, y) = (stats[a.id]?.lastPlayed ?? .distantPast, stats[b.id]?.lastPlayed ?? .distantPast)
            return x != y ? x > y : Library.order(a.title, b.title)
        }
        return shows.compactMap { show in
            let episodes = Renderer.ordered(byShow[show.id] ?? [])
            guard !terms.isEmpty else { return Result(show: show, showMatches: false, episodes: episodes) }
            let about = show.title + "\n" + (show.author ?? "")
            let showMatches = terms.allSatisfy { contains(about, $0) }
            let matching = episodes.filter { episode in terms.allSatisfy { contains(episode.title, $0) || contains(about, $0) } }
            guard showMatches || !matching.isEmpty else { return nil }
            return Result(show: show, showMatches: showMatches, episodes: showMatches ? episodes : matching)
        }
    }

    static func contains(_ text: String, _ term: String) -> Bool {
        text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }

    /// Where each word of `query` appears in `text`, for highlighting.
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for term in query.split(whereSeparator: \.isWhitespace) {
            var start = text.startIndex
            while start < text.endIndex, let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: start..<text.endIndex) {
                found.append(range)
                start = range.upperBound
            }
        }
        return found.sorted { $0.lowerBound < $1.lowerBound }
    }
}
