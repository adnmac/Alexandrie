import Foundation

/// Compression PalmDoc (LZ77 simplifié) utilisée par les enregistrements texte MOBI.
enum PalmDoc {
    static func decompress(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count * 2)
        var i = 0
        while i < input.count {
            let c = Int(input[i])
            i += 1
            if c >= 1 && c <= 8 {
                let end = min(i + c, input.count)
                out.append(contentsOf: input[i..<end])
                i = end
            } else if c < 0x80 {
                out.append(UInt8(c))
            } else if c >= 0xC0 {
                out.append(0x20)
                out.append(UInt8(c ^ 0x80))
            } else {
                guard i < input.count else { break }
                let pair = (c << 8) | Int(input[i])
                i += 1
                let distance = (pair >> 3) & 0x07FF
                let length = (pair & 7) + 3
                guard distance > 0, distance <= out.count else { continue }
                let start = out.count - distance
                for k in 0..<length { out.append(out[start + k]) }
            }
        }
        return out
    }

    /// Compression équivalente à celle de calibre (cPalmdoc).
    static func compress(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        let n = input.count
        input.withUnsafeBufferPointer { data in
            var i = 0
            while i < n {
                if i > 10 && n - i > 10, let (j, length) = longestMatch(data, i) {
                    let compound = ((i - j) << 3) + length - 3
                    out.append(UInt8(0x80 + (compound >> 8)))
                    out.append(UInt8(compound & 0xFF))
                    i += length
                    continue
                }
                var c = data[i]
                i += 1
                if c == 0x20 && i < n {
                    let next = data[i]
                    if next >= 0x40 && next <= 0x7F {
                        out.append(next ^ 0x80)
                        i += 1
                        continue
                    }
                }
                if c == 0 || (c > 8 && c < 0x80) {
                    out.append(c)
                } else {
                    // Suite d'octets « binaires » échappés par un préfixe de longueur 1-8.
                    var run: [UInt8] = [c]
                    var j = i
                    while j < n && run.count < 8 {
                        c = data[j]
                        if c == 0 || (c > 8 && c < 0x80) { break }
                        run.append(c)
                        j += 1
                    }
                    i += run.count - 1
                    out.append(UInt8(run.count))
                    out.append(contentsOf: run)
                }
            }
        }
        return out
    }

    /// Correspondance la plus longue (3 à 10 octets) dans la fenêtre de 2047 octets ;
    /// à longueur égale, la plus proche — même résultat que calibre, en un seul passage.
    private static func longestMatch(_ data: UnsafeBufferPointer<UInt8>, _ pos: Int) -> (Int, Int)? {
        var best: (Int, Int)?
        let limit = max(0, pos - 2047)
        var j = pos - 3
        let first = data[pos]
        while j >= limit {
            if data[j] == first {
                // La source ne doit pas chevaucher la position courante.
                let maxLength = min(10, pos - j)
                var k = 1
                while k < maxLength && data[j + k] == data[pos + k] { k += 1 }
                if k >= 3 && k > (best?.1 ?? 0) {
                    best = (j, k)
                    if k == 10 { break }
                }
            }
            j -= 1
        }
        return best
    }
}

/// Décompression HUFF/CDIC (portage du lecteur de KindleUnpack).
final class HuffCDICReader {
    private var dict1: [(codelen: Int, term: Bool, maxcode: UInt64)] = []
    private var mincode: [UInt64] = []
    private var maxcode: [UInt64] = []
    private var dictionary: [(bytes: [UInt8], done: Bool)?] = []

    init(huff: [UInt8], cdics: [[UInt8]]) throws {
        guard huff.hasPrefix("HUFF"), huff.u32(4) == 0x18 else {
            throw BookError.unreadable("enregistrement HUFF invalide")
        }
        let off1 = huff.u32(8), off2 = huff.u32(12)
        for i in 0..<256 {
            let v = UInt64(huff.u32(off1 + 4 * i))
            let codelen = Int(v & 0x1F)
            let term = v & 0x80 != 0
            let mc = v >> 8
            dict1.append((codelen, term, codelen == 0 ? 0 : ((mc + 1) << (32 - UInt64(codelen))) - 1))
        }
        mincode = [0]
        maxcode = [0xFFFF_FFFF]
        for codelen in 1...32 {
            let lo = UInt64(huff.u32(off2 + 8 * (codelen - 1)))
            let hi = UInt64(huff.u32(off2 + 8 * (codelen - 1) + 4))
            mincode.append(lo << (32 - UInt64(codelen)))
            maxcode.append(((hi + 1) << (32 - UInt64(codelen))) - 1)
        }
        for cdic in cdics {
            guard cdic.hasPrefix("CDIC"), cdic.u32(4) == 0x10 else {
                throw BookError.unreadable("enregistrement CDIC invalide")
            }
            let phrases = cdic.u32(8), bits = cdic.u32(12)
            let n = min(1 << bits, phrases - dictionary.count)
            for k in 0..<max(0, n) {
                let off = cdic.u16(16 + 2 * k)
                let blen = cdic.u16(16 + off)
                dictionary.append((cdic.slice(18 + off, blen & 0x7FFF), blen & 0x8000 != 0))
            }
        }
    }

    func unpack(_ input: [UInt8]) -> [UInt8] {
        var bitsLeft = input.count * 8
        let data = input + [UInt8](repeating: 0, count: 8)
        func q(_ pos: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<8 { v = (v << 8) | UInt64(data[pos + k]) }
            return v
        }
        var pos = 0
        var x = q(pos)
        var n = 32
        var out: [UInt8] = []
        while true {
            if n <= 0 {
                pos += 4
                x = q(pos)
                n += 32
            }
            let code = (x >> UInt64(n)) & 0xFFFF_FFFF
            var (codelen, term, mc) = dict1[Int(code >> 24)]
            if !term {
                while codelen < 32 && code < mincode[codelen] { codelen += 1 }
                mc = maxcode[codelen]
            }
            n -= codelen
            bitsLeft -= codelen
            if bitsLeft < 0 || codelen == 0 { break }
            let r = Int((mc - code) >> UInt64(32 - codelen))
            guard r < dictionary.count, let entry = dictionary[r] else { break }
            if entry.done {
                out.append(contentsOf: entry.bytes)
            } else {
                dictionary[r] = nil
                let expanded = unpack(entry.bytes)
                dictionary[r] = (expanded, true)
                out.append(contentsOf: expanded)
            }
        }
        return out
    }
}
