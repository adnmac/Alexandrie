import Foundation
import Testing
@testable import AlexandrieCore

@Suite struct UpdateCheckerTests {
    static func compare(status: String, ahead: Int, commits: [(String, String)]) -> Data {
        let list = commits.map { ["sha": $0.0, "commit": ["message": $0.1]] }
        let json: [String: Any] = ["status": status, "ahead_by": ahead, "behind_by": 0, "commits": list,
                                   "html_url": "https://github.com/adnmac/Alexandrie/compare/abc...main"]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test func reportsNewCommits() async throws {
        let requested = LockedURL()
        let checker = UpdateChecker { url in
            requested.set(url)
            return Self.compare(status: "ahead", ahead: 2,
                                commits: [("111", "fix: un"), ("222", "feat: formats sous la couverture\n\nDétails…")])
        }
        let info = try #require(try await checker.check(currentCommit: "abc"))
        #expect(requested.get()?.absoluteString == "https://api.github.com/repos/adnmac/Alexandrie/compare/abc...main")
        #expect(info.newCommits == 2)
        #expect(info.latestSHA == "222")
        #expect(info.latestMessage == "feat: formats sous la couverture")
        #expect(info.url?.absoluteString == "https://github.com/adnmac/Alexandrie/compare/abc...main")
    }

    @Test func upToDateOrAheadOfGitHubIsNil() async throws {
        for status in ["identical", "behind"] {
            let checker = UpdateChecker { _ in Self.compare(status: status, ahead: 0, commits: []) }
            #expect(try await checker.check(currentCommit: "abc") == nil)
        }
    }

    @Test func unexpectedResponseThrows() async {
        let checker = UpdateChecker { _ in Data("{\"message\":\"Not Found\"}".utf8) }
        await #expect(throws: (any Error).self) { try await checker.check(currentCommit: "abc") }
    }
}

final class LockedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    func set(_ u: URL) { lock.lock(); url = u; lock.unlock() }
    func get() -> URL? { lock.lock(); defer { lock.unlock() }; return url }
}
