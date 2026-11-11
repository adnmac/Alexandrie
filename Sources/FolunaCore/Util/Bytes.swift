import Foundation

/// Accès binaires big-endian tolérants : une lecture hors limites renvoie 0
/// plutôt que de faire planter l'app sur un fichier corrompu.
extension Array where Element == UInt8 {
    @inline(__always) func u8(_ o: Int) -> Int {
        o >= 0 && o < count ? Int(self[o]) : 0
    }

    @inline(__always) func u16(_ o: Int) -> Int {
        (u8(o) << 8) | u8(o + 1)
    }

    @inline(__always) func u32(_ o: Int) -> Int {
        (u8(o) << 24) | (u8(o + 1) << 16) | (u8(o + 2) << 8) | u8(o + 3)
    }

    func slice(_ o: Int, _ length: Int) -> [UInt8] {
        let start = Swift.max(0, Swift.min(o, count))
        let end = Swift.max(start, Swift.min(o + length, count))
        return Array(self[start..<end])
    }

    func ascii(_ o: Int, _ length: Int) -> String {
        String(decoding: slice(o, length), as: UTF8.self)
    }

    func hasPrefix(_ s: String) -> Bool {
        let p = Array(s.utf8)
        return count >= p.count && Array(self[0..<p.count]) == p
    }

    /// Première occurrence de `pattern` à partir de `from`.
    func find(_ pattern: [UInt8], from: Int = 0) -> Int? {
        guard !pattern.isEmpty, pattern.count <= count else { return nil }
        var i = Swift.max(0, from)
        let first = pattern[0]
        while i <= count - pattern.count {
            if self[i] == first {
                var j = 1
                while j < pattern.count && self[i + j] == pattern[j] { j += 1 }
                if j == pattern.count { return i }
            }
            i += 1
        }
        return nil
    }

    func find(_ byte: UInt8, from: Int) -> Int? {
        var i = Swift.max(0, from)
        while i < count {
            if self[i] == byte { return i }
            i += 1
        }
        return nil
    }

    /// Dernière occurrence de `byte` strictement avant `before`.
    func rfind(_ byte: UInt8, before: Int) -> Int? {
        var i = Swift.min(before, count) - 1
        while i >= 0 {
            if self[i] == byte { return i }
            i -= 1
        }
        return nil
    }

    mutating func appendBE16(_ v: Int) {
        append(UInt8((v >> 8) & 0xFF)); append(UInt8(v & 0xFF))
    }

    mutating func appendBE32(_ v: Int) {
        append(UInt8((v >> 24) & 0xFF)); append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF)); append(UInt8(v & 0xFF))
    }

    mutating func append(_ s: String) {
        append(contentsOf: Array(s.utf8))
    }

    /// Complète par des zéros jusqu'à un multiple de 4.
    func aligned4() -> [UInt8] {
        let r = count % 4
        return r == 0 ? self : self + [UInt8](repeating: 0, count: 4 - r)
    }
}

/// Entiers à largeur variable des index MOBI (7 bits par octet).
enum VarInt {
    /// Lecture « avant » : le dernier octet porte le bit 0x80.
    static func readForward(_ data: [UInt8], _ offset: Int) -> (consumed: Int, value: Int) {
        var value = 0, consumed = 0
        while offset + consumed < data.count {
            let v = Int(data[offset + consumed])
            consumed += 1
            value = (value << 7) | (v & 0x7F)
            if v & 0x80 != 0 { break }
        }
        return (consumed, value)
    }

    /// Encodage « avant » (équivalent de `encint` de calibre).
    static func encodeForward(_ value: Int) -> [UInt8] {
        var v = value
        var bytes: [UInt8] = []
        repeat {
            bytes.insert(UInt8(v & 0x7F), at: 0)
            v >>= 7
        } while v > 0
        bytes[bytes.count - 1] |= 0x80
        return bytes
    }
}

/// Base 32 Amazon (0-9A-V) utilisée dans `kindle:embed`, `kindle:pos`, `aid`.
enum Base32 {
    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUV")

    static func encode(_ value: Int, width: Int = 0) -> String {
        var v = value
        var out: [Character] = []
        repeat {
            out.insert(digits[v % 32], at: 0)
            v /= 32
        } while v > 0
        while out.count < width { out.insert("0", at: 0) }
        return String(out)
    }

    static func decode<S: StringProtocol>(_ s: S) -> Int {
        var v = 0
        for c in s.uppercased() {
            guard let d = digits.firstIndex(of: c) else { continue }
            v = v * 32 + d
        }
        return v
    }
}

extension String {
    /// Échappement XML minimal pour le texte et les attributs.
    var xmlEscaped: String {
        var s = replacingOccurrences(of: "&", with: "&amp;")
        s = s.replacingOccurrences(of: "<", with: "&lt;")
        s = s.replacingOccurrences(of: ">", with: "&gt;")
        return s.replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Nom de fichier sûr pour la Kindle et les systèmes de fichiers FAT.
    public var safeFilename: String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}")
        let cleaned = unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(120))
    }
}

/// Résolution de chemins relatifs à l'intérieur d'une archive (EPUB).
enum ArchivePath {
    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Résout `href` relativement à `baseDir` ; renvoie (chemin, fragment).
    static func resolve(_ href: String, relativeTo baseDir: String) -> (path: String, fragment: String?) {
        var target = href
        var fragment: String?
        if let hash = target.firstIndex(of: "#") {
            fragment = String(target[target.index(after: hash)...])
            target = String(target[..<hash])
        }
        target = target.removingPercentEncoding ?? target
        if target.isEmpty { return ("", fragment) }
        var parts = target.hasPrefix("/") ? [] : baseDir.split(separator: "/").map(String.init)
        for comp in target.split(separator: "/") {
            switch comp {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(comp))
            }
        }
        return (parts.joined(separator: "/"), fragment)
    }

    /// Chemin relatif de `target` vu depuis le dossier `fromDir`.
    static func relative(_ target: String, from fromDir: String) -> String {
        let a = fromDir.split(separator: "/").map(String.init)
        let b = target.split(separator: "/").map(String.init)
        var i = 0
        while i < a.count && i < b.count - 1 && a[i] == b[i] { i += 1 }
        let ups = Array(repeating: "..", count: a.count - i)
        return (ups + b[i...]).joined(separator: "/")
    }

    static func isExternal(_ href: String) -> Bool {
        let lower = href.lowercased()
        return lower.contains(":") && !lower.hasPrefix("kindle:")
    }
}
