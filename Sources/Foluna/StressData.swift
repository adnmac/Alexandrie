import AppKit
import FolunaCore
import Foundation

/// Bibliothèque inventée pour les tests de résistance (`Foluna --stress`) : de vrais fichiers,
/// reproductibles (voir `StressCatalog`), gardés d'un passage à l'autre dans `/tmp/foluna-stress-data/<n>`.
///
/// Répartition : EPUB surtout (un sur trois avec couverture), 2 % de PDF, 5 % de copies en double,
/// 1 % de fichiers tronqués, un lot de titres identiques, des noms accentués et quelques emoji,
/// rangés sur trois niveaux (lettre / auteur / fichier).
enum StressData {

    /// Crée le jeu s'il n'est pas complet. Renvoie le dossier de livres et le nombre de fichiers.
    @MainActor static func ensure(count n: Int, at root: URL) throws -> (books: URL, files: Int) {
        let books = root.appendingPathComponent("Livres", isDirectory: true)
        let done = root.appendingPathComponent(".complet")
        if let text = try? String(contentsOf: done, encoding: .utf8), let files = Int(text) {
            return (books, files)
        }
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
        let covers = coverPalette()
        let failures = Counter()
        // Les PDF passent par CoreGraphics et AppKit : faits ensuite, sur un seul fil.
        DispatchQueue.concurrentPerform(iterations: n) { i in
            guard !isPDF(i) else { return }
            do { try write(i, covers: covers, in: books) } catch { failures.add() }
        }
        for i in 0..<n where isPDF(i) {
            do { try writePDF(i, in: books) } catch { failures.add() }
        }
        // Copies en double : le même fichier, ailleurs (même empreinte, mêmes informations).
        let copies = books.appendingPathComponent("Copies", isDirectory: true)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        var duplicates = 0
        for i in stride(from: 7, to: n, by: 20) where !isPDF(i) && !isBroken(i) {
            let source = file(i, in: books)
            if (try? FileManager.default.copyItem(at: source, to: copies.appendingPathComponent(source.lastPathComponent))) != nil {
                duplicates += 1
            }
        }
        let files = n - failures.value + duplicates
        try String(files).write(to: done, atomically: true, encoding: .utf8)
        return (books, files)
    }

    /// Ajoute `count` livres nouveaux (numéros à partir de `start`) dans un sous-dossier ; renvoie ce dossier.
    @MainActor static func addBooks(start: Int, count: Int, in books: URL) throws -> URL {
        let folder = books.appendingPathComponent("Ajouts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let covers = coverPalette()
        DispatchQueue.concurrentPerform(iterations: count) { k in
            try? write(start + k, covers: covers, in: folder, flat: true)
        }
        return folder
    }

    static func isPDF(_ i: Int) -> Bool { i % 50 == 13 }
    static func isBroken(_ i: Int) -> Bool { i % 100 == 41 }

    static func entry(_ i: Int) -> StressCatalog.Entry { StressCatalog.entry(i) }

    /// Un livre sur 1 000 porte le titre commun (« Mémoires ») : 100 sur 100 000, d'auteurs différents.
    static func title(_ i: Int) -> String {
        i % 1000 == 3 ? StressCatalog.sharedTitle : entry(i).title
    }

    static func file(_ i: Int, in books: URL, flat: Bool = false) -> URL {
        let e = entry(i)
        let author = e.authors[0]
        let emoji = i % 97 == 0 ? " 📚" : ""
        let name = "\(String(format: "%06d", i)) \(title(i))\(emoji)".safeFilename + (isPDF(i) ? ".pdf" : ".epub")
        if flat { return books.appendingPathComponent(name) }
        let letter = String(author.split(separator: " ").last?.first ?? "X").uppercased()
        return books.appendingPathComponent(letter, isDirectory: true)
            .appendingPathComponent(author.safeFilename, isDirectory: true)
            .appendingPathComponent(name)
    }

    private static func write(_ i: Int, covers: [Data], in books: URL, flat: Bool = false) throws {
        let e = entry(i)
        var meta = BookMetadata(title: title(i), authors: e.authors, language: e.language,
                                publisher: e.publisher, summary: e.summary, identifier: "urn:foluna:stress:\(i)")
        meta.series = e.series
        meta.seriesIndex = e.seriesIndex
        meta.subjects = e.subjects
        var epub = EPUBBuilder(metadata: meta)
        if i % 3 == 0 {
            epub.add("Images/cover.png", mediaType: "image/png", data: covers[i % covers.count])
            epub.coverPath = "Images/cover.png"
        }
        let text = (0..<(3 + i % 6)).map { p in "<p>Paragraphe \(p + 1) du livre \(i) : \(e.summary)</p>" }.joined(separator: "\n")
        let html = """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(e.language)">
            <head><title>Chapitre 1</title></head>
            <body><h1>Chapitre 1</h1>
            \(text)
            </body>
            </html>
            """
        epub.add("Text/chapter1.xhtml", mediaType: "application/xhtml+xml", data: Data(html.utf8), inSpine: true)
        epub.toc.append(TOCNode(title: "Chapitre 1", path: "Text/chapter1.xhtml"))
        let url = file(i, in: books, flat: flat)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try epub.write(to: url)
        if isBroken(i) {
            // Fichier tronqué : archive ZIP illisible, le livre doit quand même apparaître (titre du nom de fichier).
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(max(1, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 2) / 2))
            try handle.close()
        }
    }

    @MainActor private static func writePDF(_ i: Int, in books: URL) throws {
        let url = file(i, in: books)
        let folder = url.deletingLastPathComponent()
        let scratch = folder.appendingPathComponent(".pdf-\(i)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let made = try SeedData.makePDF(title: title(i), author: entry(i).authors[0], pages: 2 + i % 4, in: scratch)
        try FileManager.default.moveItem(at: made, to: url)
    }

    /// Quelques couvertures dessinées une fois (AppKit ne dessine pas sur plusieurs fils à la fois).
    /// Chaque livre a quand même sa couverture : elle est stockée sous l'empreinte du fichier.
    @MainActor private static func makeCovers() -> [Data] {
        let colors: [NSColor] = [.systemBlue, .systemRed, .systemGreen, .systemOrange, .systemPurple,
                                 .systemTeal, .systemBrown, .systemPink, .systemIndigo, .systemGray]
        return colors.enumerated().compactMap { k, c in SeedData.coverPNG(title: "Couverture \(k + 1)", color: c) }
    }

    @MainActor private static func coverPalette() -> [Data] { makeCovers() }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
}
