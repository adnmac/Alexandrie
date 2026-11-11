import Foundation

/// Copie d'un EPUB dont l'OPF porte les corrections de l'app (titre, auteurs, éditeur, date, langue, résumé,
/// ISBN, série) : ce qu'une Kobo ou une liseuse EPUB affiche. Le fichier source n'est jamais modifié ;
/// un champ vide garde la valeur du livre.
public enum EPUBMetadataWriter {
    static let dc = "http://purl.org/dc/elements/1.1/"

    public static func rewrite(_ source: URL, with edits: MetadataEdits, to output: URL) throws {
        let zip = try ZipReader(url: source)
        let container = try XMLLoader.document(zip.data("META-INF/container.xml"))
        guard let opfPath = container.rootElement()?.descendants(named: "rootfile").first?.attr("full-path") else {
            throw BookError.unreadable(String(localized: "container.xml sans rootfile"))
        }
        let opf = try XMLDocument(data: zip.data(opfPath), options: [.nodePreserveWhitespace])
        guard let package = opf.rootElement(), let metadata = package.firstChild(named: "metadata") else {
            throw BookError.unreadable(String(localized: "OPF sans métadonnées"))
        }
        apply(edits, to: metadata, package: package)

        let tmp = output.deletingLastPathComponent().appendingPathComponent(".\(output.lastPathComponent).tmp")
        let writer = try ZipWriter(url: tmp)
        // `mimetype` d'abord, sans compression (exigence EPUB).
        try writer.add("mimetype", data: (try? zip.data("mimetype")) ?? Data("application/epub+zip".utf8), compress: false)
        for path in zip.paths where path != "mimetype" && !path.hasSuffix("/") {
            let data = path == opfPath ? opf.xmlData(options: [.nodePreserveWhitespace]) : try zip.data(path)
            try writer.add(path, data: data)
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: tmp, to: output)
    }

    static func apply(_ e: MetadataEdits, to metadata: XMLElement, package: XMLElement) {
        let isEPUB3 = (package.attr("version") ?? "").hasPrefix("3")
        func text(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        }
        if let title = text(e.title) { replace("title", with: [title], in: metadata) }
        let authors = e.authors.compactMap(text)
        if !authors.isEmpty {
            // Les précisions EPUB 3 (rôle, tri) des anciens auteurs partent avec eux.
            let old = Set(metadata.children(named: "creator").compactMap { $0.attr("id") }.map { "#" + $0 })
            for meta in metadata.children(named: "meta") where old.contains(meta.attr("refines") ?? "") { meta.detach() }
            replace("creator", with: authors, in: metadata).enumerated().forEach { i, el in
                if isEPUB3 {
                    let id = "alx-creator-\(i + 1)"
                    el.setAttr("id", id)
                    metadata.addChild(meta(property: "role", refines: "#" + id, scheme: "marc:relators", "aut"))
                } else {
                    el.addAttribute(XMLNode.attribute(withName: "opf:role", uri: "http://www.idpf.org/2007/opf", stringValue: "aut") as! XMLNode)
                }
            }
        }
        if let publisher = text(e.publisher) { replace("publisher", with: [publisher], in: metadata) }
        if let date = text(e.publishedDate) { replace("date", with: [date], in: metadata) }
        if let language = text(e.language) { replace("language", with: [language], in: metadata) }
        if let summary = text(e.summary) { replace("description", with: [summary], in: metadata) }
        if let isbn = text(e.isbn).flatMap(ISBN.normalized) {
            // L'identifiant unique du paquet reste : seuls les autres ISBN sont remplacés.
            let unique = package.attr("unique-identifier")
            for el in metadata.children(named: "identifier") where el.attr("id") != unique
                && (el.textContent.lowercased().contains("isbn") || ISBN.normalized(el.textContent) != nil) {
                el.detach()
            }
            let el = XMLElement(name: "dc:identifier", uri: dc)
            el.stringValue = "urn:isbn:" + isbn
            metadata.addChild(el)
        }
        if let series = text(e.series) {
            for m in metadata.children(named: "meta") {
                let name = m.attr("name") ?? ""
                if name == "calibre:series" || name == "calibre:series_index" || m.attr("property") == "belongs-to-collection" {
                    if let id = m.attr("id") {
                        for r in metadata.children(named: "meta") where r.attr("refines") == "#" + id { r.detach() }
                    }
                    m.detach()
                }
            }
            let index = e.seriesIndex.map { $0 == $0.rounded() ? String(Int($0)) : String($0) }
            let calibre = XMLElement(name: "meta")
            calibre.setAttr("name", "calibre:series")
            calibre.setAttr("content", series)
            metadata.addChild(calibre)
            if let index {
                let i = XMLElement(name: "meta")
                i.setAttr("name", "calibre:series_index")
                i.setAttr("content", index)
                metadata.addChild(i)
            }
            if isEPUB3 {
                let collection = meta(property: "belongs-to-collection", series)
                collection.setAttr("id", "alx-series")
                metadata.addChild(collection)
                metadata.addChild(meta(property: "collection-type", refines: "#alx-series", "series"))
                if let index { metadata.addChild(meta(property: "group-position", refines: "#alx-series", index)) }
            }
        }
    }

    /// Remplace tous les `dc:<name>` par les valeurs données ; rend les éléments ajoutés.
    @discardableResult
    static func replace(_ name: String, with values: [String], in metadata: XMLElement) -> [XMLElement] {
        for el in metadata.children(named: name) { el.detach() }
        return values.map { value in
            let el = XMLElement(name: "dc:" + name, uri: dc)
            el.stringValue = value
            metadata.addChild(el)
            return el
        }
    }

    static func meta(property: String, refines: String? = nil, scheme: String? = nil, _ value: String) -> XMLElement {
        let m = XMLElement(name: "meta")
        m.setAttr("property", property)
        if let refines { m.setAttr("refines", refines) }
        if let scheme { m.setAttr("scheme", scheme) }
        m.stringValue = value
        return m
    }
}
