import Foundation

/// FictionBook 2 (`.fb2`, et `.fb2.zip` compressé) : XML avec informations (`title-info`), corps en sections,
/// notes (`<body name="notes">`) et images en base64 (`<binary>`). Une section de premier niveau = un chapitre.
public enum FB2Importer: BookImporter {
    public static let id = "fb2"
    public static var formats: [BookFormat] { [.fb2] }
    public static var output: ImportOutput { .reflowable }
    public static let version = 1

    public static func detect(_ header: Data) -> Bool {
        if header.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return true }   // .fb2.zip
        let text = String(decoding: header.prefix(Importers.headerLength), as: UTF8.self)
        return text.contains("<FictionBook") || text.hasPrefix("<?xml") || text.hasPrefix("\u{FEFF}<?xml")
    }

    public static func document(of url: URL) throws -> ImportedDocument {
        let root = try rootElement(xml(of: url))
        let name = url.lastPathComponent
        let base = name.lowercased().hasSuffix(".fb2.zip") ? String(name.dropLast(8)) : url.deletingPathExtension().lastPathComponent
        var converter = Converter(root: root, fallbackTitle: base)
        return converter.document()
    }

    // MARK: - Lecture

    /// XML du livre, sorti de son archive pour un `.fb2.zip`.
    static func xml(of url: URL) throws -> Data {
        if Importers.header(of: url).starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            let zip = try ZipReader(url: url)
            guard zip.files.count <= ImportLimits.maxArchiveEntries,
                  let entry = zip.files.first(where: { $0.path.lowercased().hasSuffix(".fb2") }) else {
                throw BookError.unreadable(String(localized: "aucun fichier FB2 dans l'archive"))
            }
            return try zip.data(entry.path, limit: ImportLimits.maxTextSize)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= ImportLimits.maxTextSize else { throw ImportLimits.tooLarge }
        return data
    }

    /// Élément racine. Un document qui déclare des entités est refusé : FictionBook n'en a pas besoin, et des
    /// entités imbriquées peuvent faire exploser la mémoire. Aucune ressource externe n'est chargée.
    static func rootElement(_ data: Data) throws -> XMLElement {
        let root = try safeXMLRoot(data)
        guard root.localName == "FictionBook" else {
            throw BookError.unreadable(String(localized: "ce n'est pas un livre FictionBook"))
        }
        return root
    }

    /// Racine d'un document XML lu sans entités déclarées ni ressources externes (FB2, ComicInfo.xml).
    static func safeXMLRoot(_ data: Data) throws -> XMLElement {
        // Recherché dans tout le fichier : une déclaration peut être précédée de commentaires aussi longs qu'on veut.
        if data.range(of: Data("<!ENTITY".utf8)) != nil {
            throw BookError.unreadable(String(localized: "XML non pris en charge (entités déclarées)"))
        }
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever, .nodePreserveWhitespace])
        } catch {
            throw BookError.unreadable(String(localized: "XML invalide"))
        }
        guard let root = document.rootElement() else { throw BookError.unreadable(String(localized: "XML invalide")) }
        return root
    }

    // MARK: - Conversion

    /// Parcours du document : chapitres XHTML, notes, images.
    struct Converter {
        let root: XMLElement
        let fallbackTitle: String
        private(set) var images: [ImportedDocument.Image] = []
        /// Identifiant FB2 d'une image (`#cover.jpg`) → nom dans l'EPUB.
        private var imageNames: [String: String] = [:]
        /// Identifiant d'élément → numéro du chapitre qui le contient (liens vers les notes et renvois).
        private var anchors: [String: Int] = [:]
        private var chapterIndex = 0

        init(root: XMLElement, fallbackTitle: String) {
            self.root = root
            self.fallbackTitle = fallbackTitle
        }

        mutating func document() -> ImportedDocument {
            loadImages()
            var meta = metadata()
            let bodies = root.children(named: "body")
            let main = bodies.first { $0.attr("name") == nil } ?? bodies.first
            var chapters: [ImportedDocument.Chapter] = []
            if let main {
                chapters = mainChapters(main, bookTitle: meta.title)
            }
            for notes in bodies where notes !== main {
                chapterIndex = chapters.count
                let title = notes.firstChild(named: "title").map(Self.plainText) ?? String(localized: "Notes")
                let body = "<h2>\(ImportedDocument.xhtml(title))</h2>\n" + notes.children(named: "section").map { note($0) }.joined(separator: "\n")
                chapters.append(.init(title: title, body: body))
            }
            chapters = chapters.map { c in
                var c = c
                c.body = resolveLinks(c.body)
                return c
            }
            if meta.title.isEmpty { meta.title = fallbackTitle }
            var cover: String?
            if let href = titleInfo?.firstChild(named: "coverpage")?.firstChild(named: "image")?.attr("href") {
                cover = imageNames[String(href.drop { $0 == "#" })]
            }
            return ImportedDocument(metadata: meta, chapters: chapters, images: images, cover: cover)
        }

        // MARK: Informations

        var titleInfo: XMLElement? { root.firstChild(named: "description")?.firstChild(named: "title-info") }

        func metadata() -> BookMetadata {
            let info = titleInfo
            let publish = root.firstChild(named: "description")?.firstChild(named: "publish-info")
            var meta = BookMetadata(title: info?.firstChild(named: "book-title")?.textContent ?? "")
            meta.authors = (info?.children(named: "author") ?? []).compactMap(Self.authorName)
            meta.language = info?.firstChild(named: "lang")?.textContent.lowercased().nilIfEmpty
            meta.summary = info?.firstChild(named: "annotation").map(Self.plainText)?.nilIfEmpty
            let date = info?.firstChild(named: "date")
            meta.publishedDate = (date?.attr("value") ?? date?.textContent)?.nilIfEmpty
                ?? publish?.firstChild(named: "year")?.textContent.nilIfEmpty
            meta.publisher = publish?.firstChild(named: "publisher")?.textContent.nilIfEmpty
            meta.isbn = publish?.firstChild(named: "isbn").flatMap { ISBN.normalized($0.textContent) }
            if let sequence = info?.firstChild(named: "sequence"), let name = sequence.attr("name")?.nilIfEmpty {
                meta.series = name
                meta.seriesIndex = sequence.attr("number").flatMap(Double.init)
            }
            return meta
        }

        static func authorName(_ el: XMLElement) -> String? {
            let parts = ["first-name", "middle-name", "last-name"].compactMap { el.firstChild(named: $0)?.textContent.nilIfEmpty }
            if !parts.isEmpty { return parts.joined(separator: " ") }
            return el.firstChild(named: "nickname")?.textContent.nilIfEmpty
        }

        // MARK: Images

        mutating func loadImages() {
            for (n, binary) in root.children(named: "binary").enumerated() {
                guard let id = binary.attr("id"),
                      let data = Data(base64Encoded: binary.stringValue ?? "", options: .ignoreUnknownCharacters),
                      ImportLimits.acceptsImage(data),
                      let mime = ImageTools.mimeType([UInt8](data.prefix(8))), mime != "image/bmp" else { continue }
                let name = "image\(n + 1).\(ImageTools.fileExtension(forMime: mime))"
                images.append(.init(name: name, mediaType: mime, data: data))
                imageNames[id] = name
            }
        }

        // MARK: Chapitres

        /// Chapitres du corps : titre du livre et épigraphes d'abord, puis une section de premier niveau par chapitre.
        mutating func mainChapters(_ body: XMLElement, bookTitle: String) -> [ImportedDocument.Chapter] {
            var chapters: [ImportedDocument.Chapter] = []
            var intro = ""
            for case let el as XMLElement in body.children ?? [] where el.localName != "section" {
                intro += block(el, depth: 1)
            }
            let sections = body.children(named: "section")
            if !intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chapterIndex = 0
                chapters.append(.init(title: sections.isEmpty ? bookTitle : nil, body: intro))
            }
            for section in sections {
                chapterIndex = chapters.count
                let title = section.firstChild(named: "title").map(Self.plainText)?.nilIfEmpty
                chapters.append(.init(title: title, body: self.section(section, depth: 2)))
            }
            return chapters
        }

        /// Section et ses sous-sections (titres de niveau 2 à 4).
        mutating func section(_ el: XMLElement, depth: Int) -> String {
            var out = anchor(el)
            for case let child as XMLElement in el.children ?? [] {
                if child.localName == "section" {
                    out += section(child, depth: min(depth + 1, 4))
                } else {
                    out += block(child, depth: depth)
                }
            }
            return out
        }

        /// Élément de bloc : paragraphe, titre, poème, citation, image…
        mutating func block(_ el: XMLElement, depth: Int) -> String {
            let id = anchorID(el)
            switch el.localName {
            case "title":
                let lines = el.children(named: "p").map { inline($0) }.filter { !$0.isEmpty }
                guard !lines.isEmpty else { return "" }
                return "<h\(depth)\(id)>\(lines.joined(separator: "<br/>"))</h\(depth)>\n"
            case "p": return "<p\(id)>\(inline(el))</p>\n"
            case "subtitle": return "<h\(min(depth + 1, 5))\(id)>\(inline(el))</h\(min(depth + 1, 5))>\n"
            case "empty-line": return "<p class=\"center\">&#160;</p>\n"
            case "text-author": return "<p class=\"center\"\(id)><em>\(inline(el))</em></p>\n"
            case "image": return image(el).map { "<div class=\"image\"\(id)>\($0)</div>\n" } ?? ""
            case "epigraph": return "<div class=\"epigraph\"\(id)>\n\(blocks(el, depth: depth))</div>\n"
            case "cite", "annotation": return "<blockquote\(id)>\n\(blocks(el, depth: depth))</blockquote>\n"
            case "poem", "stanza": return "<div class=\"poem\"\(id)>\n\(blocks(el, depth: depth))</div>\n"
            case "v": return "<p class=\"verse\"\(id)>\(inline(el))</p>\n"
            case "table":
                let rows = el.children(named: "tr").map { tr in
                    "<tr>" + (tr.children ?? []).compactMap { $0 as? XMLElement }.map { cell in
                        let tag = cell.localName == "th" ? "th" : "td"
                        return "<\(tag)>\(inline(cell))</\(tag)>"
                    }.joined() + "</tr>"
                }
                return "<table\(id)>\(rows.joined())</table>\n"
            case "section": return section(el, depth: min(depth + 1, 4))
            default: return ""
            }
        }

        mutating func blocks(_ el: XMLElement, depth: Int) -> String {
            (el.children ?? []).compactMap { $0 as? XMLElement }.map { block($0, depth: min(depth + 1, 5)) }.joined()
        }

        /// Texte et mise en forme d'un paragraphe.
        func inline(_ el: XMLElement) -> String {
            var out = ""
            for node in el.children ?? [] {
                guard let child = node as? XMLElement else {
                    if node.kind == .text { out += ImportedDocument.xhtml(node.stringValue ?? "") }
                    continue
                }
                let inner = inline(child)
                switch child.localName {
                case "strong": out += "<strong>\(inner)</strong>"
                case "emphasis": out += "<em>\(inner)</em>"
                case "strikethrough": out += "<del>\(inner)</del>"
                case "sub": out += "<sub>\(inner)</sub>"
                case "sup": out += "<sup>\(inner)</sup>"
                case "code": out += "<code>\(inner)</code>"
                case "image": out += image(child) ?? ""
                case "a":
                    let href = child.attr("href") ?? ""
                    let isNote = child.attr("type") == "note"
                    let target = href.hasPrefix("#") ? "{{lien:\(href.dropFirst())}}" : ImportedDocument.xhtml(href)
                    // Lien externe : seulement http(s), jamais javascript: ni fichier local.
                    if href.hasPrefix("#") || href.lowercased().hasPrefix("http://") || href.lowercased().hasPrefix("https://") {
                        out += isNote ? "<sup><a href=\"\(target)\">\(inner)</a></sup>" : "<a href=\"\(target)\">\(inner)</a>"
                    } else {
                        out += inner
                    }
                default: out += inner
                }
            }
            return out
        }

        func image(_ el: XMLElement) -> String? {
            guard let href = el.attr("href"), let name = imageNames[String(href.drop { $0 == "#" })] else { return nil }
            let alt = ImportedDocument.xhtml(el.attr("alt") ?? "")
            return "<img src=\"../Images/\(name)\" alt=\"\(alt)\"/>"
        }

        /// Note : son numéro (titre) puis son texte, ancrée à son identifiant.
        mutating func note(_ el: XMLElement) -> String {
            var out = "<div class=\"note\"\(anchorID(el))>\n"
            if let title = el.firstChild(named: "title").map(Self.plainText)?.nilIfEmpty {
                out += "<p class=\"first\"><strong>\(ImportedDocument.xhtml(title))</strong></p>\n"
            }
            for case let child as XMLElement in el.children ?? [] where child.localName != "title" {
                out += block(child, depth: 4)
            }
            return out + "</div>\n"
        }

        /// ` id="…"` pour un élément qui en a un (cible de lien), retenu avec son chapitre.
        mutating func anchorID(_ el: XMLElement) -> String {
            guard let id = el.attr("id"), let safe = Self.safeID(id) else { return "" }
            anchors[safe] = anchors[safe] ?? chapterIndex
            return " id=\"\(safe)\""
        }

        mutating func anchor(_ el: XMLElement) -> String {
            let id = anchorID(el)
            return id.isEmpty ? "" : "<div\(id)></div>\n"
        }

        static func safeID(_ id: String) -> String? {
            let s = String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) })
            guard let first = s.first else { return nil }
            return first.isLetter ? s : "n" + s
        }

        /// `{{lien:n1}}` → `chapter0012.xhtml#n1`, une fois connus les chapitres de chaque identifiant.
        func resolveLinks(_ body: String) -> String {
            guard body.contains("{{lien:") else { return body }
            var out = "", rest = Substring(body)
            while let start = rest.range(of: "{{lien:"), let end = rest[start.upperBound...].range(of: "}}") {
                out += rest[..<start.lowerBound]
                let id = Self.safeID(String(rest[start.upperBound..<end.lowerBound])) ?? ""
                if let chapter = anchors[id] {
                    out += String(format: "chapter%04d.xhtml#", chapter + 1) + id
                } else {
                    out += "#"
                }
                rest = rest[end.upperBound...]
            }
            return out + rest
        }

        static func plainText(_ el: XMLElement) -> String {
            (el.stringValue ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
    }
}

extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
