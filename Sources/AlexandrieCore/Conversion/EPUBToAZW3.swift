import Foundation

/// Conversion EPUB → AZW3 (KF8 pur), sur le modèle du writer KF8 de calibre.
///
/// Chaque document de la spine devient un squelette (`<html><head>…<body>` + `</body></html>`)
/// dans lequel sont insérés des fragments d'environ 8 Ko, découpés entre les enfants
/// directs de `<body>`. Les liens internes deviennent des `kindle:pos:fid:…:off:…`,
/// les images et polices des `kindle:embed:…`, les feuilles de style des flux `kindle:flow:…`.
public enum EPUBToAZW3 {
    public struct Result: Sendable {
        public let asin: String
        public let coverData: Data?
    }

    /// `edits` remplace les métadonnées de l'EPUB (corrections faites dans l'app).
    @discardableResult
    public static func convert(input: URL, output: URL, edits: MetadataEdits? = nil,
                               asin: String? = nil) throws -> Result {
        let reader = try EPUBReader(url: input)
        var meta = try reader.bookMetadata()
        guard !meta.isDRMProtected else { throw BookError.drmProtected }
        if let e = edits?.normalized, !e.title.isEmpty { meta.apply(e) }
        let asin = asin ?? Self.makeASIN()
        let builder = KF8Builder(reader: reader, metadata: meta, asin: asin)
        let data = try builder.build()
        try Data(data).write(to: output, options: .atomic)
        return Result(asin: asin, coverData: meta.coverData)
    }

    /// Identifiant de 10 caractères, stable par livre si l'appelant le mémorise.
    public static func makeASIN() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return "AX" + String((0..<8).map { _ in chars.randomElement()! })
    }
}

private final class KF8Builder {
    let reader: EPUBReader
    let meta: BookMetadata
    let asin: String

    static let recordSize = 4096
    static let chunkSize = 8192

    // Ressources (images, polices) : index 0-based → kindle:embed:(index+1).
    var resourceRecords: [[UInt8]] = []
    var resourceIndex: [String: (index: Int, mime: String)] = [:]
    // Flux : 0 = texte, puis CSS et SVG.
    var flows: [[UInt8]] = [[]]
    var flowIndex: [String: (index: Int, mime: String)] = [:]

    struct Chunk {
        let raw: [UInt8]
        let selector: String
        let insertPos: Int
        let fileNumber: Int
        let startInFile: Int
    }

    struct Skeleton {
        let fileNumber: Int
        let start: Int
        let length: Int
        let chunkCount: Int
    }

    struct Position {
        let chunk: Int
        let offset: Int
        var absolute: Int
    }

    var text: [UInt8] = []
    var chunks: [Chunk] = []
    var skeletons: [Skeleton] = []
    var links: [(path: String, fragment: String?)] = []
    var idPositions: [String: Position] = [:]
    var filePositions: [String: Position] = [:]
    var aidCounter = 0

    init(reader: EPUBReader, metadata: BookMetadata, asin: String) {
        self.reader = reader
        self.meta = metadata
        self.asin = asin
    }

    func build() throws -> [UInt8] {
        collectResources()
        collectStylesheets()
        let documents = reader.spine.filter { $0.mediaType.contains("html") }
        guard !documents.isEmpty else { throw BookError.conversionFailed("aucun document dans la spine") }
        for (n, item) in documents.enumerated() {
            try addDocument(item, fileNumber: n)
        }
        fillLinkPlaceholders()

        flows[0] = text
        var allText: [UInt8] = []
        var fdst: [(Int, Int)] = []
        for f in flows {
            fdst.append((allText.count, allText.count + f.count))
            allText += f
        }
        return assemble(textBytes: allText, fdst: fdst)
    }

    // MARK: - Ressources

    private static let fontTypes: Set<String> = [
        "font/ttf", "font/otf", "font/sfnt", "application/x-font-ttf", "application/x-font-truetype",
        "application/x-font-opentype", "application/vnd.ms-opentype", "application/font-sfnt",
        "application/x-font-otf",
    ]

