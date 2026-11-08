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
        #expect(requested.get()?.absoluteString == "https://api.github.com/repos/adnmac/Foluna/compare/abc...main")
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

@Suite struct ReleaseTests {
    static let release = Data(#"""
    {"tag_name": "v0.3.0", "body": "- feat: étagères", "html_url": "https://github.com/adnmac/Alexandrie/releases/tag/v0.3.0",
     "assets": [{"name": "Alexandrie-0.3.0.zip",
                 "browser_download_url": "https://github.com/adnmac/Alexandrie/releases/download/v0.3.0/Alexandrie-0.3.0.zip"}]}
    """#.utf8)

    @Test func comparesVersionsNumerically() {
        #expect(UpdateChecker.isVersion("0.10.0", newerThan: "0.9.2"))
        #expect(UpdateChecker.isVersion("1.0", newerThan: "0.9.9"))
        #expect(!UpdateChecker.isVersion("0.2.0", newerThan: "0.2.0"))
        #expect(!UpdateChecker.isVersion("0.2.0", newerThan: "0.2.1"))
    }

    @Test func newerReleaseIsReported() async throws {
        let checker = UpdateChecker { url in
            #expect(url == UpdateChecker.latestReleaseURL)
            return Self.release
        }
        let r = try #require(try await checker.newerRelease(than: "0.2.0"))
        #expect(r.version == "0.3.0")
        #expect(r.downloadURL.lastPathComponent == "Alexandrie-0.3.0.zip")
        #expect(try await checker.newerRelease(than: "0.3.0") == nil)
    }

    @Test func diskImageIsPreferredToZip() throws {
        let data = Data(#"""
        {"tag_name": "v0.4.0", "assets": [
          {"name": "Alexandrie-0.4.0.zip", "browser_download_url": "https://example.org/Alexandrie-0.4.0.zip"},
          {"name": "Alexandrie-0.4.0.dmg", "browser_download_url": "https://example.org/Alexandrie-0.4.0.dmg"}]}
        """#.utf8)
        let r = try #require(UpdateChecker.parseRelease(data))
        #expect(r.downloadURL.lastPathComponent == "Alexandrie-0.4.0.dmg")
        #expect(r.isDiskImage)
        #expect(UpdateChecker.parseRelease(Self.release)?.isDiskImage == false)
    }

    /// Une image disque comme celle de scripts/release.sh : l'app en est extraite, l'image démontée.
    @Test func appIsExtractedFromDiskImage() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("alx-dmg-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let stage = dir.appendingPathComponent("stage/Foluna.app/Contents", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("v2".utf8).write(to: stage.appendingPathComponent("version"))
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("stage/Applications").path, withDestinationPath: "/Applications")
        let dmg = dir.appendingPathComponent("Alexandrie.dmg")
        try DiskImage.run("/usr/bin/hdiutil", ["create", "-quiet", "-volname", "Alexandrie test", "-srcfolder",
                                               dir.appendingPathComponent("stage").path, "-format", "UDZO", dmg.path])
        let app = try DiskImage.extractApp(from: dmg, to: dir.appendingPathComponent("out"))
        #expect(try String(contentsOf: app.appendingPathComponent("Contents/version"), encoding: .utf8) == "v2")
        #expect(!(try DiskImage.run("/usr/bin/hdiutil", ["info"])).contains(dir.path))
        #expect(throws: DiskImage.Failure.appMissing) {
            try DiskImage.extractApp(named: ["Autre.app"], from: dmg, to: dir.appendingPathComponent("out2"))
        }
    }

    /// Le script attend la fin du processus, remplace l'app et efface le dossier de travail.
    @Test func installScriptReplacesAppAfterExit() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("alx-inst-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let installed = dir.appendingPathComponent("Applications/Alexandrie.app")
        let work = dir.appendingPathComponent("work")
        let new = work.appendingPathComponent("Alexandrie.app")
        try fm.createDirectory(at: installed, withIntermediateDirectories: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("ancienne".utf8).write(to: installed.appendingPathComponent("v"))
        try Data("nouvelle".utf8).write(to: new.appendingPathComponent("v"))
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["0.5"]
        try sleeper.run()
        let p = try UpdateInstall.launch(waitingFor: sleeper.processIdentifier, newApp: new, installedApp: installed,
                                         relaunch: false, cleaning: work)
        #expect(try String(contentsOf: installed.appendingPathComponent("v"), encoding: .utf8) == "ancienne")
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(try String(contentsOf: installed.appendingPathComponent("v"), encoding: .utf8) == "nouvelle")
        #expect(!fm.fileExists(atPath: work.path))
        #expect(try fm.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path) == ["Alexandrie.app"])
    }

    /// Une copie nommée Alexandrie.app est remplacée par Foluna.app.
    @Test func installScriptRenamesApp() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("alx-ren-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let apps = dir.appendingPathComponent("Applications")
        let installed = apps.appendingPathComponent("Alexandrie.app")
        let new = dir.appendingPathComponent("work/Foluna.app")
        try fm.createDirectory(at: installed, withIntermediateDirectories: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("nouvelle".utf8).write(to: new.appendingPathComponent("v"))
        let p = try UpdateInstall.launch(waitingFor: 999_999, newApp: new, installedApp: installed,
                                         destination: apps.appendingPathComponent("Foluna.app"), relaunch: false)
        p.waitUntilExit()
        #expect(try fm.contentsOfDirectory(atPath: apps.path) == ["Foluna.app"])
    }

    @Test func releaseWithoutZipIsIgnored() {
        #expect(UpdateChecker.parseRelease(Data(#"{"tag_name": "v1.0.0", "assets": []}"#.utf8)) == nil)
    }
}
