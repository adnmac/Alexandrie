import Foundation

/// Construit un EPUB 3 (avec toc.ncx pour les lecteurs EPUB 2).
/// Les chemins des ressources sont relatifs au dossier `OEBPS/`.
public struct EPUBBuilder {
    public struct Resource {
        public var path: String
        public var mediaType: String
        public var data: Data
        public var inSpine: Bool
        public var properties: [String] = []
    }

    public var metadata: BookMetadata
    public var resources: [Resource] = []
    public var toc: [TOCNode] = []
    public var coverPath: String?

    public init(metadata: BookMetadata) {
        self.metadata = metadata
    }

    public var spinePaths: [String] { resources.filter(\.inSpine).map(\.path) }

    public mutating func add(_ path: String, mediaType: String, data: Data, inSpine: Bool = false) {
        resources.append(Resource(path: path, mediaType: mediaType, data: data, inSpine: inSpine))
    }

    public func write(to url: URL) throws {
        // Identifiant figé une fois pour que l'OPF et le NCX concordent.
        var book = self
        if book.metadata.identifier == nil {
            book.metadata.identifier = "urn:uuid:\(UUID().uuidString.lowercased())"
        }
        try book.writeArchive(to: url)
    }

    private func writeArchive(to url: URL) throws {
        let zip = try ZipWriter(url: url)
        try zip.add("mimetype", data: Data("application/epub+zip".utf8), compress: false)
        try zip.add("META-INF/container.xml", data: Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """.utf8))
        for r in resources {
            try zip.add("OEBPS/" + r.path, data: r.data)
        }
        let toc = effectiveTOC
        try zip.add("OEBPS/nav.xhtml", data: Data(navDocument(toc).utf8))
        try zip.add("OEBPS/toc.ncx", data: Data(ncxDocument(toc).utf8))
        try zip.add("OEBPS/content.opf", data: Data(opfDocument().utf8))
    }

    /// La TOC ne peut pas être vide : à défaut, une entrée par document de la spine.
    private var effectiveTOC: [TOCNode] {
        if !toc.isEmpty { return toc }
        return spinePaths.enumerated().map { i, p in TOCNode(title: "Partie \(i + 1)", path: p) }
    }

    private var identifier: String {
        metadata.identifier ?? "urn:uuid:00000000-0000-0000-0000-000000000000"
    }

    private func opfDocument() -> String {
        var ids: [String: String] = [:]
        var manifest = ""
        for (i, r) in resources.enumerated() {
            let id = "item\(i + 1)"
            ids[r.path] = id
            var props = r.properties
            if r.path == coverPath, !props.contains("cover-image") { props.append("cover-image") }
            if r.mediaType == "application/xhtml+xml",
               let text = String(data: r.data, encoding: .utf8), text.contains("<svg") {
                props.append("svg")
            }
            let p = props.isEmpty ? "" : " properties=\"\(props.joined(separator: " "))\""
            manifest += "    <item id=\"\(id)\" href=\"\(r.path.xmlEscaped)\" media-type=\"\(r.mediaType)\"\(p)/>\n"
        }
        manifest += "    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n"
        manifest += "    <item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\n"
        let spine = spinePaths.compactMap { ids[$0] }.map { "    <itemref idref=\"\($0)\"/>" }
            .joined(separator: "\n")
        var meta = "    <dc:identifier id=\"bookid\">\(identifier.xmlEscaped)</dc:identifier>\n"
        meta += "    <dc:title>\(metadata.title.xmlEscaped)</dc:title>\n"
        for a in metadata.authors { meta += "    <dc:creator>\(a.xmlEscaped)</dc:creator>\n" }
        meta += "    <dc:language>\((metadata.language ?? "fr").xmlEscaped)</dc:language>\n"
        if let p = metadata.publisher { meta += "    <dc:publisher>\(p.xmlEscaped)</dc:publisher>\n" }
        if let d = metadata.publishedDate { meta += "    <dc:date>\(d.xmlEscaped)</dc:date>\n" }
        if let i = metadata.isbn { meta += "    <dc:identifier>urn:isbn:\(i.xmlEscaped)</dc:identifier>\n" }
        if let s = metadata.series {
            // EPUB 3 (collection) et forme Calibre, lue par la plupart des logiciels.
            meta += "    <meta property=\"belongs-to-collection\" id=\"series\">\(s.xmlEscaped)</meta>\n"
            meta += "    <meta refines=\"#series\" property=\"collection-type\">series</meta>\n"
            meta += "    <meta name=\"calibre:series\" content=\"\(s.xmlEscaped)\"/>\n"
            if let n = metadata.seriesIndex {
                meta += "    <meta refines=\"#series\" property=\"group-position\">\(SeriesNames.format(n))</meta>\n"
                meta += "    <meta name=\"calibre:series_index\" content=\"\(SeriesNames.format(n))\"/>\n"
            }
        }
        if let d = metadata.summary { meta += "    <dc:description>\(d.xmlEscaped)</dc:description>\n" }
        for s in metadata.subjects { meta += "    <dc:subject>\(s.xmlEscaped)</dc:subject>\n" }
        let modified = ISO8601DateFormatter().string(from: Date())
        meta += "    <meta property=\"dcterms:modified\">\(modified)</meta>\n"
        if let c = coverPath, let id = ids[c] { meta += "    <meta name=\"cover\" content=\"\(id)\"/>\n" }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            \(meta)  </metadata>
              <manifest>
            \(manifest)  </manifest>
              <spine toc="ncx">
            \(spine)
              </spine>
            </package>
            """
    }

    private static func href(_ node: TOCNode) -> String {
        node.path.xmlEscaped + (node.fragment.map { "#" + $0.xmlEscaped } ?? "")
    }

    private func navDocument(_ toc: [TOCNode]) -> String {
        func list(_ nodes: [TOCNode], indent: String) -> String {
            var s = "\(indent)<ol>\n"
            for n in nodes {
                s += "\(indent)  <li><a href=\"\(Self.href(n))\">\(n.title.xmlEscaped)</a>"
                if !n.children.isEmpty { s += "\n" + list(n.children, indent: indent + "    ") + indent + "  " }
                s += "</li>\n"
            }
            return s + "\(indent)</ol>\n"
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>\(metadata.title.xmlEscaped)</title></head>
            <body>
              <nav epub:type="toc" id="toc">
                <h1>Table des matières</h1>
            \(list(toc, indent: "    "))  </nav>
            </body>
            </html>
            """
    }

    private func ncxDocument(_ toc: [TOCNode]) -> String {
        var order = 0
        func points(_ nodes: [TOCNode], indent: String) -> String {
            nodes.map { n in
                order += 1
                return """
                \(indent)<navPoint id="np\(order)" playOrder="\(order)">
                \(indent)  <navLabel><text>\(n.title.xmlEscaped)</text></navLabel>
                \(indent)  <content src="\(Self.href(n))"/>
                \(points(n.children, indent: indent + "  "))\(indent)</navPoint>

                """
            }.joined()
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
              <head><meta name="dtb:uid" content="\(identifier.xmlEscaped)"/></head>
              <docTitle><text>\(metadata.title.xmlEscaped)</text></docTitle>
              <navMap>
            \(points(toc, indent: "    "))  </navMap>
            </ncx>
            """
    }
}
