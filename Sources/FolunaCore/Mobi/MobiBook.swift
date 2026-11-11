import Foundation

/// Valeur « absente » des champs d'index MOBI.
let mobiNull = 0xFFFF_FFFF

/// En-tête PalmDoc + MOBI + EXTH (enregistrement 0 d'une section KF7 ou KF8).
struct MobiHeader {
    let raw: [UInt8]
    /// Index de l'enregistrement 0 de cette section dans la base PalmDB.
    let start: Int

    var compression: Int { raw.u16(0) }
    var textLength: Int { raw.u32(4) }
    var textRecordCount: Int { raw.u16(8) }
    var encryption: Int { raw.u16(12) }
    var headerLength: Int { raw.u32(20) }
    var encoding: Int { raw.u32(28) }
    var version: Int { raw.u32(36) }
    var isKF8: Bool { version >= 8 }
    var isUTF8: Bool { encoding == 65001 }

    /// Champs d'index, convertis en index absolus (ou nil si absents).
    private func index(_ offset: Int) -> Int? {
        guard headerLength + 16 > offset else { return nil }
        let v = raw.u32(offset)
        return v == mobiNull ? nil : v + start
    }

    var firstResource: Int? { index(0x6C) }
    var huffRecord: Int? { index(0x70) }
    var huffCount: Int { raw.u32(0x74) }
    var fdstIndex: Int? { isKF8 ? index(0xC0) : nil }
    var ncxIndex: Int? { index(0xF4) }
    var fragmentIndex: Int? { isKF8 ? index(0xF8) : nil }
    var skeletonIndex: Int? { isKF8 ? index(0xFC) : nil }

    var extraDataFlags: Int {
        headerLength >= 0xE4 && version >= 5 ? raw.u16(0xF2) : 0
    }

    var fullName: String {
        decode(raw.slice(raw.u32(0x54), raw.u32(0x58)))
    }

    /// Enregistrements EXTH : type → valeurs (un type peut se répéter, ex. plusieurs auteurs).
    let exth: [Int: [[UInt8]]]

    init(raw: [UInt8], start: Int) {
        self.raw = raw
        self.start = start
        var exth: [Int: [[UInt8]]] = [:]
        let headerLength = raw.u32(20)
        let base = 16 + headerLength
        if raw.u32(0x80) & 0x40 != 0, raw.slice(base, 4) == Array("EXTH".utf8) {
            let count = raw.u32(base + 8)
            var pos = base + 12
            for _ in 0..<count {
                let type = raw.u32(pos), len = raw.u32(pos + 4)
                guard len >= 8 else { break }
                exth[type, default: []].append(raw.slice(pos + 8, len - 8))
                pos += len
            }
        }
        self.exth = exth
    }

