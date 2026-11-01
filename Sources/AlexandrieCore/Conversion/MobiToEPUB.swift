import Compression
import Foundation

/// Conversion MOBI (KF7) / AZW3 (KF8) → EPUB, inspirée de KindleUnpack.
public enum MobiToEPUB {
    /// `edits` : informations corrigées dans l'app, écrites dans l'EPUB produit.
    public static func convert(input: URL, output: URL, edits: MetadataEdits? = nil) throws {
        var epub = try build(MobiBook(url: input))
        if let e = edits?.normalized, !e.title.isEmpty { epub.metadata.apply(e) }
        try epub.write(to: output)
    }

    static func build(_ book: MobiBook) throws -> EPUBBuilder {
        guard !book.isDRMProtected else { throw BookError.drmProtected }
        var meta = book.metadata()
        meta.coverData = nil
        var epub = EPUBBuilder(metadata: meta)

        let resources = extractResources(book)
        for (_, r) in resources.sorted(by: { $0.key < $1.key }) {
            epub.add(r.path, mediaType: r.mediaType, data: r.data)
        }
        if let cover = book.coverResourceIndex, let r = resources[cover] {
            epub.coverPath = r.path
        }
        let paths = resources.mapValues(\.path)
        if let kf8 = book.kf8 {
            try KF8Unpacker(book: book, header: kf8, resourcePaths: paths).build(into: &epub)
        } else {
            try KF7Unpacker(book: book, resourcePaths: paths).build(into: &epub)
        }
        return epub
    }

    struct Resource {
        let path: String
        let mediaType: String
        let data: Data
    }

    /// Images et polices, indexées relativement au premier enregistrement de ressource.
    static func extractResources(_ book: MobiBook) -> [Int: Resource] {
        guard let first = book.firstResource else { return [:] }
        var out: [Int: Resource] = [:]
        var i = first
        while i < book.records.count {
            let r = book.records[i]
            if r.hasPrefix("BOUNDARY") || r == [0xE9, 0x8E, 0x0D, 0x0A] { break }
            let rel = i - first
            let name = String(format: "%05d", rel + 1)
            if let mime = ImageTools.mimeType(r) {
                let ext = ImageTools.fileExtension(forMime: mime)
                out[rel] = Resource(path: "Images/image\(name).\(ext)", mediaType: mime, data: Data(r))
            } else if r.hasPrefix("FONT"), let font = decodeFont(r) {
                let otf = font.prefix(4) == Data("OTTO".utf8)
                out[rel] = Resource(path: "Fonts/font\(name).\(otf ? "otf" : "ttf")",
                                    mediaType: otf ? "font/otf" : "font/ttf", data: font)
            }
            i += 1
        }
        return out
    }

    /// Enregistrement FONT : obfuscation XOR éventuelle puis compression zlib éventuelle.
    static func decodeFont(_ r: [UInt8]) -> Data? {
        let size = r.u32(4), flags = r.u32(8), dataStart = r.u32(12)
        let xorLength = r.u32(16), xorStart = r.u32(20)
        guard dataStart < r.count else { return nil }
        var font = Array(r[dataStart...])
        if flags & 2 != 0, xorLength > 0 {
            let key = r.slice(xorStart, xorLength)
            for k in 0..<min(1040, font.count) { font[k] ^= key[k % key.count] }
        }
        if flags & 1 != 0 {
            guard font.count > 2, size > 0 else { return nil }
            var out = [UInt8](repeating: 0, count: size)
            let written = font.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    compression_decode_buffer(dst.baseAddress!, size, src.baseAddress! + 2, src.count - 2,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            guard written > 0 else { return nil }
            return Data(out.prefix(written))
        }
        return Data(font)
    }

    /// Construit l'arbre de TOC à partir des entrées NCX (parent = index, -1 pour la racine).
    static func tocTree(_ flat: [(node: TOCNode, parent: Int)]) -> [TOCNode] {
        var children: [Int: [Int]] = [:]
        var roots: [Int] = []
        for (i, e) in flat.enumerated() {
            if e.parent >= 0 && e.parent < flat.count && e.parent != i {
                children[e.parent, default: []].append(i)
            } else {
                roots.append(i)
            }
        }
        func make(_ i: Int, depth: Int) -> TOCNode {
            var n = flat[i].node
            n.children = depth > 10 ? [] : (children[i] ?? []).map { make($0, depth: depth + 1) }
            return n
        }
        return roots.map { make($0, depth: 0) }
    }
}

// MARK: - KF8

private struct KF8Unpacker {
    let book: MobiBook
    let header: MobiHeader
    let resourcePaths: [Int: String]