    private func collectResources() {
        let obfuscated = obfuscatedPaths()
        for item in reader.items {
            guard let data = try? reader.data(item.path) else { continue }
            let mime = item.mediaType.lowercased()
            let ext = (item.path as NSString).pathExtension.lowercased()
            if ["image/jpeg", "image/png", "image/gif"].contains(mime) {
                addResource(item.path, [UInt8](data), mime: mime)
            } else if mime.hasPrefix("image/") && mime != "image/svg+xml" {
                if let jpeg = ImageTools.jpeg(data, maxPixelSize: 2400) {
                    addResource(item.path, [UInt8](jpeg), mime: "image/jpeg")
                }
            } else if mime == "image/svg+xml" {
                flows.append([UInt8](data))
                flowIndex[item.path] = (flows.count - 1, mime)
            } else if (Self.fontTypes.contains(mime) || ["ttf", "otf"].contains(ext)) && !obfuscated.contains(item.path) {
                var record = Array("FONT".utf8)
                record.appendBE32(data.count)
                record.appendBE32(0)
                record.appendBE32(24)
                record.appendBE32(0)
                record.appendBE32(0)
                addResource(item.path, record + [UInt8](data), mime: ext == "otf" ? "font/otf" : "font/ttf")
            }
        }
    }

    private func addResource(_ path: String, _ record: [UInt8], mime: String) {
        resourceIndex[path] = (resourceRecords.count, mime)
        resourceRecords.append(record)
    }

    /// Polices obfusquées (encryption.xml) : ignorées plutôt que d'embarquer des données illisibles.
    private func obfuscatedPaths() -> Set<String> {
        guard let data = try? reader.data("META-INF/encryption.xml"),
              let root = try? XMLLoader.document(data).rootElement() else { return [] }
        return Set(root.descendants(named: "CipherReference").compactMap { $0.attr("URI") }
            .map { ArchivePath.resolve($0, relativeTo: "").path })
    }

    private func collectStylesheets() {
        for item in reader.items where item.mediaType == "text/css" {
            guard let data = try? reader.data(item.path) else { continue }
            let css = rewriteCSS(String(decoding: data, as: UTF8.self), baseDir: ArchivePath.directory(of: item.path))
            flows.append(Array(css.utf8))
            flowIndex[item.path] = (flows.count - 1, "text/css")
        }
    }

    private static let urlPattern = try! NSRegularExpression(pattern: "url\\(\\s*(['\"]?)([^'\"\\)]+)\\1\\s*\\)")

    private func rewriteCSS(_ css: String, baseDir: String) -> String {
        let noImports = css.replacingOccurrences(of: "@import[^;]*;", with: "", options: .regularExpression)
        return Self.urlPattern.replace(in: noImports) { g in
            let ref = g[2]
            if ArchivePath.isExternal(ref) || ref.hasPrefix("data:") { return g[0] }
            let path = ArchivePath.resolve(ref, relativeTo: baseDir).path
            if let embed = embedURL(path) { return "url(\(embed))" }
            return g[0]
        }
    }

    private func embedURL(_ path: String) -> String? {
        if let r = resourceIndex[path] {
            return "kindle:embed:\(Base32.encode(r.index + 1, width: 4))?mime=\(r.mime)"
        }
        if let f = flowIndex[path] {
            return "kindle:flow:\(Base32.encode(f.index, width: 4))?mime=\(f.mime)"
        }
        return nil
    }

    // MARK: - Documents

    private func nextAid() -> String {
        defer { aidCounter += 1 }
        return Base32.encode(aidCounter)
    }

