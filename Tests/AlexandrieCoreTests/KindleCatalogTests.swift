import Foundation
import Testing
@testable import AlexandrieCore

/// Arborescence de Kindle simulée sur disque (même structure qu'un appareil monté).
func makeFakeKindle() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kindle-\(UUID().uuidString)")
    let docs = root.appendingPathComponent("documents")
    let items = docs.appendingPathComponent("Downloads/Items01/B0ABCDEFGH")
    let thumbs = root.appendingPathComponent("system/thumbnails")
    for d in [items, thumbs, docs.appendingPathComponent("Essai.sdr")] {
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    }
    // AZW3 envoyé par Alexandrie.
    try EPUBToAZW3.convert(input: makeSampleEPUB(chapters: 1, paragraphs: 3),
                           output: docs.appendingPathComponent("Le Livre d'Essai - Jeanne Dupont.azw3"))
    // Même livre, champ de chiffrement forcé : simule un achat sous DRM.
    var drm = try [UInt8](Data(contentsOf: docs.appendingPathComponent("Le Livre d'Essai - Jeanne Dupont.azw3")))
    let record0 = drm.u32(78)
    drm[record0 + 13] = 2
    try Data(drm).write(to: items.appendingPathComponent("Achat_B0ABCDEFGH.azw"))
    // KFX illisible + miniature générée par la Kindle.
    try Data([1, 2, 3]).write(to: items.appendingPathComponent("Le_Petit_Prince_B0ABCDEFGH.kfx"))
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    try png.write(to: thumbs.appendingPathComponent("thumbnail_B0ABCDEFGH_EBOK_portrait.jpg"))
    // Fichiers à ignorer : données de lecture et formats non-livres.
    try Data().write(to: docs.appendingPathComponent("Essai.sdr/Essai.azw3"))
    try Data().write(to: docs.appendingPathComponent("notes.docx"))
    try Data("notes".utf8).write(to: docs.appendingPathComponent("My Clippings.txt"))
    return root
}

@Suite struct KindleCatalogTests {
    @Test func listsAndReadsBooks() throws {
        let device = VolumeKindle(root: try makeFakeKindle())
        let docs = try device.listDocuments()
        #expect(Set(docs.map(\.path)) == [
            "Le Livre d'Essai - Jeanne Dupont.azw3",
            "Downloads/Items01/B0ABCDEFGH/Achat_B0ABCDEFGH.azw",
            "Downloads/Items01/B0ABCDEFGH/Le_Petit_Prince_B0ABCDEFGH.kfx",
        ])

        let dirs = AppDirectories(base: FileManager.default.temporaryDirectory.appendingPathComponent("app-\(UUID().uuidString)"))
        let catalog = KindleCatalog(directories: dirs)
        func info(_ suffix: String) -> KindleBookInfo {
            catalog.info(for: docs.first { $0.path.hasSuffix(suffix) }!, on: device)
        }

        let sent = info(".azw3")
        #expect(sent.title == "Le Livre d'Essai")
        #expect(sent.authors == ["Jeanne Dupont"])
        #expect(sent.format == "AZW3")
        #expect(sent.cdeType == "EBOK")
        #expect(!sent.isDRMProtected)
        #expect(catalog.coverURL(sent).map { FileManager.default.fileExists(atPath: $0.path) } == true)

        let bought = info(".azw")
        #expect(bought.isDRMProtected)
        #expect(bought.title == "Le Livre d'Essai")

        let kfx = info(".kfx")
        #expect(kfx.isGuessed)
        #expect(kfx.title == "Le Petit Prince")
        #expect(kfx.asin == "B0ABCDEFGH")
        #expect(kfx.coverKey != nil, "miniature de la Kindle utilisée comme couverture")

        // Le cache survit à un rechargement.
        catalog.save()
        let reloaded = KindleCatalog(directories: dirs)
        #expect(reloaded.cached(docs[0]) != nil)
    }
}

@Suite struct ScannerTests {
    @Test func addedDateFollowsFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("ancien.epub")
        try EPUBBuilder(metadata: BookMetadata(title: "x")).write(to: old)
        let files = FolderScanner.scan([dir])
        #expect(files.count == 1)
        // Date d'arrivée du fichier dans le dossier, telle que fournie par macOS.
        let expected = try old.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate
        #expect(expected != nil)
        #expect(files[0].addedAt == expected)
        let book = FolderScanner.makeBook(files[0], imported: false,
                                          coverStore: CoverStore(directory: dir))
        #expect(book.addedAt == files[0].addedAt)
    }
}

@Suite struct KindleIdentifierTests {
    @Test func volumeIdentifierIsStable() {
        let root = tempDirectory()
        let a = VolumeKindle(root: root), b = VolumeKindle(root: root)
        #expect(a.identifier.hasPrefix("vol:"))
        #expect(a.identifier.count > 4)
        #expect(a.identifier == b.identifier)
    }
}

@Suite struct ReaderListTests {
    @Test func roundTripAndMissingFile() throws {
        let url = tempDirectory().appendingPathComponent("readers.json")
        #expect(try ReaderList.load(url).isEmpty)
        let readers = [Reader(id: "vol:ABC", name: "Kindle de Léa", seenAt: Date(timeIntervalSince1970: 1)),
                       Reader(id: "mtp:G0001", name: "Kindle de Paul", seenAt: Date(timeIntervalSince1970: 2))]
        try ReaderList.save(readers, to: url)
        #expect(try ReaderList.load(url) == readers)
    }
}

@Suite struct ShelfSyncTests {
    func book(_ path: String, _ title: String, _ format: BookFormat = .epub, sent: String? = nil, drm: Bool = false) -> Book {
        var b = Book(path: path, format: format, fingerprint: path, fileSize: 0, modifiedAt: Date(), addedAt: Date(),
                     title: title, authors: ["Auteur"], tags: [], hasCover: false, isDRMProtected: drm, isImported: false, asin: "A")
        b.sentFilename = sent
        return b
    }

    @Test func missingBooksOfShelf() {
        let shelf = BookGroups.make([
            book("/a.epub", "Candide", sent: "Candide - Auteur.azw3"),        // sur la Kindle par son nom d'envoi
            book("/b.azw3", "L'Étranger", .azw3),                              // sur la Kindle par son titre
            book("/c.epub", "Zadig"),                                          // absent : à envoyer
            book("/d.epub", "Protégé", drm: true),                             // absent mais non envoyable
            book("/e1.azw3", "Micromégas", .azw3), book("/e2.epub", "Micromégas"), // absent : un seul envoi
        ])
        let missing = ShelfSync.missing(shelf, documentNames: ["Candide - Auteur.azw3"],
                                        deviceTitles: [ShelfSync.normalize("l’Etranger")])
        #expect(missing.map(\.title).sorted() == ["Micromégas", "Zadig"])
        #expect(missing.first { $0.title == "Micromégas" }?.format == .azw3)
    }
}
