import Foundation

/// Nouveautés publiées sur GitHub depuis la version installée.
public struct UpdateInfo: Equatable, Sendable {
    public var newCommits: Int
    public var latestSHA: String
    /// Première ligne du message du dernier commit.
    public var latestMessage: String
    /// Page GitHub des modifications depuis la version installée.
    public var url: URL?
}

/// Compare le commit compilé dans l'app à la branche principale du dépôt GitHub (API publique, sans compte).
/// L'accès réseau est injectable pour les tests.
public struct UpdateChecker: Sendable {
    public static let repository = "adnmac/Alexandrie"
    public static let branch = "main"
    let fetch: CatalogClient.Fetch

    public init(fetch: CatalogClient.Fetch? = nil) {
        self.fetch = fetch ?? { url in
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("Alexandrie (macOS)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return data
        }
    }

    public static func compareURL(from commit: String) -> URL {
        URL(string: "https://api.github.com/repos/\(repository)/compare/\(commit)...\(branch)")!
    }

    /// nil si la version installée est à jour (ou plus récente que GitHub).
    public func check(currentCommit: String) async throws -> UpdateInfo? {
        try Self.parse(await fetch(Self.compareURL(from: currentCommit)))
    }

    static func parse(_ data: Data) throws -> UpdateInfo? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ahead = json["ahead_by"] as? Int else { throw URLError(.cannotParseResponse) }
        guard ahead > 0 else { return nil }
        let last = (json["commits"] as? [[String: Any]])?.last
        let message = ((last?["commit"] as? [String: Any])?["message"] as? String) ?? ""
        return UpdateInfo(newCommits: ahead,
                          latestSHA: last?["sha"] as? String ?? "",
                          latestMessage: message.components(separatedBy: .newlines).first ?? "",
                          url: (json["html_url"] as? String).flatMap(URL.init(string:)))
    }
}
