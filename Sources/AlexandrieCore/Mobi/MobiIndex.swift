import Foundation

/// Lecture des index INDX/TAGX/CNCX (squelettes, fragments, NCX…).
struct MobiIndexReader {
    struct Entry {
        let key: [UInt8]
        let tags: [Int: [Int]]
    }

    let entries: [Entry]
    /// Chaînes CNCX par offset.
    let strings: [Int: [UInt8]]

    init(records: [[UInt8]], index: Int) throws {
        guard index < records.count, records[index].hasPrefix("INDX") else {
            throw BookError.unreadable(String(localized: "index INDX introuvable"))
        }
        let header = records[index]
        let headerLength = header.u32(4)
        let dataRecords = header.u32(24)
        let cncxCount = header.u32(52)

        var strings: [Int: [UInt8]] = [:]
        for j in 0..<cncxCount {
            let r = index + dataRecords + 1 + j
            guard r < records.count else { break }
            for (off, s) in Self.readCNCX(records[r]) { strings[off + j * 0x10000] = s }
        }
        self.strings = strings

        let (controlBytes, tagTable) = Self.readTAGX(header, at: headerLength)
        var entries: [Entry] = []
        for r in (index + 1)..<min(records.count, index + 1 + dataRecords) {
            let data = records[r]
            guard data.hasPrefix("INDX") else { continue }
            let idxt = data.u32(20), count = data.u32(24)
            var positions = (0..<count).map { data.u16(idxt + 4 + 2 * $0) }
            positions.append(idxt)
            for j in 0..<count {
                let start = positions[j], end = positions[j + 1]
                let keyLength = data.u8(start)
                let key = data.slice(start + 1, keyLength)
                let tags = Self.tagMap(controlBytes, tagTable, data, start + 1 + keyLength, end)
                entries.append(Entry(key: key, tags: tags))
            }
        }
        self.entries = entries
    }

    private static func readCNCX(_ data: [UInt8]) -> [(Int, [UInt8])] {
        var out: [(Int, [UInt8])] = []
        var offset = 0
        while offset < data.count, data[offset] != 0 {
            let start = offset
            let (consumed, length) = VarInt.readForward(data, offset)
            offset += consumed
            out.append((start, data.slice(offset, length)))
            offset += length
        }
        return out
    }

    private static func readTAGX(_ data: [UInt8], at start: Int) -> (Int, [(tag: Int, perEntry: Int, mask: Int, end: Int)]) {
        guard data.slice(start, 4) == Array("TAGX".utf8) else { return (0, []) }
        let firstEntry = data.u32(start + 4)
        let controlBytes = data.u32(start + 8)
        var table: [(Int, Int, Int, Int)] = []
        var i = 12
        while i < firstEntry {
            let p = start + i
            table.append((data.u8(p), data.u8(p + 1), data.u8(p + 2), data.u8(p + 3)))
            i += 4
        }
        return (controlBytes, table)
    }

    private static func tagMap(_ controlByteCount: Int, _ table: [(tag: Int, perEntry: Int, mask: Int, end: Int)],
                               _ data: [UInt8], _ start: Int, _ end: Int) -> [Int: [Int]] {
        var pending: [(tag: Int, count: Int?, bytes: Int?, perEntry: Int)] = []
        var controlIndex = 0
        var dataStart = start + controlByteCount
        for t in table {
            if t.end == 1 {
                controlIndex += 1
                continue
            }
            var mask = t.mask
            var value = data.u8(start + controlIndex) & mask
            guard value != 0 else { continue }
            if value == mask {
                if mask.nonzeroBitCount > 1 {
                    let (consumed, v) = VarInt.readForward(data, dataStart)
                    dataStart += consumed
                    pending.append((t.tag, nil, v, t.perEntry))
                } else {
                    pending.append((t.tag, 1, nil, t.perEntry))
                }
            } else {
                while mask & 1 == 0 {
                    mask >>= 1
                    value >>= 1
                }
                pending.append((t.tag, value, nil, t.perEntry))
            }
        }
        var result: [Int: [Int]] = [:]
        for p in pending {
            var values: [Int] = []
            if let count = p.count {
                for _ in 0..<(count * p.perEntry) {
                    let (consumed, v) = VarInt.readForward(data, dataStart)
                    dataStart += consumed
                    values.append(v)
                }
            } else if let bytes = p.bytes {
                var total = 0
                while total < bytes && dataStart < end {
                    let (consumed, v) = VarInt.readForward(data, dataStart)
                    dataStart += consumed
                    total += consumed
                    values.append(v)
                }
            }
            result[p.tag] = values
        }
        return result
    }
}

/// Écriture d'un index INDX (en-tête + enregistrements de données + CNCX),
/// sur le modèle du writer KF8 de calibre.
struct MobiIndexWriter {
    struct Tag {
        let number: Int
        let perEntry: Int
        let mask: Int
    }