    struct Fragment {
        var insertPos: Int
        let selector: String
        let fileNumber: Int
        let length: Int
    }

    struct Part {
        let filename: String
        var bytes: [UInt8]
        let start: Int
        let end: Int
    }

    func build(into epub: inout EPUBBuilder) throws {
        let raw = try book.text(header)
        let flows = splitFlows(raw)
        guard let skelIndex = header.skeletonIndex, let fragIndex = header.fragmentIndex else {
            throw BookError.unreadable("index KF8 manquants")
        }
        let skel = try MobiIndexReader(records: book.records, index: skelIndex)
        let frag = try MobiIndexReader(records: book.records, index: fragIndex)
        var fragments = frag.entries.map { e in
            Fragment(insertPos: Int(String(decoding: e.key, as: UTF8.self)) ?? 0,
                     selector: String(decoding: frag.strings[e.tags[2]?.first ?? -1] ?? [], as: UTF8.self),
                     fileNumber: e.tags[3]?.first ?? 0,
                     length: e.tags[6]?.dropFirst().first ?? 0)
        }
        let parts = buildParts(text: flows.first ?? [], skeletons: skel.entries, fragments: &fragments)

        // Flux secondaires : feuilles de style ou SVG.
        var flowPaths: [Int: String] = [:]
        for j in 1..<max(1, flows.count) {
            let content = header.decode(flows[j])
            if content.contains("<svg") {
                flowPaths[j] = String(format: "Images/flow%05d.svg", j)
                epub.add(flowPaths[j]!, mediaType: "image/svg+xml", data: Data(content.utf8))
            } else {
                flowPaths[j] = String(format: "Styles/style%04d.css", j)
                epub.add(flowPaths[j]!, mediaType: "text/css",
                         data: Data(rewriteEmbeds(content, flowPaths: [:]).utf8))
            }
        }

        // Liens internes kindle:pos → fichier#id.
        var linkedAids = Set<String>()
        let posPattern = try! NSRegularExpression(pattern: "kindle:pos:fid:([0-9A-Va-v]{4}):off:([0-9A-Va-v]{10})")
        var texts = parts.map { header.decode($0.bytes) }
        for i in texts.indices {
            texts[i] = posPattern.replace(in: texts[i]) { g in
                let (file, id) = target(fid: Base32.decode(g[1]), off: Base32.decode(g[2]),
                                        fragments: fragments, parts: parts, linkedAids: &linkedAids)
                return file.map { ArchivePath.relative($0, from: "Text") + (id.isEmpty ? "" : "#" + id) } ?? "#"
            }
        }
        let aidPattern = try! NSRegularExpression(pattern: "\\s(?:aid|AID)\\s*=\\s*['\"]([^'\"]+)['\"]")
        for i in texts.indices {
            texts[i] = aidPattern.replace(in: texts[i]) { g in
                linkedAids.contains(g[1]) ? " id=\"aid-\(g[1])\"" : ""
            }
            texts[i] = rewriteEmbeds(texts[i], flowPaths: flowPaths)
            epub.add(parts[i].filename, mediaType: "application/xhtml+xml", data: Data(texts[i].utf8), inSpine: true)
        }

        if let ncx = header.ncxIndex, let index = try? MobiIndexReader(records: book.records, index: ncx) {
            let rebuilt = parts
            var flat: [(TOCNode, Int)] = []
            for e in index.entries {
                let label = header.decode(index.strings[e.tags[3]?.first ?? -1] ?? [])
                var path = rebuilt.first?.filename ?? ""
                var fragment: String?
                if let pf = e.tags[6], pf.count >= 2 {
                    var ignored = Set<String>()
                    let (file, id) = target(fid: pf[0], off: pf[1], fragments: fragments, parts: rebuilt,
                                            linkedAids: &ignored)
                    if let file { path = file }
                    if !id.isEmpty {
                        // Les ancres « aid » n'existent que si elles ont été liées dans le texte.
                        fragment = id.hasPrefix("aid-") && !linkedAids.contains(String(id.dropFirst(4))) ? nil : id
                    }
                }
                flat.append((TOCNode(title: label, path: path, fragment: fragment), e.tags[21]?.first ?? -1))
            }
            epub.toc = MobiToEPUB.tocTree(flat)
        }
    }

