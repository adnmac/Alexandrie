import FolunaCore
import AppKit
import CoreText
import Foundation
import PDFKit

/// Livres d'exemple pour les captures (`FOLUNA_SEED=1`), écrits dans le dossier de test seulement.
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
        /// Plusieurs chapitres : un vrai livre à lire dans la fenêtre de lecture.
        var chapters = 1
        /// Notes de bas de page au premier chapitre (S-103).
        var notes = false
        /// Dans le second dossier de livres (« Disque externe ») plutôt que dans « Livres ».
        var external = false
    }

    /// Exemples en anglais pour les captures anglaises du site (`FOLUNA_SEED_LANG=en`, posé par `scripts/snap.sh`) ;
    /// en français sinon, y compris pour le self-test.
    static let english = ProcessInfo.processInfo.environment["FOLUNA_SEED_LANG"] == "en"
    static func t(_ french: String, _ englishText: String) -> String { english ? englishText : french }

    /// Noms repris par les captures (`Snapshot.swift`) : ils suivent la langue des exemples.
    static let harbour = t("Le Port des brumes", "Harbour of Mists")
    static let slowHours = t("Les Heures lentes", "The Slow Hours")
    static let lowTide = t("Mort à marée basse", "Death at Low Tide")
    static let longHistory = t("Une très longue histoire de la cartographie des mers du Nord, de l'Antiquité à nos jours",
                               "A Very Long History of the Mapping of the North Seas, from Antiquity to the Present Day")
    static let orbit = t("Orbite", "Orbit")
    static let travelNotebook = t("Carnet de voyage", "Travel Notebook")
    static let riverHandbook = t("Manuel du fleuve", "River Handbook")
    static let oldMaps = t("Plans anciens", "Old Maps")
    static let vidalSeries = t("Commissaire Vidal", "Inspector Vidal")
    static let crime = t("Policier", "Crime")
    static let publisher = t("Éditions d'Exemple", "Example Press")
    static let language = t("fr", "en")
    /// Mot du texte des livres (recherche dans le contenu) et mot des renvois de la fenêtre de lecture.
    static let searchWord = t("brume", "mist")
    static let lighthouse = t("phare", "lighthouse")
    static let backupFolder = t("iCloud Drive (exemple)", "iCloud Drive (example)")

    static let samples: [Sample] = [
        Sample(title: t("La Maison au bord du fleuve", "The House by the River"), authors: ["Claire Morel"],
               genre: t("Roman", "Novel"), year: "2019", cover: .systemTeal),
        Sample(title: slowHours, authors: ["Claire Morel"], genre: t("Roman", "Novel"), year: "2022", cover: .systemIndigo),
        Sample(title: harbour, authors: ["Hugo Lambert"], genre: crime, series: vidalSeries,
               index: 1, year: "2015", cover: .systemGray, chapters: 4, notes: true),
        Sample(title: lowTide, authors: ["Hugo Lambert"], genre: crime, series: vidalSeries,
               index: 2, year: "2016", cover: .systemBrown),
        Sample(title: t("Le Dernier Ferry", "The Last Ferry"), authors: ["Hugo Lambert"], genre: crime, series: vidalSeries,
               index: 3, year: "2018", cover: .systemRed),
        Sample(title: longHistory, authors: ["Inès Garnier"], genre: t("Histoire", "History"), year: "2011", cover: .systemOrange),
        Sample(title: orbit, authors: ["Samuel Okafor"], genre: t("Science-fiction", "Science Fiction"), year: "2021",
               cover: .black, external: true),
        Sample(title: t("Les Jardins de Titan", "The Gardens of Titan"), authors: ["Samuel Okafor"],
               genre: t("Science-fiction", "Science Fiction"), series: t("Cycle de Saturne", "Saturn Cycle"),
               index: 1, year: "2023", cover: .systemPurple, external: true),
        Sample(title: t("Sel", "Salt"), authors: ["Léa Fontaine"], genre: t("Poésie", "Poetry"), year: "2020", cover: nil),
        Sample(title: t("Petit traité de la patience", "A Short Treatise on Patience"), authors: ["Marc Aubert", "Julie Roy"],
               genre: t("Essai", "Essay"), year: "2017", cover: .systemGreen),
        Sample(title: t("Nuit d'orage à Bruges", "Storm Night in Bruges"), authors: ["Anne Verhaegen"], genre: crime,
               year: "2024", cover: .systemPink),
        Sample(title: t("Le Goût des pommes", "The Taste of Apples"), authors: ["Léa Fontaine"], genre: t("Roman", "Novel"),
               year: "2025", cover: .systemYellow),
        Sample(title: t("Atlas des vents", "Atlas of Winds"), authors: ["Inès Garnier"], genre: t("Histoire", "History"),
               year: "2014", cover: .systemCyan, azw3: true),
        Sample(title: travelNotebook, authors: ["Paul Martin"], genre: t("Récit", "Memoir"), year: "2009", cover: .systemMint),
    ]

    /// Second dossier de livres des captures (page « dossier-exemple »).
    static var externalFolder: URL? {
        AppDirectories.testStore?.appendingPathComponent(t("Disque externe", "External Drive"), isDirectory: true)
    }

    /// Avant le lancement de l'app : remplit deux dossiers de test vides et y fait pointer `FOLUNA_BOOKS`.
    static func seedIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["FOLUNA_SEED"] == "1", let store = AppDirectories.testStore, let external = externalFolder else { return }
        let folder = store.appendingPathComponent(t("Livres", "Books"), isDirectory: true)
        // Troisième dossier jamais créé : un disque débranché, pour la capture de l'état indisponible (S-062).
        let unplugged = store.appendingPathComponent(t("Clé USB", "USB Stick"), isDirectory: true)
        setenv("FOLUNA_BOOKS", [folder, external, unplugged].map(\.path).joined(separator: ":"), 1)
        guard !FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            for f in [folder, external] { try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true) }
            for s in samples { try write(s, in: s.external ? external : folder) }
            // PDF (S-064, S-065) : un texte de plusieurs pages, et un scan sans texte.
            try makePDF(title: riverHandbook, author: "Claire Morel", pages: 6, in: folder)
            try makePDF(title: oldMaps, author: "Inès Garnier", pages: 3, scanned: true, in: folder)
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
        if let book = library.books.first(where: { $0.title == travelNotebook }), book.trashedAt == nil {
            library.moveToTrash(book)
        }
        if let book = library.books.first(where: { $0.title == orbit }), book.pendingSendAt == nil {
            library.queueForKindle([book], reader: nil)
        }
        // Favoris (S-107) : une étoile sur la couverture du « Port des brumes ».
        if let book = library.books.first(where: { $0.title == harbour }), !book.isFavorite {
            library.setFavorite([book], on: true)
        }
        // Lecture commencée (S-068) : la fiche montre « 42 % lu ».
        if let book = library.books.first(where: { $0.title == slowHours }) {
            AppServices.shared.reading.record(ReadingPosition(chapter: 0, fraction: 0.42, percent: 0.42), for: book)
        }
        addReaderHighlights(library, kindle: AppServices.shared.kindle)
        addResearches(library, kindle: AppServices.shared.kindle, store: AppServices.shared.researches)
    }

    /// Notes d'une Kindle : la date est écrite dans la langue de la Kindle (française, ou anglaise pour les captures anglaises).
    private static let clippings: [Clipping] = [
        Clipping(title: harbour, author: "Hugo Lambert", kind: .highlight, location: "page 12 · emplacement 180-182",
                 added: t("mardi 3 novembre 2026 10:12:33", "Tuesday, 3 November 2026 10:12:33"),
                 text: t("La brume montait du port comme une marée à l'envers.", "The mist rose from the harbour like a tide in reverse.")),
        Clipping(title: harbour, author: "Hugo Lambert", kind: .note, location: "page 12 · emplacement 182",
                 added: t("mardi 3 novembre 2026 10:13:02", "Tuesday, 3 November 2026 10:13:02"),
                 text: t("Relire ce passage pour la scène du quai.", "Reread this passage for the scene on the quay.")),
        Clipping(title: harbour, author: "Hugo Lambert", kind: .highlight, location: "page 87 · emplacement 1304-1310",
                 added: t("mercredi 4 novembre 2026 21:40:11", "Wednesday, 4 November 2026 21:40:11"),
                 text: t("Vidal savait que les témoins se taisent rarement par peur ; le plus souvent, c'est par lassitude, parce que personne ne leur a jamais posé la bonne question.",
                         "Vidal knew that witnesses rarely keep quiet out of fear; more often it is out of weariness, because nobody has ever asked them the right question.")),
        Clipping(title: orbit, author: "Samuel Okafor", kind: .highlight, location: "page 3 · emplacement 40-41",
                 added: t("lundi 2 novembre 2026 08:05:47", "Monday, 2 November 2026 08:05:47"),
                 text: t("Vu d'en haut, aucune frontière ne tient.", "Seen from above, no border holds.")),
    ]

    private static func write(_ s: Sample, in folder: URL) throws {
        var meta = BookMetadata(title: s.title, authors: s.authors, language: language, publisher: publisher,
                                summary: t("Livre d'exemple pour les captures d'écran de Foluna.", "Sample book for Foluna's screenshots."))
        meta.series = s.series
        meta.seriesIndex = s.index
        meta.publishedDate = s.year
        meta.subjects = [s.genre]
        let epub = try makeEPUB(meta, cover: s.cover.flatMap { coverPNG(title: s.title, color: $0) }, chapters: s.chapters,
                                notes: s.notes, in: folder)
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
        let paragraph = english
            ? ["The river flows slowly down to the sea through the plains and", "the sleeping villages.",
               "Each season changes its colour and the height of its waters, which the", "boatmen measure with care.",
               "This handbook describes the channels, the locks and the harbours where", "you can stop for the night."]
            : ["Le fleuve descend lentement vers la mer en traversant les plaines et", "les villages endormis.",
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

    static func chapterTitle(_ c: Int, of chapters: Int, english: Bool = SeedData.english) -> String {
        let names = english ? ["The Quay", "The Mist", "The Lighthouse", "The Tide"] : ["Le quai", "La brume", "Le phare", "La marée"]
        return chapters == 1 ? (english ? "Chapter 1" : "Chapitre 1") : "\(c). \(names[(c - 1) % names.count])"
    }

    /// Notes de bas de page du premier chapitre (S-103) : deux courtes, en bulle, et une longue, dans le panneau.
    static func footnotes(english: Bool = SeedData.english) -> [String] {
        english
            ? ["The harbour was rebuilt after the great storm of 1953.",
               "The nickname the dockers gave the inspector, after his grey coat.",
               "The last ferry left the island at a quarter past nine in winter and at ten in summer. The timetable, "
                + "pinned up in the harbour office, had not changed for twenty years; everyone knew it by heart, and "
                + "nobody ever checked it, which is precisely why the inspector went to read it on the evening of the "
                + "disappearance. He noticed that someone had added, in pencil, a crossing that did not exist."]
            : ["Le port a été reconstruit après la grande tempête de 1953.",
               "Surnom donné au commissaire par les dockers, à cause de son manteau gris.",
               "Le dernier ferry quittait l'île à neuf heures et quart en hiver, à dix heures en été. L'horaire, punaisé "
                + "dans le bureau du port, n'avait pas changé depuis vingt ans ; tout le monde le connaissait par cœur, "
                + "et personne ne le vérifiait jamais, ce qui explique que le commissaire soit allé le lire le soir de "
                + "la disparition. Il remarqua qu'on y avait ajouté, au crayon, une traversée qui n'existait pas."]
    }

    /// Passages surlignés dans « Le Port des brumes » (fenêtre de lecture) : ils sont dans le texte des paragraphes.
    static let readerPassage = t("le commissaire attendait sur le quai que le dernier ferry rentre",
                                 "the inspector waited on the quay for the last ferry to come in")
    static let readerPinkPassage = t("on entendait seulement les haussières grincer", "all you could hear were the mooring lines creaking")

    /// Textes des paragraphes d'un chapitre (sans balises).
    static func paragraphs(chapter c: Int, of chapters: Int, bookTitle: String, english: Bool = SeedData.english) -> [String] {
        guard chapters > 1 else {
            return [english ? "A paragraph from “\(bookTitle)”." : "Un paragraphe de « \(bookTitle) », avec des accents : été, œuvre."]
        }
        return (1...18).map { p in
            english
                ? "The mist rose from the harbour like a tide in reverse, and the inspector waited on the quay for the last ferry "
                    + "to come in. Nobody spoke; all you could hear were the mooring lines creaking against the bollards and, "
                    + "further off, the lighthouse horn counting the minutes (\(c).\(p))."
                : "La brume montait du port comme une marée à l'envers, et le commissaire attendait sur le quai que "
                    + "le dernier ferry rentre. Personne ne parlait ; on entendait seulement les haussières grincer contre "
                    + "les bittes d'amarrage et, plus loin, la corne du phare qui comptait les minutes (\(c).\(p))."
        }
    }

    /// Texte du corps d'un chapitre tel que la page le lit (`textContent`) : titre et paragraphes, un saut de ligne entre.
    static func chapterText(_ c: Int, of chapters: Int, bookTitle: String) -> String {
        ([chapterTitle(c, of: chapters)] + paragraphs(chapter: c, of: chapters, bookTitle: bookTitle)).joined(separator: "\n") + "\n"
    }

    /// Surlignages faits dans la fenêtre de lecture (S-070) : un dans un EPUB, un dans un PDF.
    /// Deux thématiques (S-075, S-079) ; « Le Port des brumes » est lu pour « Rénovation des voiries », dont la
    /// légende nomme ses couleurs ; « Mesures de trafic » est une couleur ajoutée. Le passage rose sert aussi
    /// au « Mémoire de master » : un passage, deux thématiques.
    static func addResearches(_ library: LibraryStore, kindle: KindleMonitor, store: ResearchStore) {
        guard store.researches.isEmpty, let book = library.books.first(where: { $0.title == harbour }) else { return }
        var roads = store.addResearch(name: t("Rénovation des voiries", "Road Renovation"))
        let roadThemes = english
            ? ["Construction", "Contractors", "Civil Engineering", "Cost Analysis", "Regulations"]
            : ["Construction", "Entreprises", "Génie civil", "Analyse des coûts", "Réglementation"]
        for (i, name) in roadThemes.enumerated() {
            roads.themes[i].name = name
        }
        roads.addTheme(name: t("Mesures de trafic", "Traffic Counts"))
        store.update(roads)
        var memoir = store.addResearch(name: t("Mémoire de master", "Master's Thesis"))
        let memoirThemes = english ? ["Anthropology", "Method", "Fieldwork", "Sociology"] : ["Anthropologie", "Méthode", "Terrain", "Sociologie"]
        for (i, name) in memoirThemes.enumerated() { memoir.themes[i].name = name }
        memoir.themes.removeLast()
        store.update(memoir)
        store.setActive(roads.id, for: book)
        let highlights = kindle.readerHighlights(of: book)
        for h in highlights { store.setThematic(roads.id, on: true, for: h.id) }
        if highlights.count > 1 { store.setThematic(memoir.id, on: true, for: highlights[1].id) }
        // Le prochain surlignage sera jaune, « Construction ».
        store.remember(HighlightMark(roads.themes[0]), in: roads.id)
    }

    static func addReaderHighlights(_ library: LibraryStore, kindle: KindleMonitor) {
        if let book = library.books.first(where: { $0.title == harbour }), kindle.readerHighlights(of: book).isEmpty {
            // Deuxième chapitre, douzième paragraphe : sur la page où la lecture reprend.
            let text = chapterText(2, of: 4, bookTitle: book.title)
            let passage = readerPassage
            let paragraph = paragraphs(chapter: 2, of: 4, bookTitle: book.title)[11]
            if let p = text.range(of: paragraph), let r = text[p].range(of: passage) {
                let start = text.utf16.distance(from: text.startIndex, to: r.lowerBound)
                let end = start + passage.utf16.count
                let weights = [1, 2, 3, 4].map { (chapterText($0, of: 4, bookTitle: book.title).utf8.count) }
                let order = ReaderAnchor.estimatedLocation(chapter: 1, offset: start, textLength: text.utf16.count, weights: weights)
                let clipping = Clipping.readerHighlight(title: book.title, author: book.authorLine, text: passage,
                                                        anchor: ReaderAnchor(book: book.fingerprint, chapter: 1, start: start,
                                                                             end: end, order: order), isPDF: false)
                kindle.addHighlight(clipping)
                // Annoté (S-071) : le repère de note se voit dans la page et dans « Notes et surlignages ».
                kindle.setNote(clipping.id, t("Il attend toujours au même endroit : à rapprocher du dernier chapitre.",
                                              "He always waits in the same spot: compare with the last chapter."))
                // Un deuxième passage, en rose, deux paragraphes plus bas (S-073).
                let pink = readerPinkPassage
                if let p2 = text.range(of: paragraphs(chapter: 2, of: 4, bookTitle: book.title)[13]),
                   let r2 = text[p2].range(of: pink) {
                    let start2 = text.utf16.distance(from: text.startIndex, to: r2.lowerBound)
                    kindle.addHighlight(.readerHighlight(title: book.title, author: book.authorLine, text: pink,
                                                         anchor: ReaderAnchor(book: book.fingerprint, chapter: 1, start: start2,
                                                                              end: start2 + pink.utf16.count, order: order + 1),
                                                         isPDF: false, color: .pink))
                }
            }
        }
        if let book = library.books.first(where: { $0.title == riverHandbook }), kindle.readerHighlights(of: book).isEmpty,
           let page = PDFDocument(url: book.url)?.page(at: 0), let string = page.string {
            let passage = t("Chaque saison change sa couleur et la hauteur de ses eaux", "Each season changes its colour and the height of its waters")
            let range = (string as NSString).range(of: passage)
            if range.location != NSNotFound {
                let clipping = Clipping.readerHighlight(title: book.title, author: book.authorLine, text: passage,
                                                        anchor: ReaderAnchor(book: book.fingerprint, chapter: 0, start: range.location,
                                                                             end: NSMaxRange(range), order: 1), isPDF: true)
                kindle.addHighlight(clipping)
                kindle.setNote(clipping.id, t("Comparer avec les relevés de crue.", "Compare with the flood records."))
                // Une autre couleur que le jaune (S-073).
                kindle.setColor(clipping.id, .green)
            }
        }
    }

    /// EPUB minimal (un chapitre), avec une couverture si `cover` est fourni. Titre sans & ni <.
    /// `chapters` > 1 : un livre de plusieurs pages, pour la fenêtre de lecture (S-066 à S-070).
    /// `english` : langue du texte des chapitres (la traduction de la comparaison est dans l'autre langue).
    static func makeEPUB(_ meta: BookMetadata, cover: Data?, chapters: Int = 1, notes: Bool = false,
                         english: Bool = SeedData.english, in folder: URL) throws -> URL {
        var epub = EPUBBuilder(metadata: meta)
        if let cover {
            epub.add("Images/cover.png", mediaType: "image/png", data: cover)
            epub.coverPath = "Images/cover.png"
        }
        for c in 1...chapters {
            let title = chapterTitle(c, of: chapters, english: english)
            let texts = paragraphs(chapter: c, of: chapters, bookTitle: meta.title, english: english)
            // Appels de note EPUB 3 au bout des premiers paragraphes, notes en fin de chapitre.
            let calls = notes && c == 1 ? footnotes(english: english) : []
            var body = texts.enumerated().map { i, text in
                let call = i < calls.count ? "<sup><a epub:type=\"noteref\" href=\"#n\(i + 1)\" id=\"r\(i + 1)\">\(i + 1)</a></sup>" : ""
                return "<p>\(text)\(call)</p>"
            }.joined(separator: "\n")
            for (i, note) in calls.enumerated() {
                body += "\n<aside epub:type=\"footnote\" id=\"n\(i + 1)\"><p><a href=\"#r\(i + 1)\">\(i + 1).</a> \(note)</p></aside>"
            }
            let html = """
                <?xml version="1.0" encoding="utf-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(meta.language ?? "fr")">
                <head><title>\(meta.title)</title></head>
                <body><h1>\(title)</h1>
                \(body)
                </body>
                </html>
                """
            epub.add("Text/chapter\(c).xhtml", mediaType: "application/xhtml+xml", data: Data(html.utf8), inSpine: true)
            epub.toc.append(TOCNode(title: title, path: "Text/chapter\(c).xhtml"))
        }
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
