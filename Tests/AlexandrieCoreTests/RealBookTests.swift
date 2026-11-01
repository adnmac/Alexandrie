import Foundation
import Testing
@testable import AlexandrieCore

/// Tests sur de vrais livres (ex. Project Gutenberg), activés si `ALEXANDRIE_FIXTURES`
/// pointe vers un dossier contenant des .epub/.azw3/.mobi (ou les fichiers *.kf8.images, etc.).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ALEXANDRIE_FIXTURES"] != nil))
struct RealBookTests {
    static var dir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["ALEXANDRIE_FIXTURES"] ?? "/")
    }

    static func files(_ suffixes: [String]) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return all.filter { url in suffixes.contains { url.lastPathComponent.hasSuffix($0) } }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static var outDir: URL {
        let d = dir.appendingPathComponent("out")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func kindleFilesToEPUB() throws {
        let inputs = Self.files([".azw3", ".mobi", ".kf8.images", ".kindle.images"])
        #expect(!inputs.isEmpty)
        for url in inputs {
            let book = try MobiBook(url: url)
            let meta = book.metadata()
            print("📘 \(url.lastPathComponent): « \(meta.title) » — \(meta.authors) KF8=\(book.hasKF8) cover=\(meta.coverData?.count ?? 0)")
            #expect(!meta.title.isEmpty)
            let epub = try MobiToEPUB.build(book)
            print("   spine=\(epub.spinePaths.count) toc=\(epub.toc.reduce(0) { $0 + $1.totalCount }) ressources=\(epub.resources.count)")
            #expect(!epub.spinePaths.isEmpty)
            let out = Self.outDir.appendingPathComponent(url.lastPathComponent + ".epub")
            try epub.write(to: out)
            // Chaque document produit doit être du XML bien formé.
            let reader = try EPUBReader(url: out)
            for item in reader.spine {
                let data = try reader.data(item.path)
                #expect((try? XMLDocument(data: data, options: [])) != nil, "XHTML invalide : \(item.path)")
            }
        }
    }

    @Test func rewriteMetadata() throws {
        let edits = MetadataEdits(title: "Titre corrigé é", authors: ["Auteur Un"], publishedDate: "1759")
        for url in Self.files([".azw3", ".mobi", ".kf8.images", ".kindle.images"]) {
            let before = try MobiBook(url: url)
            let out = Self.outDir.appendingPathComponent(url.lastPathComponent + ".edited")
            try MobiMetadataWriter.rewrite(url, with: edits, to: out)
            let after = try MobiBook(url: out)
            #expect(after.metadata().title == "Titre corrigé é")
            #expect(after.metadata().publishedDate == "1759")
            #expect(after.metadata().coverData == before.metadata().coverData)
            for (a, b) in zip([after.kf7] + [after.kf8].compactMap { $0 }, [before.kf7] + [before.kf8].compactMap { $0 }) {
                #expect(try after.text(a) == before.text(b), "texte modifié : \(url.lastPathComponent)")
            }
            #expect(try MobiToEPUB.build(after).spinePaths.count == MobiToEPUB.build(before).spinePaths.count)
        }
    }

    @Test func epubToAZW3() throws {
        for url in Self.files([".epub", ".epub3.images"]) {
            let azw3 = Self.outDir.appendingPathComponent(url.lastPathComponent + ".azw3")
            let start = Date()
            try EPUBToAZW3.convert(input: url, output: azw3)
            let book = try MobiBook(url: azw3)
            let back = try MobiToEPUB.build(book)
            let source = try EPUBReader(url: url)
            print("📗 \(url.lastPathComponent) → AZW3 \(try Data(contentsOf: azw3).count / 1024) Ko en \(String(format: "%.2f", Date().timeIntervalSince(start))) s ; spine \(source.spine.count) → \(back.spinePaths.count), toc \(back.toc.reduce(0) { $0 + $1.totalCount })")
            #expect(back.spinePaths.count == source.spine.filter { $0.mediaType.contains("html") }.count)
            try back.write(to: Self.outDir.appendingPathComponent(url.lastPathComponent + ".roundtrip.epub"))
        }
    }
}