    func decode(_ bytes: [UInt8]) -> String {
        if isUTF8 { return String(decoding: bytes, as: UTF8.self) }
        return String(data: Data(bytes), encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }

    func exthString(_ type: Int) -> String? {
        exth[type]?.first.map(decode)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func exthStrings(_ type: Int) -> [String] {
        (exth[type] ?? []).map { decode($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func exthInt(_ type: Int) -> Int? {
        guard let v = exth[type]?.first, v.count >= 4 else { return nil }
        return v.u32(0)
    }
}

/// Fichier MOBI / AZW / AZW3 (KF7, KF8 ou hybride).
public final class MobiBook {
    let records: [[UInt8]]
    let kf7: MobiHeader
    /// Section KF8 (AZW3 pur ou partie KF8 d'un MOBI hybride).
    let kf8: MobiHeader?

    public convenience init(url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count > 78 else { throw BookError.unreadable("fichier trop court") }
        let type = bytes.ascii(60, 8)
        guard type == "BOOKMOBI" || type == "TEXtREAd" else {
            throw BookError.unreadable("signature PalmDB inconnue (\(type))")
        }
        let count = bytes.u16(76)
        var offsets = (0..<count).map { bytes.u32(78 + 8 * $0) }
        offsets.append(bytes.count)
        records = (0..<count).map { i in
            let a = min(offsets[i], bytes.count), b = max(a, min(offsets[i + 1], bytes.count))
            return Array(bytes[a..<b])
        }
        guard let first = records.first else { throw BookError.unreadable("aucun enregistrement") }
        kf7 = MobiHeader(raw: first, start: 0)
        if kf7.isKF8 {
            kf8 = kf7
        } else if let boundary = kf7.exthInt(121), boundary != mobiNull {
            kf8 = Self.locateKF8(records, boundary)
        } else {
            kf8 = nil
        }
    }

    /// EXTH 121 désigne l'enregistrement BOUNDARY ou l'en-tête KF8 qui le suit selon les outils.
    private static func locateKF8(_ records: [[UInt8]], _ boundary: Int) -> MobiHeader? {
        for candidate in [boundary, boundary + 1] where candidate < records.count {
            let r = records[candidate]
            if r.slice(16, 4) == Array("MOBI".utf8) {
                let h = MobiHeader(raw: r, start: candidate)
                if h.isKF8 { return h }
            }
        }
        return nil
    }

    public var isDRMProtected: Bool { kf7.encryption != 0 || (kf8?.encryption ?? 0) != 0 }
    public var hasKF8: Bool { kf8 != nil }

    /// En-tête de référence pour les métadonnées et les ressources.
    var mainHeader: MobiHeader { kf8 ?? kf7 }

    /// Premier enregistrement de ressource (images, polices…). Dans un hybride, les ressources
    /// sont partagées et commencent là où l'indique l'en-tête KF7.
    var firstResource: Int? {
        if kf8 != nil && !kf7.isKF8 { return kf7.firstResource }
        return mainHeader.firstResource
    }

    func resource(_ relativeIndex: Int) -> [UInt8]? {
        guard let first = firstResource else { return nil }
        let i = first + relativeIndex
        return i >= 0 && i < records.count ? records[i] : nil
    }

    // MARK: - Texte

    /// Texte brut décompressé d'une section (HTML KF7 ou « rawML » KF8).
    func text(_ header: MobiHeader) throws -> [UInt8] {
        guard header.encryption == 0 else { throw BookError.drmProtected }
        var huff: HuffCDICReader?
        if header.compression == 17480 {
            guard let h = header.huffRecord, h < records.count else {
                throw BookError.unreadable("table HUFF absente")
            }
            let cdics = (1..<max(1, header.huffCount)).compactMap { h + $0 < records.count ? records[h + $0] : nil }
            huff = try HuffCDICReader(huff: records[h], cdics: cdics)
        } else if header.compression != 1 && header.compression != 2 {
            throw BookError.unsupported("compression \(header.compression)")
        }
        var out: [UInt8] = []
        out.reserveCapacity(header.textLength)
        for i in 1...max(1, header.textRecordCount) {
            let idx = header.start + i
            guard idx < records.count else { break }
            var rec = records[idx]
            let trailing = Self.trailingSize(rec, flags: header.extraDataFlags)
            rec = Array(rec.prefix(max(0, rec.count - trailing)))
            switch header.compression {
            case 2: out.append(contentsOf: PalmDoc.decompress(rec))
            case 17480: out.append(contentsOf: huff!.unpack(rec))
            default: out.append(contentsOf: rec)
            }
        }
        if out.count > header.textLength { out.removeLast(out.count - header.textLength) }
        return out
    }

    /// Taille des données de fin d'enregistrement (TBS, octets multi-octets…).
    static func trailingSize(_ rec: [UInt8], flags: Int) -> Int {
        func entrySize(_ size: Int) -> Int {
            var bitpos = 0, result = 0, size = size
            while size > 0 {
                let v = Int(rec[size - 1])
                result |= (v & 0x7F) << bitpos
                bitpos += 7
                size -= 1
                if v & 0x80 != 0 || bitpos >= 28 { break }
            }
            return result
        }
        var num = 0
        var test = flags >> 1
        while test != 0 {
            if test & 1 != 0 { num += entrySize(rec.count - num) }
            test >>= 1
        }
        if flags & 1 != 0, rec.count - num - 1 >= 0 {
            num += Int(rec[rec.count - num - 1] & 0x3) + 1
        }
        return num
    }

    // MARK: - Métadonnées

    public func metadata() -> BookMetadata {
        let h = mainHeader
        var meta = BookMetadata(title: h.exthString(503) ?? h.fullName)
        meta.authors = h.exthStrings(100).flatMap { splitAuthors($0) }
        meta.publisher = h.exthString(101)
        meta.summary = h.exthString(103)
        meta.identifier = h.exthString(104) ?? h.exthString(113)
        meta.publishedDate = h.exthString(106)
        meta.isbn = ISBN.first(in: h.exthStrings(104))
        meta.subjects = h.exthStrings(105)
        meta.language = h.exthString(524)
        meta.isDRMProtected = isDRMProtected
        meta.coverData = coverImage().map { Data($0) }
        return meta
    }

    private func splitAuthors(_ s: String) -> [String] {
        s.components(separatedBy: "&").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Index relatif (dans les ressources) de l'image de couverture.
    var coverResourceIndex: Int? {
        let h = mainHeader
        for type in [201, 202] {
            if let off = h.exthInt(type), off != mobiNull, let r = resource(off), ImageTools.mimeType(r) != nil {
                return off
            }
        }
        return nil
    }

    func coverImage() -> [UInt8]? {
        if let i = coverResourceIndex { return resource(i) }
        // À défaut, la première image des ressources.
        guard let first = firstResource else { return nil }
        for i in first..<min(records.count, first + 50) where ImageTools.mimeType(records[i]) != nil {
            return records[i]
        }
        return nil
    }

    /// EXTH 113 (ASIN) — utile pour les miniatures sur la Kindle.
    public var asin: String? { mainHeader.exthString(113) }
    public var cdeType: String? { mainHeader.exthString(501) }
}
