import Foundation

/// Entrée de table des matières, indépendante du format.
public struct TOCNode: Sendable, Equatable {
    public var title: String
    /// Chemin dans l'archive (ou dans le livre généré) + fragment éventuel.
    public var path: String
    public var fragment: String?
    public var children: [TOCNode] = []

    public init(title: String, path: String, fragment: String? = nil, children: [TOCNode] = []) {
        self.title = title
        self.path = path
        self.fragment = fragment
        self.children = children
    }

    public var totalCount: Int { 1 + children.reduce(0) { $0 + $1.totalCount } }
}

/// Lecteur EPUB 2/3 : container.xml → OPF → manifeste, spine, métadonnées, TOC.
public final class EPUBReader {
    public struct Item: Sendable {
        public let id: String
        /// Chemin complet dans l'archive.
        public let path: String
        public let mediaType: String
        public let properties: Set<String>
    }

    private let zip: ZipReader
    public let opfPath: String
    public private(set) var items: [Item] = []
    public private(set) var spine: [Item] = []
    private var itemsByID: [String: Item] = [:]
    private var metadataElement: XMLElement?
    private var coverMetaID: String?
    private var ncxID: String?

    public init(url: URL) throws {
        zip = try ZipReader(url: url)
        let container = try XMLLoader.document(zip.data("META-INF/container.xml"))
        guard let rootfile = container.rootElement()?.descendants(named: "rootfile").first,
              let path = rootfile.attr("full-path") else {
            throw BookError.unreadable("container.xml sans rootfile")
        }
        opfPath = path
        try parseOPF()
    }

    private func parseOPF() throws {
        guard let package = try XMLLoader.document(zip.data(opfPath)).rootElement() else {
            throw BookError.unreadable("OPF vide")
        }
        let baseDir = ArchivePath.directory(of: opfPath)
        metadataElement = package.firstChild(named: "metadata")
        for item in package.firstChild(named: "manifest")?.children(named: "item") ?? [] {
            guard let id = item.attr("id"), let href = item.attr("href") else { continue }
            let props = Set((item.attr("properties") ?? "").split(separator: " ").map(String.init))
            let entry = Item(id: id, path: ArchivePath.resolve(href, relativeTo: baseDir).path,
                             mediaType: item.attr("media-type") ?? "", properties: props)
            items.append(entry)
            itemsByID[id] = entry
        }
        let spineEl = package.firstChild(named: "spine")
        ncxID = spineEl?.attr("toc")
        spine = (spineEl?.children(named: "itemref") ?? []).compactMap { ref in
            ref.attr("idref").flatMap { itemsByID[$0] }
        }
        coverMetaID = metadataElement?.children(named: "meta")
            .first { $0.attr("name") == "cover" }?.attr("content")
    }

    public func data(_ path: String) throws -> Data {
        try zip.data(path)
    }

    public func item(atPath path: String) -> Item? {
        items.first { $0.path == path }
    }

    // MARK: - Métadonnées

    private func dc(_ name: String) -> [XMLElement] {
        metadataElement?.children(named: name) ?? []
    }

    public var coverItem: Item? {
        if let item = items.first(where: { $0.properties.contains("cover-image") }) { return item }
        if let id = coverMetaID, let item = itemsByID[id], item.mediaType.hasPrefix("image/") { return item }
        // Certains EPUB référencent par href plutôt que par id.
        if let id = coverMetaID, let item = items.first(where: { $0.path.hasSuffix(id) }) { return item }
        return items.first {
            $0.mediaType.hasPrefix("image/") && $0.path.lowercased().contains("cover")
        }
    }