    private func splitFlows(_ raw: [UInt8]) -> [[UInt8]] {
        guard let f = header.fdstIndex, f < book.records.count, book.records[f].hasPrefix("FDST") else {
            return [raw]
        }
        let r = book.records[f]
        let count = r.u32(8)
        return (0..<count).map { j in
            let start = min(r.u32(12 + 8 * j), raw.count)
            let end = max(start, min(r.u32(16 + 8 * j), raw.count))
            return Array(raw[start..<end])
        }
    }

    private func buildParts(text: [UInt8], skeletons: [MobiIndexReader.Entry],
                            fragments: inout [Fragment]) -> [Part] {
        var parts: [Part] = []
        var fragPtr = 0
        for (fileNumber, s) in skeletons.enumerated() {
            let count = s.tags[1]?.first ?? 0
            let skelPos = s.tags[6]?.first ?? 0
            let skelLen = s.tags[6]?.dropFirst().first ?? 0
            var base = skelPos + skelLen
            var skeleton = text.slice(skelPos, skelLen)
            for _ in 0..<count where fragPtr < fragments.count {
                let f = fragments[fragPtr]
                let slice = text.slice(base, f.length)
                var insert = min(max(0, f.insertPos - skelPos), skeleton.count)
                if insideTag(skeleton, insert), let fixed = locateAfterTag(skeleton, aid: f.selector) {
                    insert = fixed
                    fragments[fragPtr].insertPos = fixed + skelPos
                }
                skeleton.insert(contentsOf: slice, at: insert)
                base += f.length
                fragPtr += 1
            }
            parts.append(Part(filename: String(format: "Text/part%04d.xhtml", fileNumber),
                              bytes: skeleton, start: skelPos, end: base))
        }
        return parts
    }

    private func insideTag(_ b: [UInt8], _ pos: Int) -> Bool {
        let lt = b.rfind(UInt8(ascii: "<"), before: pos) ?? -1
        let gt = b.rfind(UInt8(ascii: ">"), before: pos) ?? -1
        return lt > gt
    }

    /// Position juste après la balise portant `aid` (sélecteur `P-//*[@aid='X']`).
    private func locateAfterTag(_ b: [UInt8], aid selector: String) -> Int? {
        guard let q1 = selector.range(of: "'"), let q2 = selector.range(of: "'", range: q1.upperBound..<selector.endIndex)
        else { return nil }
        let aid = String(selector[q1.upperBound..<q2.lowerBound])
        for quote in ["\"", "'"] {
            if let p = b.find(Array("aid=\(quote)\(aid)\(quote)".utf8)), let gt = b.find(UInt8(ascii: ">"), from: p) {
                return gt + 1
            }
        }
        return nil
    }

    /// Convertit (fid, off) en (fichier, id) en cherchant l'ancre la plus proche avant la position.
    private func target(fid: Int, off: Int, fragments: [Fragment], parts: [Part],
                        linkedAids: inout Set<String>) -> (String?, String) {
        guard fid < fragments.count else { return (parts.first?.filename, "") }
        var pos = fragments[fid].insertPos + off
        var partIndex = parts.firstIndex { pos >= $0.start && pos < $0.end }
        if partIndex == nil {
            let file = fragments[fid].fileNumber
            guard file < parts.count else { return (parts.first?.filename, "") }
            partIndex = file
            pos = parts[file].start
        }
        let part = parts[partIndex!]
        return (part.filename, idTag(part.bytes, pos - part.start, linkedAids: &linkedAids))
    }