    private func addDocument(_ item: EPUBReader.Item, fileNumber: Int) throws {
        documentPath = item.path
        let doc = try XMLLoader.document(reader.data(item.path))
        guard let root = doc.rootElement() else { throw BookError.conversionFailed("document vide : \(item.path)") }
        let baseDir = ArchivePath.directory(of: item.path)
        rewrite(root, baseDir: baseDir)

        let head = root.firstChild(named: "head")
        var body = root.firstChild(named: "body")
        if body == nil {
            body = XMLElement(name: "body")
            root.addChild(body!)
        }
        let bodyAid = nextAid()

        // Balise ouvrante du squelette.
        var rootTag = "<html xmlns=\"http://www.w3.org/1999/xhtml\""
        for ns in root.namespaces ?? [] where !(ns.name ?? "").isEmpty {
            rootTag += " xmlns:\(ns.name!)=\"\((ns.stringValue ?? "").xmlEscaped)\""
        }
        for a in root.attributes ?? [] { rootTag += " " + a.xmlString }
        rootTag += ">"
        let headXML = head.map(serialize) ?? "<head><title>\(meta.title.xmlEscaped)</title></head>"
        var bodyTag = "<body"
        for a in body!.attributes ?? [] where a.name != "aid" { bodyTag += " " + a.xmlString }
        bodyTag += " aid=\"\(bodyAid)\">"
        let skeletonHead = Array("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n\(rootTag)\(headXML)\(bodyTag)".utf8)
        let skeletonTail = Array("</body></html>".utf8)

        // Fragments : enfants directs de <body>, regroupés par ~8 Ko, coupés après un élément.
        var groups: [(raw: [UInt8], lastAid: String?)] = []
        var current: [UInt8] = []
        var currentAid: String?
        for node in body!.children ?? [] {
            var raw: [UInt8]
            if let el = node as? XMLElement {
                let aid = nextAid()
                el.setAttr("aid", aid)
                raw = Array(serialize(el).utf8)
                currentAid = aid
            } else {
                raw = Array(node.xmlString.utf8)
            }
            current += raw
            if current.count >= Self.chunkSize, currentAid != nil {
                groups.append((current, currentAid))
                current = []
                currentAid = nil
            }
        }
        if !current.isEmpty || groups.isEmpty {
            if current.isEmpty { current = Array(" ".utf8) }
            if groups.isEmpty || currentAid != nil {
                groups.append((current, currentAid))
            } else {
                // Texte final sans élément : rattaché au fragment précédent.
                groups[groups.count - 1].raw += current
            }
        }

        let skelStart = text.count
        text += skeletonHead + skeletonTail
        var insert = skelStart + skeletonHead.count
        var inFile = 0
        let firstChunk = chunks.count
        var previousAid: String?
        for g in groups {
            let selector = previousAid.map { "S-//*[@aid='\($0)']" } ?? "P-//*[@aid='\(bodyAid)']"
            chunks.append(Chunk(raw: g.raw, selector: selector, insertPos: insert, fileNumber: fileNumber,
                                startInFile: inFile))
            indexIDs(g.raw, path: item.path, chunk: chunks.count - 1, insertPos: insert)
            text += g.raw
            insert += g.raw.count
            inFile += g.raw.count
            previousAid = g.lastAid
        }
        skeletons.append(Skeleton(fileNumber: fileNumber, start: skelStart,
                                  length: skeletonHead.count + skeletonTail.count, chunkCount: groups.count))
        let top = Position(chunk: firstChunk, offset: 0, absolute: skelStart + skeletonHead.count)
        filePositions[item.path] = top
        // Les ancres posées sur <body> ou dans <head> renvoient au début du fichier.
        if let id = body!.attr("id") { idPositions[item.path + "#" + id] = top }
    }

    private static let voidElements = "area|base|br|col|embed|hr|img|input|link|meta|param|source|track|wbr"
    private static let expandedVoid = try! NSRegularExpression(
        pattern: "<(\(voidElements))(\\s[^>]*)?></\\1>", options: .caseInsensitive)

