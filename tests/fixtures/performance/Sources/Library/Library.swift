import Foundation

public struct Song: Codable, Sendable {
    public var id: Int
    public var title: String
    public var artist: String
    public var seconds: Double
}

public enum Library {
    public static func data(count: Int) -> Data {
        let songs = (0..<count).map {
            Song(id: $0, title: "Song \(($0 * 7919) % count)", artist: "Artist \($0 % 97)", seconds: Double($0 % 300))
        }
        return (try? JSONEncoder().encode(songs)) ?? Data()
    }

    /// The measured operation: decode the library and sort it by artist and title. `slow`
    /// decodes it twice, the kind of regression an edit can bring in without failing a test.
    public static func load(_ data: Data, slow: Bool = false) -> [Song] {
        var songs = (try? JSONDecoder().decode([Song].self, from: data)) ?? []
        if slow { songs = (try? JSONDecoder().decode([Song].self, from: data)) ?? [] }
        return songs.sorted { ($0.artist, $0.title) < ($1.artist, $1.title) }
    }
}
