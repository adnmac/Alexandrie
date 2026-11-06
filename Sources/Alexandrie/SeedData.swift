import AlexandrieCore
import AppKit
import CoreText
import Foundation

/// Livres d'exemple pour les captures (`ALEXANDRIE_SEED=1`), écrits dans le dossier de test seulement.
/// Titres longs et courts, séries, plusieurs auteurs, un livre sans couverture, un AZW3, des notes Kindle.
@MainActor
enum SeedData {
    struct Sample {
        var title: String
        var authors: [String]
        var genre: String
        var series: String? = nil
        var index: Double? = nil
        var year: String
        var cover: NSColor? = .systemBlue
        var azw3 = false
        /// Dans le second dossier de livres (« Disque externe ») plutôt que dans « Livres ».
        var external = false
    }

    static let samples: [Sample] = [
        Sample(title: "La Maison au bord du fleuve", authors: ["Claire Morel"], genre: "Roman", year: "2019", cover: .systemTeal),
        Sample(title: "Les Heures lentes", authors: ["Claire Morel"], genre: "Roman", year: "2022", cover: .systemIndigo),
        Sample(title: "Le Port des brumes", authors: ["Hugo Lambert"], genre: "Policier", series: "Commissaire Vidal",
               index: 1, year: "2015", cover: .systemGray),
        Sample(title: "Mort à marée basse", authors: ["Hugo Lambert"], genre: "Policier", series: "Commissaire Vidal",
               index: 2, year: "2016", cover: .systemBrown),
        Sample(title: "Le Dernier Ferry", authors: ["Hugo Lambert"], genre: "Policier", series: "Commissaire Vidal",
               index: 3, year: "2018", cover: .systemRed),
        Sample(title: "Une très longue histoire de la cartographie des mers du Nord, de l'Antiquité à nos jours",
               authors: ["Inès Garnier"], genre: "Histoire", year: "2011", cover: .systemOrange),
        Sample(title: "Orbite", authors: ["Samuel Okafor"], genre: "Science-fiction", year: "2021", cover: .black, external: true),
        Sample(title: "Les Jardins de Titan", authors: ["Samuel Okafor"], genre: "Science-fiction", series: "Cycle de Saturne",
               index: 1, year: "2023", cover: .systemPurple, external: true),
        Sample(title: "Sel", authors: ["Léa Fontaine"], genre: "Poésie", year: "2020", cover: nil),
        Sample(title: "Petit traité de la patience", authors: ["Marc Aubert", "Julie Roy"], genre: "Essai", year: "2017",
               cover: .systemGreen),
        Sample(title: "Nuit d'orage à Bruges", authors: ["Anne Verhaegen"], genre: "Policier", year: "2024", cover: .systemPink),
        Sample(title: "Le Goût des pommes", authors: ["Léa Fontaine"], genre: "Roman", year: "2025", cover: .systemYellow),
        Sample(title: "Atlas des vents", authors: ["Inès Garnier"], genre: "Histoire", year: "2014", cover: .systemCyan, azw3: true),
        Sample(title: "Carnet de voyage", authors: ["Paul Martin"], genre: "Récit", year: "2009", cover: .systemMint),
    ]

    /// Second dossier de livres des captures (page « dossier-exemple »).
    static var externalFolder: URL? {
        AppDirectories.testStore?.appendingPathComponent("Disque externe", isDirectory: true)
    }

