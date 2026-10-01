import Foundation

/// Looks up a YouTube video's title via its public oEmbed endpoint — no API key or signed-in
/// account needed (unlike the Data API), which fits every added video being shown with a real
/// title instead of a bare link.
enum YouTubeOEmbedService {
    struct Info: Decodable {
        var title: String
        var authorName: String?

        enum CodingKeys: String, CodingKey {
            case title
            case authorName = "author_name"
        }
    }

    enum OEmbedError: LocalizedError {
        case notFound
        var errorDescription: String? {
            switch self {
            case .notFound: return "Couldn't find that video (it may be private or deleted)."
            }
        }
    }

    static func fetch(videoID: String) async throws -> Info {
        let watchURLString = YouTubeLinkParser.watchURL(videoID: videoID).absoluteString
        guard let encoded = watchURLString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.youtube.com/oembed?url=\(encoded)&format=json") else {
            throw OEmbedError.notFound
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OEmbedError.notFound
        }
        return try JSONDecoder().decode(Info.self, from: data)
    }
}