    /// XHTML sans balises auto-fermantes, sauf pour les éléments vides par nature.
    private func serialize(_ node: XMLNode) -> String {
        let s = node.xmlString(options: [.nodeExpandEmptyElement])
        return Self.expandedVoid.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "<$1$2/>")
    }

    /// Réécrit récursivement les références (styles, images, liens) d'un document.
    private func rewrite(_ el: XMLElement, baseDir: String) {
        for case let child as XMLElement in el.children ?? [] {
            let name = child.localName ?? ""
            switch name {
            case "script":
                child.detach()
                continue
            case "link":
                if let href = child.attr("href"), !ArchivePath.isExternal(href) {
                    let path = ArchivePath.resolve(href, relativeTo: baseDir).path
                    if let f = flowIndex[path], f.mime == "text/css" {
                        child.setAttr("href", "kindle:flow:\(Base32.encode(f.index, width: 4))?mime=text/css")
                    } else {
                        child.detach()
                        continue
                    }
                }
            case "style":
                if let css = child.stringValue {
                    child.stringValue = rewriteCSS(css, baseDir: baseDir)
                }
            case "img", "image", "source", "object":
                for attrName in ["src", "href", "data"] {
                    guard let attr = child.attributes?.first(where: { $0.localName == attrName }),
                          let value = attr.stringValue, !ArchivePath.isExternal(value) else { continue }
                    let path = ArchivePath.resolve(value, relativeTo: baseDir).path
                    if let embed = embedURL(path) { attr.stringValue = embed }
                }
            case "a", "area":
                if let attr = child.attribute(forName: "href"), let href = attr.stringValue,
                   !ArchivePath.isExternal(href) {
                    let target = href.hasPrefix("#")
                        ? (path: "", fragment: String(href.dropFirst()))
                        : ArchivePath.resolve(href, relativeTo: baseDir)
                    links.append((target.path.isEmpty ? documentPath : target.path,
                                  target.fragment))
                    attr.stringValue = "kindle:pos:fid:\(Base32.encode(links.count - 1, width: 4)):off:0000000000"
                }
            default:
                break
            }
            if let style = child.attribute(forName: "style"), let css = style.stringValue, css.contains("url(") {
                style.stringValue = rewriteCSS(css, baseDir: baseDir)
            }
            rewrite(child, baseDir: baseDir)
        }
    }

    /// Chemin du document en cours (pour les liens `#ancre` intra-fichier).
    private var documentPath = ""

    private static let idAttr = try! NSRegularExpression(pattern: "\\s(?:id|name)\\s*=\\s*[\"']([^\"']*)[\"']")

    /// Mémorise la position de chaque `id` (début de la balise) dans un fragment.
    private func indexIDs(_ raw: [UInt8], path: String, chunk: Int, insertPos: Int) {
        var i = 0
        let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">")
        while let open = raw.find(lt, from: i) {
            let close = raw.find(gt, from: open) ?? (raw.count - 1)
            let tag = String(decoding: raw[open...close], as: UTF8.self)
            if tag.contains("id"), let g = Self.idAttr.firstGroups(in: tag) {
                let key = path + "#" + g[1]
                if idPositions[key] == nil {
                    idPositions[key] = Position(chunk: chunk, offset: open, absolute: insertPos + open)
                }
            }
            i = close + 1
        }
    }

    private static let placeholder = try! NSRegularExpression(pattern: "kindle:pos:fid:([0-9A-V]{4}):off:0000000000")

    /// Remplace les marqueurs de liens par les positions réelles (même longueur → offsets inchangés).
    private func fillLinkPlaceholders() {
        let s = String(decoding: text, as: UTF8.self)
        let filled = Self.placeholder.replace(in: s) { g in
            let link = links[Base32.decode(g[1])]
            let pos = position(path: link.path, fragment: link.fragment)
            return "kindle:pos:fid:\(Base32.encode(pos.chunk, width: 4)):off:\(Base32.encode(pos.offset, width: 10))"
        }
        text = Array(filled.utf8)
    }

    private func position(path: String, fragment: String?) -> Position {
        if let f = fragment, !f.isEmpty, let p = idPositions[path + "#" + f] { return p }
        return filePositions[path] ?? Position(chunk: 0, offset: 0, absolute: chunks.first?.insertPos ?? 0)
    }

    // MARK: - Index et assemblage

    private func chunkIndex() -> [[UInt8]] {
        var cncx = CNCXBuilder()
        var w = MobiIndexWriter(tags: [.init(number: 2, perEntry: 1, mask: 1), .init(number: 3, perEntry: 1, mask: 2),
                                       .init(number: 4, perEntry: 1, mask: 4), .init(number: 6, perEntry: 2, mask: 8)])
        for (seq, c) in chunks.enumerated() {
            w.entries.append((String(format: "%010d", c.insertPos),
                              [2: [cncx.offset(for: c.selector)], 3: [c.fileNumber], 4: [seq],
                               6: [c.startInFile, c.raw.count]]))
        }
        w.cncxRecords = cncx.finish()
        return w.records()
    }

    private func skeletonIndex() -> [[UInt8]] {
        var w = MobiIndexWriter(tags: [.init(number: 1, perEntry: 1, mask: 3), .init(number: 6, perEntry: 2, mask: 12)])
        for s in skeletons {
            w.entries.append((String(format: "SKEL%010d", s.fileNumber),
                              [1: [s.chunkCount, s.chunkCount], 6: [s.start, s.length, s.start, s.length]]))
        }
        return w.records()
    }

    private func ncxIndex(textLength: Int) -> [[UInt8]] {
        struct Flat {
            let label: String
            let depth: Int
            let parent: Int?
            var firstChild: Int?
            var lastChild: Int?
            let pos: Position
        }
        var toc = reader.tableOfContents()
        if toc.isEmpty {
            toc = reader.spine.filter { $0.mediaType.contains("html") }.enumerated()
                .map { TOCNode(title: "Partie \($0.offset + 1)", path: $0.element.path) }
        }
        // Parcours en largeur : les enfants d'un même parent sont contigus.
        var flat: [Flat] = []
        var queue: [(TOCNode, Int, Int?)] = toc.map { ($0, 0, nil) }
        var q = 0
        while q < queue.count {
            let (node, depth, parent) = queue[q]
            q += 1
            let idx = flat.count
            flat.append(Flat(label: node.title.isEmpty ? "—" : node.title, depth: depth, parent: parent,
                             pos: position(path: node.path, fragment: node.fragment)))
            if let p = parent {
                if flat[p].firstChild == nil { flat[p].firstChild = idx }
                flat[p].lastChild = idx
            }
            queue += node.children.map { ($0, depth + 1, idx) }
        }
        let sortedOffsets = Set(flat.map(\.pos.absolute) + [textLength]).sorted()
        var cncx = CNCXBuilder()
        var w = MobiIndexWriter(tags: [
            .init(number: 1, perEntry: 1, mask: 1), .init(number: 2, perEntry: 1, mask: 2),
            .init(number: 3, perEntry: 1, mask: 4), .init(number: 4, perEntry: 1, mask: 8),
            .init(number: 21, perEntry: 1, mask: 16), .init(number: 22, perEntry: 1, mask: 32),
            .init(number: 23, perEntry: 1, mask: 64), .init(number: 6, perEntry: 2, mask: 128),
        ])
        let width = max(2, String(max(0, flat.count - 1), radix: 16).count)
        for (i, e) in flat.enumerated() {
            let next = sortedOffsets.first { $0 > e.pos.absolute } ?? textLength
            var values: [Int: [Int]] = [
                1: [e.pos.absolute], 2: [max(1, next - e.pos.absolute)], 3: [cncx.offset(for: e.label)],
                4: [e.depth], 6: [e.pos.chunk, e.pos.offset],
            ]
            if let p = e.parent { values[21] = [p] }
            if let c = e.firstChild { values[22] = [c] }
            if let c = e.lastChild { values[23] = [c] }
            let key = String(i, radix: 16, uppercase: true)
            w.entries.append((String(repeating: "0", count: max(0, width - key.count)) + key, values))
        }
        w.cncxRecords = cncx.finish()
        return w.records()
    }

    /// Découpe le texte en enregistrements de 4 Ko compressés ; un caractère UTF-8 coupé
    /// est recopié en fin d'enregistrement (« multibyte overlap »).
    private func textRecords(_ bytes: [UInt8]) -> [[UInt8]] {
        var records: [[UInt8]] = []
        var pos = 0
        while pos < bytes.count {
            let end = min(pos + Self.recordSize, bytes.count)
            var overlap: [UInt8] = []
            if end < bytes.count {
                // Octets de continuation (10xxxxxx) au début de l'enregistrement suivant.
                var k = end
                while k < bytes.count && k - end < 3 && bytes[k] & 0xC0 == 0x80 { k += 1 }
                overlap = Array(bytes[end..<k])
            }
            var rec = PalmDoc.compress(Array(bytes[pos..<end]))
            rec += overlap
            rec.append(UInt8(overlap.count))
            records.append(rec)
            pos = end
        }
        return records
    }

    private func assemble(textBytes: [UInt8], fdst: [(Int, Int)]) -> [UInt8] {
        var records: [[UInt8]] = [[]]
        let text = textRecords(textBytes)
        records += text
        let textSize = text.reduce(0) { $0 + $1.count }
        if textSize % 4 != 0 { records.append([UInt8](repeating: 0, count: textSize % 4)) }
        let firstNonText = records.count

        let chunkStart = records.count
        records += chunkIndex()
        let skelStart = records.count
        records += skeletonIndex()
        let ncxStart = records.count
        records += ncxIndex(textLength: self.text.count)

        let firstResource = resourceRecords.isEmpty ? mobiNull : records.count
        records += resourceRecords

        let fdstRecord = records.count
        var fdstBytes = Array("FDST".utf8)
        fdstBytes.appendBE32(12)
        fdstBytes.appendBE32(fdst.count)
        for (s, e) in fdst { fdstBytes.appendBE32(s); fdstBytes.appendBE32(e) }
        records.append(fdstBytes)

        let flisRecord = records.count
        records.append([0x46, 0x4C, 0x49, 0x53, 0, 0, 0, 8, 0, 0x41, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF,
                        0, 1, 0, 3, 0, 0, 0, 3, 0, 0, 0, 1, 0xFF, 0xFF, 0xFF, 0xFF])
        let fcisRecord = records.count
        var fcis: [UInt8] = [0x46, 0x43, 0x49, 0x53, 0, 0, 0, 0x14, 0, 0, 0, 0x10, 0, 0, 0, 2, 0, 0, 0, 0]
        fcis.appendBE32(textBytes.count)
        fcis += [0, 0, 0, 0, 0, 0, 0, 0x28, 0, 0, 0, 0, 0, 0, 0, 0x28, 0, 0, 0, 8, 0, 1, 0, 1, 0, 0, 0, 0]
        records.append(fcis)
        records.append([0xE9, 0x8E, 0x0D, 0x0A])

        records[0] = recordZero(textLength: textBytes.count, textRecordCount: text.count,
                                firstNonText: firstNonText, firstResource: firstResource,
                                fdstRecord: fdstRecord, fdstCount: fdst.count, fcis: fcisRecord, flis: flisRecord,
                                ncx: ncxStart, chunk: chunkStart, skel: skelStart)
        return palmDatabase(records)
    }

    private func recordZero(textLength: Int, textRecordCount: Int, firstNonText: Int, firstResource: Int,
                            fdstRecord: Int, fdstCount: Int, fcis: Int, flis: Int,
                            ncx: Int, chunk: Int, skel: Int) -> [UInt8] {
        let exth = exthBlock()
        let title = Array(meta.title.utf8)
        var r: [UInt8] = []
        r.appendBE16(2)                       // compression PalmDoc
        r.appendBE16(0)
        r.appendBE32(textLength)
        r.appendBE16(textRecordCount)
        r.appendBE16(Self.recordSize)
        r.appendBE16(0)                       // pas de chiffrement
        r.appendBE16(0)
        r.append("MOBI")
        r.appendBE32(264)                     // longueur d'en-tête MOBI
        r.appendBE32(2)                       // type : livre
        r.appendBE32(65001)                   // UTF-8
        r.appendBE32(Int.random(in: 0..<0xFFFF_FFFF))
        r.appendBE32(8)                       // version de fichier
        for _ in 0..<10 { r.appendBE32(mobiNull) } // 40–80 : index orth/infl + index annexes
        r.appendBE32(firstNonText)            // 80
        r.appendBE32(280 + exth.count)        // 84 : offset du titre
        r.appendBE32(title.count)             // 88
        r.appendBE32(MobiLanguage.code(meta.language))
        r.appendBE32(0); r.appendBE32(0)      // 96 : langues de dictionnaire
        r.appendBE32(8)                       // 104 : version minimale
        r.appendBE32(firstResource)           // 108
        r.appendBE32(0); r.appendBE32(0); r.appendBE32(0); r.appendBE32(0) // 112 : HUFF
        r.appendBE32(0x50)                    // 128 : drapeaux EXTH
        r += [UInt8](repeating: 0, count: 32) // 132
        r.appendBE32(mobiNull)                // 164
        r.appendBE32(mobiNull)                // 168 : DRM
        r.appendBE32(0); r.appendBE32(0); r.appendBE32(0)
        r += [UInt8](repeating: 0, count: 8)  // 184
        r.appendBE32(fdstRecord)              // 192
        r.appendBE32(fdstCount)
        r.appendBE32(fcis); r.appendBE32(1)   // 200
        r.appendBE32(flis); r.appendBE32(1)   // 208
        r += [UInt8](repeating: 0, count: 8)  // 216
        r.appendBE32(mobiNull); r.appendBE32(0) // 224 : SRCS
        r += [UInt8](repeating: 0xFF, count: 8) // 232
        r.appendBE32(1)                       // 240 : octets multi-octets en fin d'enregistrement
        r.appendBE32(ncx)                     // 244
        r.appendBE32(chunk)                   // 248
        r.appendBE32(skel)                    // 252
        r.appendBE32(mobiNull)                // 256 : DATP
        r.appendBE32(mobiNull)                // 260 : guide
        r.appendBE32(mobiNull); r.appendBE32(0); r.appendBE32(mobiNull); r.appendBE32(0) // 264
        assert(r.count == 280)
        return r + exth + title + [UInt8](repeating: 0, count: 8192)
    }

    private func exthBlock() -> [UInt8] {
        var entries: [(Int, [UInt8])] = []
        func s(_ type: Int, _ value: String?) {
            if let v = value, !v.isEmpty { entries.append((type, Array(v.utf8))) }
        }
        func n(_ type: Int, _ value: Int) {
            var b: [UInt8] = []
            b.appendBE32(value)
            entries.append((type, b))
        }
        for a in meta.authors { s(100, a) }
        s(101, meta.publisher)
        s(103, meta.summary)
        s(104, meta.isbn)
        s(106, meta.publishedDate)
        for subject in meta.subjects { s(105, subject) }
        s(113, asin)
        s(501, "EBOK")
        s(503, meta.title)
        s(504, asin)
        s(524, meta.language ?? "fr")
        s(525, "horizontal-lr")
        n(125, 0)
        if let cover = coverResource() {
            n(201, cover)
            n(202, cover)
            n(203, 0)
        }
        var body: [UInt8] = []
        for (type, value) in entries {
            body.appendBE32(type)
            body.appendBE32(8 + value.count)
            body += value
        }
        var out = Array("EXTH".utf8)
        out.appendBE32(12 + body.count)
        out.appendBE32(entries.count)
        out += body
        let pad = 4 - (out.count % 4)
        return out + [UInt8](repeating: 0, count: pad)
    }

    private func coverResource() -> Int? {
        if let cover = reader.coverItem, let r = resourceIndex[cover.path] { return r.index }
        return nil
    }

    private func palmDatabase(_ records: [[UInt8]]) -> [UInt8] {
        var name = Array(meta.title.folding(options: .diacriticInsensitive, locale: nil)
            .unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil) || $0 == " " }
            .map { $0 == " " ? "_" : String($0) }.joined().utf8.prefix(31))
        if name.isEmpty { name = Array("book".utf8) }
        name += [UInt8](repeating: 0, count: 32 - name.count)
        let now = Int(Date().timeIntervalSince1970) & 0xFFFF_FFFF
        var out = name
        out.appendBE16(0); out.appendBE16(0)
        out.appendBE32(now); out.appendBE32(now)
        out.appendBE32(0); out.appendBE32(0); out.appendBE32(0); out.appendBE32(0)
        out.append("BOOKMOBI")
        out.appendBE32(2 * records.count - 1)
        out.appendBE32(0)
        out.appendBE16(records.count)
        var offset = out.count + 8 * records.count + 2
        for (i, r) in records.enumerated() {
            out.appendBE32(offset)
            out.append(0)
            out += [UInt8((2 * i >> 16) & 0xFF), UInt8((2 * i >> 8) & 0xFF), UInt8(2 * i & 0xFF)]
            offset += r.count
        }
        out += [0, 0]
        for r in records { out += r }
        return out
    }
}