    /// Avant le lancement de l'app : remplit deux dossiers de test vides et y fait pointer `ALEXANDRIE_BOOKS`.
    static func seedIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["ALEXANDRIE_SEED"] == "1", let store = AppDirectories.testStore, let external = externalFolder else { return }
        let folder = store.appendingPathComponent("Livres", isDirectory: true)
        // Troisième dossier jamais créé : un disque débranché, pour la capture de l'état indisponible (S-062).
        let unplugged = store.appendingPathComponent("Clé USB", isDirectory: true)
        setenv("ALEXANDRIE_BOOKS", [folder, external, unplugged].map(\.path).joined(separator: ":"), 1)
        guard !FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            for f in [folder, external] { try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true) }
            for s in samples { try write(s, in: s.external ? external : folder) }
            // PDF (S-064, S-065) : un texte de plusieurs pages, et un scan sans texte.
            try makePDF(title: "Manuel du fleuve", author: "Claire Morel", pages: 6, in: folder)
            try makePDF(title: "Plans anciens", author: "Inès Garnier", pages: 3, scanned: true, in: folder)
            try KindleClippings.save(clippings, to: AppDirectories(base: store).clippings)
        } catch {
            FileHandle.standardError.write(Data("SEED échec : \(error.localizedDescription)\n".utf8))
        }
    }

    /// Après l'indexation : ce qu'une personne fait dans l'app (genres, corbeille, file d'envoi).
    static func prepare(_ library: LibraryStore) {
        for s in samples {
            guard var book = library.books.first(where: { $0.title == s.title }), book.genre == nil else { continue }
            book.genre = s.genre
            library.update(book)
        }
        if let book = library.books.first(where: { $0.title == "Carnet de voyage" }), book.trashedAt == nil {
            library.moveToTrash(book)
        }
        if let book = library.books.first(where: { $0.title == "Orbite" }), book.pendingSendAt == nil {
            library.queueForKindle([book], reader: nil)
        }
    }

    private static let clippings: [Clipping] = [
        Clipping(title: "Le Port des brumes", author: "Hugo Lambert", kind: .highlight, location: "page 12 · emplacement 180-182",
                 added: "mardi 3 novembre 2026 10:12:33", text: "La brume montait du port comme une marée à l'envers."),
        Clipping(title: "Le Port des brumes", author: "Hugo Lambert", kind: .note, location: "page 12 · emplacement 182",
                 added: "mardi 3 novembre 2026 10:13:02", text: "Relire ce passage pour la scène du quai."),
        Clipping(title: "Le Port des brumes", author: "Hugo Lambert", kind: .highlight, location: "page 87 · emplacement 1304-1310",
                 added: "mercredi 4 novembre 2026 21:40:11",
                 text: "Vidal savait que les témoins se taisent rarement par peur ; le plus souvent, c'est par lassitude, parce que personne ne leur a jamais posé la bonne question."),
        Clipping(title: "Orbite", author: "Samuel Okafor", kind: .highlight, location: "page 3 · emplacement 40-41",
                 added: "lundi 2 novembre 2026 08:05:47", text: "Vu d'en haut, aucune frontière ne tient."),
    ]

    private static func write(_ s: Sample, in folder: URL) throws {
        var meta = BookMetadata(title: s.title, authors: s.authors, language: "fr", publisher: "Éditions d'Exemple",
                                summary: "Livre d'exemple pour les captures d'écran d'Alexandrie.")
        meta.series = s.series
        meta.seriesIndex = s.index
        meta.publishedDate = s.year
        meta.subjects = [s.genre]
        let epub = try makeEPUB(meta, cover: s.cover.flatMap { coverPNG(title: s.title, color: $0) }, in: folder)
        if s.azw3 {
            try EPUBToAZW3.convert(input: epub, output: epub.deletingPathExtension().appendingPathExtension("azw3"))
            try FileManager.default.removeItem(at: epub)
        }
    }

    /// PDF A5 aux larges marges : en-tête répété, paragraphes, numéro de page. `scanned` : de l'encre sans texte.
    @discardableResult
    static func makePDF(title: String, author: String, pages: Int, scanned: Bool = false, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(title.safeFilename + ".pdf")
        var box = CGRect(x: 0, y: 0, width: 420, height: 595)  // grid: ok page A5 en points PDF, pas une vue
        let info = [kCGPDFContextTitle: title, kCGPDFContextAuthor: author] as CFDictionary
        guard let context = CGContext(url as CFURL, mediaBox: &box, info) else {
            throw BookError.conversionFailed("PDF d'exemple")
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
        let paragraph = ["Le fleuve descend lentement vers la mer en traversant les plaines et", "les villages endormis.",
                         "Chaque saison change sa couleur et la hauteur de ses eaux, que les", "bateliers mesurent avec soin.",
                         "Ce manuel décrit les passages, les écluses et les ports où l'on peut", "s'arrêter pour la nuit."]
        for n in 1...pages {
            context.beginPDFPage(nil)
            if scanned {
                context.setFillColor(gray: 0.35, alpha: 1)
                context.fill(CGRect(x: 90, y: 160, width: 240, height: 300))
            } else {
                for (i, line) in ([title] + paragraph + ["\(n)"]).enumerated() {
                    let text = NSAttributedString(string: line, attributes: [.font: font])
                    context.textPosition = CGPoint(x: i == paragraph.count + 1 ? 205 : 90, y: 470 - CGFloat(i) * 16)
                    CTLineDraw(CTLineCreateWithAttributedString(text), context)
                }
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// EPUB minimal (un chapitre), avec une couverture si `cover` est fourni. Titre sans & ni <.
    static func makeEPUB(_ meta: BookMetadata, cover: Data?, in folder: URL) throws -> URL {
        var epub = EPUBBuilder(metadata: meta)
        if let cover {
            epub.add("Images/cover.png", mediaType: "image/png", data: cover)
            epub.coverPath = "Images/cover.png"
        }
        let html = """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="fr">
            <head><title>\(meta.title)</title></head>
            <body><h1>Chapitre 1</h1><p>Un paragraphe de « \(meta.title) », avec des accents : été, œuvre.</p></body>
            </html>
            """
        epub.add("Text/chapter1.xhtml", mediaType: "application/xhtml+xml", data: Data(html.utf8), inSpine: true)
        epub.toc = [TOCNode(title: "Chapitre 1", path: "Text/chapter1.xhtml")]
        let url = folder.appendingPathComponent(meta.title.safeFilename + ".epub")
        try epub.write(to: url)
        return url
    }

    /// Couverture 400 × 600 : un aplat de couleur et le titre.
    static func coverPNG(title: String, color: NSColor) -> Data? {
        let size = NSSize(width: 400, height: 600)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: style,
        ]
        (title as NSString).draw(in: NSRect(x: 32, y: 120, width: size.width - 64, height: 360), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