    private static let idPattern = try! NSRegularExpression(pattern: "^<[^>]*\\sid\\s*=\\s*['\"]([^'\"]*)['\"]", options: .caseInsensitive)
    private static let namePattern = try! NSRegularExpression(pattern: "^<[^>]*\\sname\\s*=\\s*['\"]([^'\"]*)['\"]", options: .caseInsensitive)
    private static let aidPattern = try! NSRegularExpression(pattern: "^<[^>]+\\s(?:aid|AID)\\s*=\\s*['\"]([^'\"]+)['\"]")

    private func idTag(_ block: [UInt8], _ position: Int, linkedAids: inout Set<String>) -> String {
        var npos = min(max(0, position), block.count)
        let gt = block.find(UInt8(ascii: ">"), from: npos) ?? block.count
        let lt = block.find(UInt8(ascii: "<"), from: npos) ?? block.count
        if lt == npos || gt < lt { npos = min(gt + 1, block.count) }
        var end = npos
        while let close = block.rfind(UInt8(ascii: ">"), before: end),
              let open = block.rfind(UInt8(ascii: "<"), before: close) {
            let tag = String(decoding: block[open...close], as: UTF8.self)
            end = open
            if tag.hasPrefix("<body ") || tag == "<body>" { return "" }
            if tag.hasPrefix("<meta ") || tag.hasPrefix("</") { continue }
            if let g = Self.idPattern.firstGroups(in: tag) ?? Self.namePattern.firstGroups(in: tag) { return g[1] }
            if let g = Self.aidPattern.firstGroups(in: tag) {
                linkedAids.insert(g[1])
                return "aid-" + g[1]
            }
        }
        return ""
    }

    private static let embedPattern = try! NSRegularExpression(pattern: "kindle:embed:([0-9A-Va-v]{4})(\\?mime=[^'\"\\)]*)?")
    private static let flowPattern = try! NSRegularExpression(pattern: "kindle:flow:([0-9A-Va-v]{4})(\\?mime=[^'\"\\)]*)?")

    /// kindle:embed / kindle:flow → chemins relatifs (depuis Text/ ou Styles/, même profondeur).
    private func rewriteEmbeds(_ s: String, flowPaths: [Int: String]) -> String {
        var out = Self.embedPattern.replace(in: s) { g in
            resourcePaths[Base32.decode(g[1]) - 1].map { "../" + $0 } ?? ""
        }
        out = Self.flowPattern.replace(in: out) { g in
            flowPaths[Base32.decode(g[1])].map { "../" + $0 } ?? ""
        }
        return out
    }
}

// MARK: - KF7

private struct KF7Unpacker {
    let book: MobiBook
    let resourcePaths: [Int: String]