    public func bookMetadata() throws -> BookMetadata {
        var meta = BookMetadata(title: dc("title").first?.textContent ?? "")
        meta.authors = dc("creator").filter {
            let role = $0.attr("role")
            return role == nil || role == "aut"
        }.map(\.textContent).filter { !$0.isEmpty }
        meta.language = dc("language").first?.textContent
        meta.publisher = dc("publisher").first?.textContent
        meta.summary = dc("description").first?.textContent
        meta.identifier = dc("identifier").first?.textContent
        meta.isbn = ISBN.first(in: dc("identifier").map(\.textContent))
        // EPUB 2 peut porter plusieurs dates : on privilégie l'événement « publication ».
        let dates = dc("date")
        meta.publishedDate = (dates.first { $0.attr("event") == "publication" } ?? dates.first)?.textContent
        meta.subjects = dc("subject").map(\.textContent).filter { !$0.isEmpty }
        let metas = metadataElement?.children(named: "meta") ?? []
        if let series = metas.first(where: { $0.attr("name") == "calibre:series" })?.attr("content") {
            meta.series = series
            meta.seriesIndex = metas.first { $0.attr("name") == "calibre:series_index" }?
                .attr("content").flatMap(Double.init)
        } else if let coll = metas.first(where: { $0.attr("property") == "belongs-to-collection" }) {
            meta.series = coll.textContent
            // EPUB 3 : la position est un <meta refines="#id" property="group-position">.
            if let id = coll.attr("id") {
                let position = metas.first { m in
                    m.attr("refines") == "#\(id)" && m.attr("property") == "group-position"
                }
                let text: String = position?.textContent ?? ""
                meta.seriesIndex = Double(text.replacingOccurrences(of: ",", with: "."))
            }
        }
        if let cover = coverItem {
            meta.coverData = try? zip.data(cover.path)
        }
        meta.isDRMProtected = zip.contains("META-INF/encryption.xml") && hasEncryptedContent()
        return meta
    }

    /// `encryption.xml` sert aussi à l'obfuscation des polices, qui n'est pas un DRM.
    private func hasEncryptedContent() -> Bool {
        guard let data = try? zip.data("META-INF/encryption.xml") else { return false }
        let text = String(decoding: data, as: UTF8.self)
        let fontAlgorithms = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]
        let algorithms = text.components(separatedBy: "Algorithm=\"").dropFirst()
            .compactMap { $0.split(separator: "\"").first.map(String.init) }
        return algorithms.contains { !fontAlgorithms.contains($0) }
    }

    // MARK: - Table des matières

    /// TOC depuis le document de navigation EPUB 3, sinon depuis le NCX.
    public func tableOfContents() -> [TOCNode] {
        if let nav = items.first(where: { $0.properties.contains("nav") }),
           let toc = try? parseNav(nav.path), !toc.isEmpty {
            return toc
        }
        let ncx = ncxID.flatMap { itemsByID[$0] }
            ?? items.first { $0.mediaType == "application/x-dtbncx+xml" }
        if let ncx, let toc = try? parseNCX(ncx.path) { return toc }
        return []
    }

    private func parseNav(_ path: String) throws -> [TOCNode] {
        guard let root = try XMLLoader.document(zip.data(path)).rootElement() else { return [] }
        let navs = root.descendants(named: "nav")
        let tocNav = navs.first { ($0.attr("type") ?? "").contains("toc") } ?? navs.first
        guard let ol = tocNav?.descendants(named: "ol").first else { return [] }
        let dir = ArchivePath.directory(of: path)
        func walk(_ list: XMLElement) -> [TOCNode] {
            list.children(named: "li").compactMap { li in
                let link = li.firstChild(named: "a") ?? li.firstChild(named: "span")
                let title = link?.textContent ?? ""
                let children = li.firstChild(named: "ol").map(walk) ?? []
                guard let href = link?.attr("href") else {
                    return children.isEmpty ? nil : TOCNode(title: title, path: children[0].path,
                                                            fragment: children[0].fragment, children: children)
                }
                let (p, frag) = ArchivePath.resolve(href, relativeTo: dir)
                return TOCNode(title: title, path: p, fragment: frag, children: children)
            }
        }
        return walk(ol)
    }

    private func parseNCX(_ path: String) throws -> [TOCNode] {
        guard let root = try XMLLoader.document(zip.data(path)).rootElement(),
              let navMap = root.firstChild(named: "navMap") else { return [] }
        let dir = ArchivePath.directory(of: path)
        func walk(_ el: XMLElement) -> [TOCNode] {
            el.children(named: "navPoint").compactMap { point in
                let title = point.firstChild(named: "navLabel")?.firstChild(named: "text")?.textContent ?? ""
                guard let src = point.firstChild(named: "content")?.attr("src") else { return nil }
                let (p, frag) = ArchivePath.resolve(src, relativeTo: dir)
                return TOCNode(title: title, path: p, fragment: frag, children: walk(point))
            }
        }
        return walk(navMap)
    }
}