    let tags: [Tag]
    /// Entrées triées : clé + valeurs par numéro de tag.
    var entries: [(key: String, values: [Int: [Int]])] = []
    /// Chaînes CNCX déjà construites (offsets référencés par les entrées).
    var cncxRecords: [[UInt8]] = []

    private static let headerLength = 192

    func tagx() -> [UInt8] {
        var body: [UInt8] = []
        for t in tags { body += [UInt8(t.number), UInt8(t.perEntry), UInt8(t.mask), 0] }
        body += [0, 0, 0, 1]
        var out = Array("TAGX".utf8)
        out.appendBE32(12 + body.count)
        out.appendBE32(1)
        return out + body
    }

    private func controlByte(_ values: [Int: [Int]]) -> UInt8 {
        var cb = 0
        for t in tags {
            let n = (values[t.number]?.count ?? 0) / t.perEntry
            cb |= t.mask & (n << t.mask.trailingZeroBitCount)
        }
        return UInt8(cb)
    }

    func records() -> [[UInt8]] {
        let recordLimit = 0x10000 - Self.headerLength - 1048
        var blocks: [[UInt8]] = [[]], idxts: [[UInt8]] = [[]]
        var counts = [0]
        var lastKeys: [[UInt8]] = [[]]
        for e in entries {
            let key = Array(e.key.utf8)
            var raw: [UInt8] = [UInt8(key.count)] + key + [controlByte(e.values)]
            for t in tags {
                for v in e.values[t.number] ?? [] { raw += VarInt.encodeForward(v) }
            }
            if blocks[blocks.count - 1].count + idxts[idxts.count - 1].count + raw.count + 2 > recordLimit {
                blocks.append([]); idxts.append([]); counts.append(0); lastKeys.append([])
            }
            let last = blocks.count - 1
            idxts[last].appendBE16(Self.headerLength + blocks[last].count)
            blocks[last] += raw
            counts[last] += 1
            lastKeys[last] = key
        }

        var dataRecords: [[UInt8]] = []
        for k in 0..<blocks.count {
            let block = blocks[k].aligned4()
            let idxt = (Array("IDXT".utf8) + idxts[k]).aligned4()
            var rec = Array("INDX".utf8)
            rec.appendBE32(Self.headerLength)
            rec.appendBE32(0)
            rec.appendBE32(1)
            rec.appendBE32(0)
            rec.appendBE32(Self.headerLength + block.count)
            rec.appendBE32(counts[k])
            rec += [UInt8](repeating: 0xFF, count: 8)
            rec += [UInt8](repeating: 0, count: 156)
            dataRecords.append(rec + block + idxt)
        }

        // En-tête : TAGX + géométrie (dernière clé de chaque enregistrement) + IDXT.
        let tagx = tagx()
        var geometry: [UInt8] = []
        var idxt = Array("IDXT".utf8)
        var pos = Self.headerLength + tagx.count
        for (key, count) in zip(lastKeys, counts) {
            idxt.appendBE16(pos)
            var g: [UInt8] = [UInt8(key.count)] + key
            g.appendBE16(count)
            geometry += g
            pos += g.count
        }
        let tagxA = tagx.aligned4(), geometryA = geometry.aligned4(), idxtA = idxt.aligned4()
        var header = Array("INDX".utf8)
        header.appendBE32(Self.headerLength)
        header += [UInt8](repeating: 0, count: 8)
        header.appendBE32(2)
        header.appendBE32(Self.headerLength + tagxA.count + geometryA.count)
        header.appendBE32(dataRecords.count)
        header.appendBE32(65001)
        header.appendBE32(mobiNull)
        header.appendBE32(entries.count)
        header.appendBE32(0)
        header.appendBE32(0)
        header.appendBE32(0)
        header.appendBE32(cncxRecords.count)
        header += [UInt8](repeating: 0, count: 124)
        header.appendBE32(Self.headerLength)
        header += [UInt8](repeating: 0, count: 8)
        return [header + tagxA + geometryA + idxtA] + dataRecords + cncxRecords
    }
}

/// Table de chaînes CNCX ; renvoie l'offset de chaque chaîne.
struct CNCXBuilder {
    private(set) var records: [[UInt8]] = []
    private var current: [UInt8] = []
    private var offsets: [String: Int] = [:]

    mutating func offset(for string: String) -> Int {
        if let o = offsets[string] { return o }
        let utf8 = Array(String(string.prefix(500)).utf8)
        let raw = VarInt.encodeForward(utf8.count) + utf8
        if current.count + raw.count > 0x10000 - 1024 {
            records.append(current.aligned4())
            current = []
        }
        let o = records.count * 0x10000 + current.count
        current += raw
        offsets[string] = o
        return o
    }

    mutating func finish() -> [[UInt8]] {
        if !current.isEmpty {
            records.append(current.aligned4())
            current = []
        }
        return records
    }
}