    func build(into epub: inout EPUBBuilder) throws {
        let header = book.kf7
        var html = try book.text(header)

        // 1. Positions ciblées par les liens filepos et par le NCX.
        var targets = Set<Int>()
        let latin = String(decoding: html, as: Unicode.ASCII.self)
        let fileposPattern = try! NSRegularExpression(pattern: "filepos=['\"]?0*(\\d+)", options: .caseInsensitive)
        for m in fileposPattern.matches(in: latin, range: NSRange(location: 0, length: (latin as NSString).length)) {
            if let v = Int((latin as NSString).substring(with: m.range(at: 1))) { targets.insert(v) }
        }
        var ncxEntries: [MobiIndexReader.Entry] = []
        var ncxStrings: [Int: [UInt8]] = [:]
        if let ncx = header.ncxIndex, let index = try? MobiIndexReader(records: book.records, index: ncx) {
            ncxEntries = index.entries
            ncxStrings = index.strings
            for e in index.entries { if let p = e.tags[1]?.first { targets.insert(p) } }
        }

        // 2. Ancres insérées de la fin vers le début pour préserver les positions.
        for pos in targets.sorted(by: >) where pos < html.count {
            var p = pos
            let lt = html.rfind(UInt8(ascii: "<"), before: p) ?? -1
            let gt = html.rfind(UInt8(ascii: ">"), before: p) ?? -1
            if lt > gt { p = lt }
            html.insert(contentsOf: Array("<a id=\"filepos\(pos)\"></a>".utf8), at: p)
        }

        // 3. Nettoyage du balisage propre au MOBI, en Latin-1 pour rester octet par octet.
        var s = String(data: Data(html), encoding: .isoLatin1) ?? ""
        let replacements: [(String, String)] = [
            ("<guide[^>]*>.*?</guide>", ""),
            ("(<a\\b[^>]*?)\\s+filepos=['\"]?0*(\\d+)['\"]?", "$1 href=\"#filepos$2\""),
            ("\\s(?:hi|lo)recindex=['\"]?\\d+['\"]?", ""),
            ("<mbp:pagebreak[^>]*>", "\u{1}PAGEBREAK\u{1}"),
            ("</?mbp:[^>]*>", ""),
        ]
        for (pattern, template) in replacements {
            let re = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                            withTemplate: template)
        }
        let recindex = try! NSRegularExpression(pattern: "\\srecindex=['\"]?0*(\\d+)['\"]?", options: .caseInsensitive)
        s = recindex.replace(in: s) { g in
            resourcePaths[(Int(g[1]) ?? 0) - 1].map { " src=\"../\($0)\"" } ?? ""
        }
        if let b = s.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            s = String(s[b.upperBound...])
        }
        if let e = s.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
            s = String(s[..<e.lowerBound])
        }

        // 4. Découpage en chapitres et retour à l'encodage réel.
        let chunks = s.components(separatedBy: "\u{1}PAGEBREAK\u{1}").map { chunk -> String in
            let bytes = chunk.data(using: .isoLatin1) ?? Data()
            return header.decode([UInt8](bytes))
        }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var anchorFile: [String: String] = [:]
        let anchor = try! NSRegularExpression(pattern: "id=\"(filepos\\d+)\"")
        let names = chunks.indices.map { String(format: "Text/chapter%04d.xhtml", $0) }
        for (i, chunk) in chunks.enumerated() {
            for m in anchor.matches(in: chunk, range: NSRange(location: 0, length: (chunk as NSString).length)) {
                anchorFile[(chunk as NSString).substring(with: m.range(at: 1))] = names[i]
            }
        }
        let href = try! NSRegularExpression(pattern: "href=\"#(filepos\\d+)\"")
        for (i, chunk) in chunks.enumerated() {
            let linked = href.replace(in: chunk) { g in
                guard let file = anchorFile[g[1]] else { return "href=\"#\"" }
                return "href=\"\(ArchivePath.relative(file, from: "Text"))#\(g[1])\""
            }
            epub.add(names[i], mediaType: "application/xhtml+xml",
                     data: Data(Self.xhtml(linked, title: epub.metadata.title).utf8), inSpine: true)
        }

        // 5. Table des matières.
        var flat: [(TOCNode, Int)] = []
        for e in ncxEntries {
            guard let pos = e.tags[1]?.first, let file = anchorFile["filepos\(pos)"] else { continue }
            let label = header.decode(ncxStrings[e.tags[3]?.first ?? -1] ?? [])
            flat.append((TOCNode(title: label, path: file, fragment: "filepos\(pos)"), e.tags[21]?.first ?? -1))
        }
        epub.toc = MobiToEPUB.tocTree(flat)
    }

    /// Transforme un fragment HTML 3.2 en XHTML bien formé (via le mode tidy de XMLDocument).
    static func xhtml(_ body: String, title: String) -> String {
        let source = "<html><head><title>\(title.xmlEscaped)</title></head><body>\(body)</body></html>"
        var serialized: String
        if let doc = try? XMLDocument(xmlString: HTMLEntities.toNumeric(source), options: [.documentTidyHTML]),
           let root = doc.rootElement() {
            root.namespaces = [XMLNode.namespace(withName: "", stringValue: "http://www.w3.org/1999/xhtml") as! XMLNode]
            serialized = root.xmlString(options: [.nodeCompactEmptyElement])
        } else {
            let text = MetadataExtractor.stripHTML(body).xmlEscaped
            serialized = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>\(title.xmlEscaped)</title></head><body><p>\(text)</p></body></html>"
        }
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" + serialized
    }
}
