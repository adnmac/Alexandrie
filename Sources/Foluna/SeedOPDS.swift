import FolunaCore
import AppKit
import Foundation

/// Catalogue OPDS d'exemple, sans réseau : captures (`scripts/snap.sh`) et self-test.
/// Toute adresse rend le même flux ; les couvertures et les livres sont fabriqués sur place.
extension SeedData {
    struct OPDSBook {
        var id: String
        var title: String
        var author: String
        var summary: String
        var color: NSColor
        var language = "fr"
    }

    /// Livres du domaine public. Un seul est dans une autre langue que les exemples : le filtre « Langue » le masque.
    static let opdsBooks: [OPDSBook] = english ? [
        OPDSBook(id: "twenty-thousand", title: "Twenty Thousand Leagues Under the Seas", author: "Jules Verne",
                 summary: "Professor Aronnax, his servant Conseil and the harpooner Ned Land, prisoners of Captain Nemo, travel the oceans aboard the Nautilus.",
                 color: .systemBlue, language: "en"),
        OPDSBook(id: "pride-prejudice", title: "Pride and Prejudice", author: "Jane Austen",
                 summary: "Elizabeth Bennet and the proud Mr Darcy learn to see past their first impressions.",
                 color: .systemOrange, language: "en"),
        OPDSBook(id: "moby-dick", title: "Moby-Dick", author: "Herman Melville",
                 summary: "Ishmael sails on the whaler Pequod, whose captain Ahab hunts the white whale.",
                 color: .systemIndigo, language: "en"),
        OPDSBook(id: "treasure-island", title: "Treasure Island", author: "Robert Louis Stevenson",
                 summary: "Young Jim Hawkins finds a map that leads to a pirate's buried treasure.",
                 color: .systemRed, language: "en"),
        OPDSBook(id: "bel-ami", title: "Bel-Ami", author: "Guy de Maupassant",
                 summary: "L'ascension de Georges Duroy dans la presse et la société parisiennes.",
                 color: .systemGreen),
    ] : [
        OPDSBook(id: "vingt-mille", title: "Vingt mille lieues sous les mers", author: "Jules Verne",
                 summary: "Le professeur Aronnax, son domestique Conseil et le harponneur Ned Land, captifs du capitaine Nemo, parcourent les océans à bord du Nautilus.",
                 color: .systemBlue),
        OPDSBook(id: "tour-du-monde", title: "Le Tour du monde en quatre-vingts jours", author: "Jules Verne",
                 summary: "Phileas Fogg parie qu'il fera le tour du monde en quatre-vingts jours ; Passepartout l'accompagne.",
                 color: .systemOrange),
        OPDSBook(id: "contemplations", title: "Les Contemplations", author: "Victor Hugo",
                 summary: "Recueil de poèmes en deux parties, « Autrefois » et « Aujourd'hui ».",
                 color: .systemIndigo),
        OPDSBook(id: "bel-ami", title: "Bel-Ami", author: "Guy de Maupassant",
                 summary: "L'ascension de Georges Duroy dans la presse et la société parisiennes.",
                 color: .systemRed),
        OPDSBook(id: "treasure-island", title: "Treasure Island", author: "Robert Louis Stevenson",
                 summary: "Young Jim Hawkins finds a map that leads to a pirate's buried treasure.",
                 color: .systemGreen, language: "en"),
    ]

    /// Flux d'accueil : deux sous-catalogues, puis les livres (EPUB, et MOBI pour le premier).
    static var opdsFeed: Data {
        let entries = opdsBooks.enumerated().map { i, b in
            """
            <entry><title>\(b.title)</title><id>urn:exemple:\(b.id)</id>
            <author><name>\(b.author)</name></author><dcterms:language>\(b.language)</dcterms:language>
            <summary>\(b.summary)</summary>
            <link rel="http://opds-spec.org/image/thumbnail" type="image/png" href="/covers/\(b.id).png"/>
            <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" length="\(240_000 + i * 31_000)" href="/books/\(b.id).epub"/>
            \(i == 0 ? #"<link rel="http://opds-spec.org/acquisition" type="application/x-mobipocket-ebook" href="/books/\#(b.id).mobi"/>"# : "")
            <link rel="related" type="application/atom+xml;profile=opds-catalog" href="/auteurs/\(b.id).xml" title="\(t("Du même auteur", "By the same author"))"/>
            </entry>
            """
        }.joined(separator: "\n")
        return Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom" xmlns:dcterms="http://purl.org/dc/terms/">
            <id>urn:exemple</id><title>\(t("Catalogue d'exemple", "Sample Catalogue"))</title><subtitle>\(t("Livres libres de droits, pour les captures.", "Public-domain books, for the screenshots."))</subtitle>
            <link rel="search" type="application/atom+xml" href="/recherche?q={searchTerms}"/>
            <entry><title>\(t("Les plus téléchargés", "Most Downloaded"))</title><id>urn:exemple:populaires</id>
            <content type="text">\(t("Les livres les plus demandés cette semaine.", "The most requested books this week."))</content>
            <link rel="subsection" type="application/atom+xml;profile=opds-catalog" href="/populaires.xml"/></entry>
            <entry><title>\(t("Par auteur", "By Author"))</title><id>urn:exemple:auteurs</id>
            <content type="text">\(t("Index alphabétique des auteurs.", "Alphabetical index of authors."))</content>
            <link rel="subsection" type="application/atom+xml;profile=opds-catalog" href="/auteurs.xml"/></entry>
            \(entries)
            </feed>
            """.utf8)
    }

    /// Client du catalogue d'exemple : flux, couvertures et EPUB fabriqués une fois, servis pour toute adresse.
    static var opdsClient: OPDSClient {
        let feed = opdsFeed
        var covers: [String: Data] = [:]
        for b in opdsBooks { covers[b.id] = coverPNG(title: b.title, color: b.color) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Foluna-seed-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var epubs: [String: Data] = [:]
        for b in opdsBooks {
            let meta = BookMetadata(title: b.title, authors: [b.author], language: b.language, summary: b.summary)
            if let url = try? makeEPUB(meta, cover: covers[b.id], in: folder) { epubs[b.id] = try? Data(contentsOf: url) }
        }
        try? FileManager.default.removeItem(at: folder)
        let images = covers
        let books = epubs
        return OPDSClient { url in
            let name = url.deletingPathExtension().lastPathComponent
            if url.path.hasPrefix("/covers/"), let png = images[name] { return (png, url) }
            if url.path.hasPrefix("/books/") {
                guard url.pathExtension == "epub", let epub = books[name] else { throw URLError(.fileDoesNotExist) }
                return (epub, url)
            }
            return (feed, url)
        }
    }
}

extension SeedData {
    /// Faux Zotero des captures : rien ne part vers le vrai Zotero de l'utilisateur.
    static let zoteroServer = ZoteroMemoryServer()
    static var zoteroClient: ZoteroLocalClient { ZoteroLocalClient(transport: zoteroServer.transport) }
}
