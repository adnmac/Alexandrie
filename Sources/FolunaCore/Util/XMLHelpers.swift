import Foundation

/// Entités HTML nommées courantes, absentes du XML pur.
enum HTMLEntities {
    static let table: [String: Int] = [
        "nbsp": 160, "iexcl": 161, "cent": 162, "pound": 163, "euro": 8364, "yen": 165,
        "sect": 167, "uml": 168, "copy": 169, "ordf": 170, "laquo": 171, "not": 172,
        "shy": 173, "reg": 174, "deg": 176, "plusmn": 177, "sup2": 178, "sup3": 179,
        "acute": 180, "micro": 181, "para": 182, "middot": 183, "cedil": 184, "sup1": 185,
        "ordm": 186, "raquo": 187, "frac14": 188, "frac12": 189, "frac34": 190, "iquest": 191,
        "Agrave": 192, "Aacute": 193, "Acirc": 194, "Atilde": 195, "Auml": 196, "Aring": 197,
        "AElig": 198, "Ccedil": 199, "Egrave": 200, "Eacute": 201, "Ecirc": 202, "Euml": 203,
        "Igrave": 204, "Iacute": 205, "Icirc": 206, "Iuml": 207, "ETH": 208, "Ntilde": 209,
        "Ograve": 210, "Oacute": 211, "Ocirc": 212, "Otilde": 213, "Ouml": 214, "times": 215,
        "Oslash": 216, "Ugrave": 217, "Uacute": 218, "Ucirc": 219, "Uuml": 220, "Yacute": 221,
        "THORN": 222, "szlig": 223, "agrave": 224, "aacute": 225, "acirc": 226, "atilde": 227,
        "auml": 228, "aring": 229, "aelig": 230, "ccedil": 231, "egrave": 232, "eacute": 233,
        "ecirc": 234, "euml": 235, "igrave": 236, "iacute": 237, "icirc": 238, "iuml": 239,
        "eth": 240, "ntilde": 241, "ograve": 242, "oacute": 243, "ocirc": 244, "otilde": 245,
        "ouml": 246, "divide": 247, "oslash": 248, "ugrave": 249, "uacute": 250, "ucirc": 251,
        "uuml": 252, "yacute": 253, "thorn": 254, "yuml": 255, "OElig": 338, "oelig": 339,
        "Scaron": 352, "scaron": 353, "Yuml": 376, "fnof": 402, "circ": 710, "tilde": 732,
        "ensp": 8194, "emsp": 8195, "thinsp": 8201, "zwnj": 8204, "zwj": 8205, "lrm": 8206,
        "rlm": 8207, "ndash": 8211, "mdash": 8212, "lsquo": 8216, "rsquo": 8217, "sbquo": 8218,
        "ldquo": 8220, "rdquo": 8221, "bdquo": 8222, "dagger": 8224, "Dagger": 8225,
        "bull": 8226, "hellip": 8230, "permil": 8240, "prime": 8242, "Prime": 8243,
        "lsaquo": 8249, "rsaquo": 8250, "trade": 8482, "larr": 8592, "rarr": 8594,
        "uarr": 8593, "darr": 8595, "harr": 8596, "minus": 8722, "le": 8804, "ge": 8805,
        "ne": 8800, "infin": 8734, "alpha": 945, "beta": 946, "gamma": 947, "delta": 948,
        "pi": 960, "sigma": 963, "omega": 969, "Omega": 937,
    ]

    private static let pattern = try! NSRegularExpression(pattern: "&([A-Za-z][A-Za-z0-9]*);")

    /// Remplace les entités nommées (hors entités XML) par des références numériques.
    static func toNumeric(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return pattern.replace(in: s) { groups in
            let name = groups[1]
            if ["amp", "lt", "gt", "quot", "apos"].contains(name) { return groups[0] }
            if let code = table[name] { return "&#\(code);" }
            return "&amp;\(name);"
        }
    }

    /// Décode toutes les entités vers du texte brut.
    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = toNumeric(s)
        out = out.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
        let numeric = try! NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);")
        out = numeric.replace(in: out) { g in
            let value = g[1].isEmpty ? Int(g[2]) : Int(g[2], radix: 16)
            guard let v = value, let scalar = Unicode.Scalar(v) else { return "" }
            return String(Character(scalar))
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}

extension NSRegularExpression {
    /// Remplacement avec une fermeture recevant les groupes capturés (groupe 0 = tout).
    func replace(in s: String, _ transform: ([String]) -> String) -> String {
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += transform(groups)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    func firstGroups(in s: String) -> [String]? {
        let ns = s as NSString
        guard let m = firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map {
            let r = m.range(at: $0)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

extension XMLElement {
    /// Enfants directs par nom local (sans préfixe d'espace de noms).
    func children(named local: String) -> [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == local }
    }

    func firstChild(named local: String) -> XMLElement? {
        children(named: local).first
    }

    /// Descendants par nom local, en ordre de document.
    func descendants(named local: String) -> [XMLElement] {
        var out: [XMLElement] = []
        for case let el as XMLElement in children ?? [] {
            if el.localName == local { out.append(el) }
            out += el.descendants(named: local)
        }
        return out
    }

    /// Valeur d'attribut par nom local (ignore le préfixe : `opf:role`, `xlink:href`…).
    func attr(_ local: String) -> String? {
        if let v = attribute(forName: local)?.stringValue { return v }
        return attributes?.first { $0.localName == local }?.stringValue
    }

    func setAttr(_ name: String, _ value: String) {
        if let a = attribute(forName: name) {
            a.stringValue = value
        } else {
            addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
        }
    }

    var textContent: String {
        (stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum XMLLoader {
    /// Analyse un document XML/XHTML ; repli sur le mode « tidy HTML » si le XML est invalide.
    static func document(_ data: Data) throws -> XMLDocument {
        let text = String(decoding: data, as: UTF8.self)
        let cleaned = HTMLEntities.toNumeric(text)
        if let doc = try? XMLDocument(xmlString: cleaned, options: [.nodePreserveWhitespace]) {
            return doc
        }
        return try XMLDocument(xmlString: cleaned, options: [.documentTidyHTML, .nodePreserveWhitespace])
    }
}
