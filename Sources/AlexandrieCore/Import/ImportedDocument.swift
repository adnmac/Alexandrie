import AppKit
import Foundation
import PDFKit

/// Livre lu par un importeur, avant d'être écrit en EPUB (ou en PDF pour des pages en images).
public struct ImportedDocument: Sendable {
    public struct Chapter: Sendable, Equatable {
        /// Titre dans la table des matières (nil : chapitre sans titre, absent de la table).
        public var title: String?
        /// Contenu du `<body>`, en XHTML valide ; les images sont appelées par `../Images/<nom>`.
        public var body: String
        /// Page en images : nom de l'image de la page (voir `images`).
        public var pageImage: String?

        public init(title: String?, body: String, pageImage: String? = nil) {
            self.title = title
            self.body = body
            self.pageImage = pageImage
        }
    }

    public struct Image: Sendable, Equatable {
        public var name: String
        public var mediaType: String
        public var data: Data

        public init(name: String, mediaType: String, data: Data) {
            self.name = name
            self.mediaType = mediaType
            self.data = data
        }
    }

    public var metadata: BookMetadata
    public var chapters: [Chapter]
    public var images: [Image] = []
    /// Nom de l'image de couverture (voir `images`).
    public var cover: String?

    public init(metadata: BookMetadata, chapters: [Chapter], images: [Image] = [], cover: String? = nil) {
        self.metadata = metadata
        self.chapters = chapters
        self.images = images
        self.cover = cover
    }

    /// Informations, avec les octets de la couverture.
    public var metadataWithCover: BookMetadata {
        var meta = metadata
        if meta.coverData == nil, let cover, let image = images.first(where: { $0.name == cover }) {
            meta.coverData = image.data
        }
        return meta
    }

    /// Texte de chaque chapitre, sans balises (recherche dans le contenu).
    public var plainTexts: [String] {
        chapters.map { BookText.plainText(Data(("<body>" + $0.body + "</body>").utf8)) }
    }

    // MARK: - EPUB

    public func writeEPUB(to url: URL, edits: MetadataEdits?) throws {
        guard !chapters.isEmpty else { throw BookError.unreadable(String(localized: "livre vide")) }
        var meta = metadata
        if let edits { meta.apply(edits) }
        meta.coverData = nil
        var epub = EPUBBuilder(metadata: meta)
        let isPages = chapters.contains { $0.pageImage != nil }
        epub.add("Styles/style.css", mediaType: "text/css", data: Data((isPages ? Self.pagesCSS : Self.textCSS).utf8))
        for image in images {
            epub.add("Images/" + image.name, mediaType: image.mediaType, data: image.data)
        }
        if let cover { epub.coverPath = "Images/" + cover }
        let language = Self.xhtml(meta.language ?? "fr")
        for (n, chapter) in chapters.enumerated() {
            let path = String(format: "Text/chapter%04d.xhtml", n + 1)
            let title = Self.xhtml(chapter.title ?? meta.title)
            let html = """
                <?xml version="1.0" encoding="utf-8"?>
                <!DOCTYPE html>
                <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(language)" lang="\(language)">
                <head><title>\(title)</title><link rel="stylesheet" type="text/css" href="../Styles/style.css"/></head>
                <body>
                \(chapter.body)
                </body>
                </html>
                """
            epub.add(path, mediaType: "application/xhtml+xml", data: Data(html.utf8), inSpine: true)
            if let t = chapter.title { epub.toc.append(TOCNode(title: t, path: path)) }
        }
        if epub.toc.isEmpty, let first = epub.spinePaths.first {
            epub.toc = [TOCNode(title: meta.title, path: first)]
        }
        try epub.write(to: url)
    }

    // MARK: - PDF (pages en images)

    public func writePDF(to url: URL, edits: MetadataEdits?) throws {
        let byName = Dictionary(images.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let document = PDFDocument()
        for chapter in chapters {
            guard let name = chapter.pageImage, let data = byName[name]?.data, let image = NSImage(data: data),
                  let page = PDFPage(image: image) else { continue }
            document.insert(page, at: document.pageCount)
        }
        guard document.pageCount > 0 else { throw BookError.unreadable(String(localized: "aucune page lisible")) }
        var meta = metadata
        if let edits { meta.apply(edits) }
        var attributes = document.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.titleAttribute] = meta.title
        if !meta.authors.isEmpty { attributes[PDFDocumentAttribute.authorAttribute] = meta.authors.joined(separator: ", ") }
        document.documentAttributes = attributes
        try? FileManager.default.removeItem(at: url)
        guard document.write(to: url) else { throw BookError.conversionFailed(String(localized: "PDF non écrit")) }
    }

    // MARK: - Aides

    /// Texte sûr pour XHTML : caractères interdits en XML retirés, `& < > "` échappés.
    public static func xhtml(_ s: String) -> String {
        var allowed = String.UnicodeScalarView()
        for u in s.unicodeScalars where u == "\t" || u == "\n" || u == "\r" || (0x20...0xD7FF).contains(u.value)
            || (0xE000...0xFFFD).contains(u.value) || u.value >= 0x10000 {
            allowed.append(u)
        }
        return String(allowed).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Paragraphes en XHTML.
    static func paragraphs(_ list: [String]) -> String {
        list.map { "<p>\(xhtml($0))</p>" }.joined(separator: "\n")
    }

    static let textCSS = """
        body { margin: 0 5%; }
        h1, h2, h3 { text-align: center; margin: 1.5em 0 1em; }
        p { margin: 0; text-indent: 1.5em; text-align: justify; }
        p.first, h1 + p, h2 + p, h3 + p { text-indent: 0; }
        .center { text-align: center; text-indent: 0; }
        .epigraph, blockquote { margin: 1em 10%; font-style: italic; }
        .note { font-size: 0.85em; }
        img { max-width: 100%; }
        div.image { text-align: center; margin: 1em 0; }
        """

    static let pagesCSS = """
        body { margin: 0; padding: 0; text-align: center; }
        img { max-width: 100%; max-height: 100vh; }
        """
}
