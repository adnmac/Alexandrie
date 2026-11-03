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

@Suite struct ClippingsTests {
    let sample = "\u{FEFF}Le Rouge et le Noir (Stendhal)\r\n- Votre surlignement sur la page 12 | emplacement 180-182 | Ajouté le mardi 3 novembre 2026 10:12:33\r\n\r\nOn n'a guère besoin d'appuyer.\r\n==========\r\n"
        + "Le Rouge et le Noir (Stendhal)\r\n- Votre note à l'emplacement 182 | Ajouté le mardi 3 novembre 2026 10:13:01\r\n\r\nÀ relire.\r\n==========\r\n"
        + "La plus belle ruse de la lumière (French Edition) (David Elbaz)\r\n- Votre signet à l'emplacement 40 | Ajouté le lundi 2 novembre 2026 09:00:00\r\n\r\n\r\n==========\r\n"
        + "Dune (Frank Herbert)\r\n- Your Highlight on page 3 | Location 41-42 | Added on Monday, 2 November 2026 08:00:00\r\n\r\nFear is the mind-killer.\r\n==========\r\n"

    @Test func parsesFrenchAndEnglishEntries() {
        let c = KindleClippings.parse(sample)
        #expect(c.count == 4)
        #expect(c[0].title == "Le Rouge et le Noir" && c[0].author == "Stendhal")
        #expect(c[0].kind == .highlight && c[0].location == "page 12 · emplacement 180-182")
        #expect(c[0].text == "On n'a guère besoin d'appuyer.")
        #expect(c[0].added == "mardi 3 novembre 2026 10:12:33")
        #expect(c[1].kind == .note && c[1].text == "À relire." && c[1].location == "emplacement 182")
        #expect(c[2].kind == .bookmark && c[2].title == "La plus belle ruse de la lumière (French Edition)")
        #expect(c[3].kind == .highlight && c[3].location == "page 3 · emplacement 41-42" && c[3].added.hasPrefix("Monday"))
    }

    @Test func mergeKeepsEachClippingOnce() throws {
        let first = KindleClippings.parse(sample)
        let merged = KindleClippings.merge(first, KindleClippings.parse(sample))
        #expect(merged.count == first.count)
        let url = tempDirectory().appendingPathComponent("clippings.json")
        try KindleClippings.save(merged, to: url)
        #expect(KindleClippings.load(url) == merged)
    }
}
