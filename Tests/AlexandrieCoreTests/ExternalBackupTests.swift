import Foundation
import Testing
@testable import AlexandrieCore

@Suite struct ExternalBackupTests {
    let fm = FileManager.default

    /// Données de l'app et dossier de sauvegarde, dans un dossier temporaire.
    func setUp() throws -> (AppDirectories, URL, URL) {
        let tmp = fm.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
        let dirs = AppDirectories(base: tmp.appendingPathComponent("App", isDirectory: true))
        let dest = tmp.appendingPathComponent("iCloud", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("[1]".utf8).write(to: dirs.index)
        try Data("clips".utf8).write(to: dirs.clippings)
        try Data("livre".utf8).write(to: dirs.imports.appendingPathComponent("Verne.epub"))
        try Data("jpg".utf8).write(to: dirs.covers.appendingPathComponent("abc.jpg"))
        try Data("cache".utf8).write(to: dirs.conversions.appendingPathComponent("x.azw3"))
        return (dirs, dest, tmp)
    }

    func day(_ s: String) -> Date { ExternalBackup.dayFormat.date(from: s)! }

    @Test func backsUpDataAndMirrorsFolders() throws {
        let (dirs, dest, tmp) = try setUp()
        defer { try? fm.removeItem(at: tmp) }
        let report = try ExternalBackup.backUp(dirs, to: dest, now: day("2026-11-08"))
        let root = ExternalBackup.root(in: dest)
        #expect(report.dataFiles == 2 && report.copied == 2 && report.removed == 0)
        #expect(try String(contentsOf: report.snapshot.appendingPathComponent("library.json"), encoding: .utf8) == "[1]")
        #expect(fm.fileExists(atPath: root.appendingPathComponent("Imports/Verne.epub").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("Covers/abc.jpg").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("Conversions").path), "les caches ne sont pas copiés")

        // Lendemain : rien n'a changé dans Imports, un livre est retiré, un autre ajouté.
        try fm.removeItem(at: dirs.imports.appendingPathComponent("Verne.epub"))
        try Data("autre".utf8).write(to: dirs.imports.appendingPathComponent("Hugo.epub"))
        let next = try ExternalBackup.backUp(dirs, to: dest, now: day("2026-11-09"))
        #expect(next.copied == 1 && next.removed == 1)
        #expect(ExternalBackup.snapshots(in: dest).map(\.url.lastPathComponent) == ["2026-11-09", "2026-11-08"])
        let again = try ExternalBackup.backUp(dirs, to: dest, now: day("2026-11-09"))
        #expect(again.copied == 0 && ExternalBackup.snapshots(in: dest).count == 2, "même jour : copie remplacée")
        let leftovers = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Données").path)
        #expect(!leftovers.contains { $0.hasPrefix(".en-cours") }, "aucun dossier provisoire laissé")
    }

    @Test func keepsTheLatestSnapshots() throws {
        let (dirs, dest, tmp) = try setUp()
        defer { try? fm.removeItem(at: tmp) }
        for d in 1...5 { try ExternalBackup.backUp(dirs, to: dest, now: day("2026-11-0\(d)"), keep: 3) }
        #expect(ExternalBackup.snapshots(in: dest).map(\.url.lastPathComponent) == ["2026-11-05", "2026-11-04", "2026-11-03"])
    }

    @Test func refusesMissingDestinationAndNeverEmptiesTheCopy() throws {
        let (dirs, dest, tmp) = try setUp()
        defer { try? fm.removeItem(at: tmp) }
        #expect(throws: ExternalBackup.Failure.self) {
            try ExternalBackup.backUp(dirs, to: tmp.appendingPathComponent("Disque débranché"))
        }
        try ExternalBackup.backUp(dirs, to: dest)
        // Dossier Imports disparu (mauvaise manipulation) : la copie garde ses livres.
        try fm.removeItem(at: dirs.imports)
        try ExternalBackup.backUp(dirs, to: dest)
        #expect(fm.fileExists(atPath: ExternalBackup.root(in: dest).appendingPathComponent("Imports/Verne.epub").path))
        let empty = AppDirectories(base: tmp.appendingPathComponent("Vide", isDirectory: true))
        #expect(throws: ExternalBackup.Failure.nothingToSave) { try ExternalBackup.backUp(empty, to: dest) }
    }

    @Test func restoresThroughAPendingRequest() throws {
        let (dirs, dest, tmp) = try setUp()
        defer { try? fm.removeItem(at: tmp) }
        let report = try ExternalBackup.backUp(dirs, to: dest)
        // Après la sauvegarde : index changé, livre importé perdu.
        try Data("[2]".utf8).write(to: dirs.index)
        try fm.removeItem(at: dirs.imports.appendingPathComponent("Verne.epub"))
        try Data("nouveau".utf8).write(to: dirs.imports.appendingPathComponent("Récent.epub"))

        #expect(PendingRestore.apply(dirs) == nil, "rien en attente")
        try PendingRestore(snapshot: report.snapshot, destination: dest).schedule(dirs)
        let result = try #require(PendingRestore.apply(dirs))
        let aside = try result.get()
        #expect(try String(contentsOf: dirs.index, encoding: .utf8) == "[1]")
        #expect(try String(contentsOf: aside.appendingPathComponent("library.json"), encoding: .utf8) == "[2]",
                "l'état d'avant est mis de côté")
        #expect(fm.fileExists(atPath: dirs.imports.appendingPathComponent("Verne.epub").path), "livre perdu rendu")
        #expect(fm.fileExists(atPath: dirs.imports.appendingPathComponent("Récent.epub").path), "rien n'est effacé")
        #expect(PendingRestore.pending(dirs) == nil, "demande appliquée une seule fois")

        let empty = tmp.appendingPathComponent("vide", isDirectory: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: ExternalBackup.Failure.emptySnapshot) { try ExternalBackup.restore(empty, from: dest, into: dirs) }
    }
}
