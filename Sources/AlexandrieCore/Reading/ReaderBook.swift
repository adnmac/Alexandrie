import Foundation

/// Livre prêt pour la fenêtre de lecture (S-066) : EPUB extrait dans les données de l'app, MOBI, AZW3, PRC
/// et formats des importeurs (FB2, TXT, CBZ) convertis en EPUB d'abord. Le fichier du dossier de livres n'est jamais modifié.
public struct ReaderBook: Sendable {
    /// Une entrée de la table des matières, rattachée à un chapitre (fichier du spine).
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var id: String { "\(chapter)#\(fragment ?? "")#\(title)" }
        public let title: String
        public let chapter: Int
        public let fragment: String?
        public let depth: Int

        public init(title: String, chapter: Int, fragment: String?, depth: Int) {
            self.title = title
            self.chapter = chapter
            self.fragment = fragment
            self.depth = depth
        }
    }

    /// Dossier extrait : les fichiers XHTML y trouvent leurs images et feuilles de style.
    public let root: URL
    /// Fichiers XHTML, dans l'ordre de lecture.
    public let chapters: [URL]
    /// Taille de chaque chapitre, pour le « % lu ».
    public let weights: [Int]
    public let toc: [Entry]

    /// Formats lus par la fenêtre de lecture sous forme d'EPUB (le PDF a sa propre vue).
    public static func canRead(_ book: Book) -> Bool {
        !book.isDRMProtected && book.format != .pdf
    }

    /// Prépare le livre ; une préparation déjà faite (même empreinte) est reprise telle quelle.
    public static func prepare(_ book: Book, directories: AppDirectories) throws -> ReaderBook {
        guard canRead(book) else {
            throw book.isDRMProtected ? BookError.drmProtected : BookError.unsupported("format \(book.format.label)")
        }
        let root = directories.reading.appendingPathComponent(book.fingerprint, isDirectory: true)
        let manifestURL = root.appendingPathComponent("lecture.json")
        if let data = try? Data(contentsOf: manifestURL), let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            return make(root: root, manifest: manifest)
        }
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var epubURL = book.url
        if book.format != .epub {
            epubURL = root.appendingPathComponent("livre.epub")
            // Copie de lecture faite une fois : une nouvelle version d'un importeur ne la refait pas, et les
            // surlignages gardent leur place (le dossier n'est supprimé que si le livre disparaît).
            if book.format.importer != nil {
                try Importers.writeEPUB(book.url, format: book.format, to: epubURL, edits: nil)
            } else {
                try MobiToEPUB.convert(input: book.url, output: epubURL)
            }
        }
        let epub = try EPUBReader(url: epubURL)
        try extract(epub, to: root)
        if book.format != .epub { try? fm.removeItem(at: epubURL) }
        let manifest = Manifest(epub)
        // Écrit en dernier : un dossier sans lui est une préparation interrompue, refaite.
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        return make(root: root, manifest: manifest)
    }

    /// Ce qui décrit le livre extrait : chapitres (chemins d'archive) et table des matières.
    struct Manifest: Codable {
        var chapters: [String]
        var toc: [Entry]

        init(_ epub: EPUBReader) {
            chapters = epub.spine.map(\.path)
            let index = Dictionary(chapters.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            var toc: [Entry] = []
            func walk(_ nodes: [TOCNode], depth: Int) {
                for node in nodes {
                    if let chapter = index[node.path] {
                        toc.append(Entry(title: node.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                         chapter: chapter, fragment: node.fragment, depth: depth))
                    }
                    walk(node.children, depth: depth + 1)
                }
            }
            walk(epub.tableOfContents(), depth: 0)
            self.toc = toc
        }
    }

    static func make(root: URL, manifest: Manifest) -> ReaderBook {
        let chapters = manifest.chapters.map { root.appendingPathComponent($0) }
        let weights = chapters.map { max(1, (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1) }
        return ReaderBook(root: root, chapters: chapters, weights: weights, toc: manifest.toc)
    }

    /// Écrit chaque ressource de l'EPUB à son chemin d'archive (les liens relatifs restent valables).
    static func extract(_ epub: EPUBReader, to root: URL) throws {
        let fm = FileManager.default
        for item in epub.items {
            guard let data = try? epub.data(item.path) else { continue }
            let target = root.appendingPathComponent(item.path)
            // Un chemin qui sortirait du dossier (« ../ ») est ignoré.
            guard target.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
        }
    }
}

// MARK: - Position de lecture (S-068)

/// Où la lecture s'est arrêtée : chapitre (ou page d'un PDF) et avancée dans ce chapitre.
public struct ReadingPosition: Codable, Equatable, Sendable {
    /// Index du chapitre (EPUB) ou de la page (PDF).
    public var chapter: Int
    /// Avancée dans le chapitre, de 0 à 1 (0 pour un PDF).
    public var fraction: Double
    /// Part du livre lue, de 0 à 1.
    public var percent: Double
    public var updatedAt: Date

    public init(chapter: Int, fraction: Double, percent: Double, updatedAt: Date = Date()) {
        self.chapter = chapter
        self.fraction = fraction
        self.percent = percent
        self.updatedAt = updatedAt
    }

    /// Part lue d'un livre découpé en chapitres de tailles `weights`.
    public static func percent(chapter: Int, fraction: Double, weights: [Int]) -> Double {
        let total = weights.reduce(0, +)
        guard total > 0, weights.indices.contains(chapter) else { return 0 }
        let before = weights[..<chapter].reduce(0, +)
        let value = (Double(before) + Double(weights[chapter]) * min(max(fraction, 0), 1)) / Double(total)
        return min(max(value, 0), 1)
    }

    /// Part lue d'un PDF ouvert à la page `page` (la dernière page compte pour un livre fini).
    public static func percent(page: Int, of count: Int) -> Double {
        count <= 1 ? (count == 1 ? 1 : 0) : Double(page) / Double(count - 1)
    }

    /// « 42 % lu », arrondi vers le bas, sauf un livre terminé.
    public var label: String {
        let value = Int((percent * 100).rounded(.down))
        let shown = max(value, percent > 0 ? 1 : 0)
        return percent >= 0.995 ? String(localized: "Terminé") : String(localized: "\(shown) % lu")
    }
}

/// Positions de lecture par livre (empreinte du fichier), dans `reading.json`.
public enum ReadingLog {
    public static func load(_ url: URL) -> [String: ReadingPosition] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: ReadingPosition].self, from: data)) ?? [:]
    }

    public static func save(_ positions: [String: ReadingPosition], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(positions).write(to: url, options: .atomic)
    }
}
