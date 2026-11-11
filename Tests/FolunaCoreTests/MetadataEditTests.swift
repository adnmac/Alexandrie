import Foundation
import Testing
@testable import FolunaCore

@Suite struct MetadataEditTests {
    let fixed = MetadataEdits(title: "Candide, ou l’Optimisme — corrigé", authors: ["Voltaire", "Éditeur Anonyme"],
                              publisher: "Cramer", language: "en", summary: "Résumé corrigé.", publishedDate: "1759")

    @Test func rewritesAZW3WithoutTouchingText() throws {
        let azw3 = temp("azw3")
        let original = try EPUBToAZW3.convert(input: makeSampleEPUB(chapters: 2, paragraphs: 30), output: azw3)
        let before = try MobiBook(url: azw3)

        let out = temp("azw3")
        try MobiMetadataWriter.rewrite(azw3, with: fixed, to: out)
        let after = try MobiBook(url: out)
        let meta = after.metadata()
        #expect(meta.title == fixed.title)
        #expect(meta.authors == fixed.authors)
        #expect(meta.publisher == "Cramer")
        #expect(meta.language == "en")
        #expect(meta.summary == "Résumé corrigé.")
        #expect(meta.publishedDate == "1759")
        #expect(after.kf8!.fullName == fixed.title)
        // Conservés : ASIN, type, couverture, texte.
        #expect(after.asin == original.asin)
        #expect(after.cdeType == "EBOK")
        #expect(meta.coverData == before.metadata().coverData)
        #expect(try after.text(after.kf8!) == before.text(before.kf8!))
        #expect(try MobiToEPUB.build(after).spinePaths.count == 2)
    }

    @Test func clearsEmptiedFields() throws {
        let azw3 = temp("azw3")
        try EPUBToAZW3.convert(input: makeSampleEPUB(chapters: 1, paragraphs: 2), output: azw3)
        let out = temp("azw3")
        try MobiMetadataWriter.rewrite(azw3, with: MetadataEdits(title: "  Seul titre  ", authors: [" "], publisher: ""),
                                       to: out)
        let meta = try MobiBook(url: out).metadata()
        #expect(meta.title == "Seul titre")
        #expect(meta.authors.isEmpty)
        #expect(meta.publisher == nil)
    }

    @Test func refusesDRM() throws {
        var bytes = try [UInt8](Data(contentsOf: {
            let u = temp("azw3")
            try EPUBToAZW3.convert(input: makeSampleEPUB(chapters: 1, paragraphs: 2), output: u)
            return u
        }()))
        bytes[bytes.u32(78) + 13] = 2
        #expect(throws: BookError.drmProtected) { try MobiMetadataWriter.rewrite(bytes, with: fixed) }
    }

    @Test func editsBookOnKindle() throws {
        let device = VolumeKindle(root: try makeFakeKindle())
        let doc = try device.listDocuments().first { $0.fileExtension == "azw3" }!
        let drm = try device.listDocuments().first { $0.fileExtension == "azw" }!
        let dirs = AppDirectories(base: FileManager.default.temporaryDirectory.appendingPathComponent("app-\(UUID().uuidString)"))
        let catalog = KindleCatalog(directories: dirs)
        #expect(KindleEditor.canEdit(doc, info: catalog.info(for: doc, on: device)))
        #expect(!KindleEditor.canEdit(drm, info: catalog.info(for: drm, on: device)))

        try KindleEditor.update(doc, with: fixed, on: device)
        let updated = try device.listDocuments().first { $0.path == doc.path }!
        #expect(updated.size != doc.size)
        let info = catalog.info(for: updated, on: device)
        #expect(info.title == fixed.title)
        #expect(info.publishedDate == "1759")
        // Aucun fichier temporaire laissé sur l'appareil.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: device.documents.path)
            .filter { $0.contains("foluna-tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func sendAppliesLibraryEdits() throws {
        let azw3 = temp("azw3")
        try EPUBToAZW3.convert(input: makeSampleEPUB(chapters: 1, paragraphs: 2), output: azw3)
        let dirs = AppDirectories(base: FileManager.default.temporaryDirectory.appendingPathComponent("app-\(UUID().uuidString)"))
        let file = ScannedFile(url: azw3, size: Int64(try Data(contentsOf: azw3).count), modifiedAt: Date())
        var book = FolderScanner.makeBook(file, imported: false, coverStore: CoverStore(directory: dirs.covers))
        book.edits = fixed
        let prepared = try KindleTransfer.prepare(book, directories: dirs)
        #expect(prepared != azw3)
        #expect(try MobiBook(url: prepared).metadata().title == fixed.title)
        // Le fichier d'origine n'est pas modifié.
        #expect(try MobiBook(url: azw3).metadata().title == "Le Livre d'Essai")
    }
}
