import Foundation
import NaturalLanguage

/// Texte brut (Project Gutenberg, textes libres) : encodage reconnu, paragraphes recollés, chapitres repérés
/// à leur titre (« Chapitre IV », « CHAPTER 2 », « XII »). Titre et auteur : en-tête Gutenberg, sinon le nom
/// du fichier (« Titre - Auteur », comme les copies envoyées par Foluna).
public enum TXTImporter: BookImporter {
    public static let id = "txt"
    public static var formats: [BookFormat] { [.txt] }
    public static var output: ImportOutput { .reflowable }
    public static let version = 1

    /// Pas de signature : un texte ne contient pas d'octet nul (sauf en UTF-16, reconnu à son BOM).
    public static func detect(_ header: Data) -> Bool {
        let b = [UInt8](header.prefix(Importers.headerLength))
        if b.starts(with: [0xFF, 0xFE]) || b.starts(with: [0xFE, 0xFF]) { return true }
        return !b.contains(0)
    }

    public static func document(of url: URL) throws -> ImportedDocument {
        let data = try Data(contentsOf: url)
        guard data.count <= ImportLimits.maxTextSize else { throw ImportLimits.tooLarge }
        guard detect(data) else { throw BookError.unreadable(String(localized: "ce fichier n'est pas du texte")) }
        var text = decode(data).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let gutenberg = GutenbergHeader(text)
        if let body = gutenberg?.body { text = body }

        var meta = BookMetadata(title: url.deletingPathExtension().lastPathComponent)
        if let parsed = titleAndAuthor(fromFilename: meta.title) { (meta.title, meta.authors) = (parsed.title, parsed.authors) }
        if let g = gutenberg {
            if let t = g.title { meta.title = t }
            if !g.authors.isEmpty { meta.authors = g.authors }
            meta.language = g.language
        }
        if meta.language == nil { meta.language = language(of: text) }
        return ImportedDocument(metadata: meta, chapters: chapters(of: paragraphs(text)))
    }

    // MARK: - Encodage

    static func decode(_ data: Data) -> String {
        let b = [UInt8](data.prefix(3))
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if b.starts(with: [0xFF, 0xFE]) { return String(data: data, encoding: .utf16LittleEndian).map { String($0.dropFirst()) } ?? "" }
        if b.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16BigEndian).map { String($0.dropFirst()) } ?? "" }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        var converted: NSString?
        let options: [StringEncodingDetectionOptionsKey: Any] = [
            .suggestedEncodingsKey: [String.Encoding.windowsCP1252.rawValue, String.Encoding.isoLatin1.rawValue,
                                     String.Encoding.macOSRoman.rawValue],
            .allowLossyKey: false,
        ]
        _ = NSString.stringEncoding(for: data, encodingOptions: options, convertedString: &converted, usedLossyConversion: nil)
        return converted.map { $0 as String } ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: - Paragraphes et chapitres

    /// Paragraphes : texte coupé à la main (lignes courtes, paragraphes séparés par une ligne vide, comme au
    /// Project Gutenberg) recollé ; sinon une ligne par paragraphe.
    static func paragraphs(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard isHardWrapped(lines) else { return lines.filter { !$0.isEmpty } }
        var out: [String] = [], current: [String] = []
        func flush() {
            if !current.isEmpty { out.append(current.joined(separator: " ")) }
            current = []
        }
        for line in lines {
            if line.isEmpty {
                flush()
            } else {
                current.append(line)
            }
        }
        flush()
        return out
    }

    /// Lignes coupées à la main : il y a des lignes vides, les lignes pleines sont courtes (moins de 100 caractères
    /// pour 4 lignes sur 5) et souvent suivies d'une autre ligne du même paragraphe.
    static func isHardWrapped(_ lines: [String]) -> Bool {
        let filled = lines.filter { !$0.isEmpty }
        guard filled.count >= 2, filled.count < lines.count else { return false }
        let lengths = filled.map(\.count).sorted()
        let typical = lengths[lengths.count * 4 / 5]
        let continued = zip(lines, lines.dropFirst()).filter { !$0.isEmpty && !$1.isEmpty }.count
        return typical <= 100 && Double(continued) >= Double(filled.count) * 0.2
    }

    /// « Chapitre IV », « CHAPTER 2. The Return », « Livre premier », « Prologue », « XII », « 3. » : un mot de
    /// chapitre suivi d'un numéro (pas « Part of the town »), un prologue ou un épilogue, ou un numéro seul.
    private static let headingPattern = try! NSRegularExpression(
        pattern: #"^(?:(?:chapitre|chapter|chap\.|kapitel|hoofdstuk|cap[ií]tulo|livre|book|buch|boek|libro|partie|part|teil|deel|parte)\s+(?:\d{1,4}|(?-i:[IVXLCDM]{1,8})|premier|première|first|one|eerste|erstes|primero|primera|primo)\b.{0,70}|(?:prologue|prolog|proloog|pr[oó]logo|[ée]pilogue|epilog|epiloog|ep[ií]logo)\b.{0,60}|(?-i:[IVXLCDM]{1,8})\.?|\d{1,3}\.?)$"#,
        options: [.caseInsensitive])

    /// Titre de chapitre : une ligne courte de la forme de `headingPattern`.
    static func isHeading(_ line: String) -> Bool {
        guard line.count <= 80 else { return false }
        return headingPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// Chapitres d'après leurs titres ; sans titre repéré, le texte est découpé en parties de taille raisonnable.
    static func chapters(of paragraphs: [String]) -> [ImportedDocument.Chapter] {
        var chapters: [(title: String?, paragraphs: [String])] = []
        var i = 0
        while i < paragraphs.count {
            let p = paragraphs[i]
            if isHeading(p) {
                var title = p
                // « CHAPITRE IV » suivi d'une ligne courte sans ponctuation finale : son titre (« Le départ »).
                if i + 2 < paragraphs.count {
                    let next = paragraphs[i + 1]
                    if next.count <= 60, !isHeading(next), let last = next.last, !".!?,;:…»\"”".contains(last) {
                        title += " — " + next
                        i += 1
                    }
                }
                chapters.append((title, []))
            } else if chapters.isEmpty {
                chapters.append((nil, [p]))
            } else {
                chapters[chapters.count - 1].paragraphs.append(p)
            }
            i += 1
        }
        // Trop peu de titres pour être des chapitres (un « 1. » égaré) : découpage par taille.
        if chapters.filter({ $0.title != nil }).count < 2 {
            chapters = split(paragraphs)
        }
        return chapters.compactMap { c in
            let heading = c.title.map { "<h2>\(ImportedDocument.xhtml($0))</h2>\n" } ?? ""
            guard c.title != nil || !c.paragraphs.isEmpty else { return nil }
            return ImportedDocument.Chapter(title: c.title, body: heading + ImportedDocument.paragraphs(c.paragraphs))
        }
    }

    /// Parties d'environ 60 000 caractères, coupées entre deux paragraphes.
    static func split(_ paragraphs: [String]) -> [(title: String?, paragraphs: [String])] {
        var parts: [(title: String?, paragraphs: [String])] = [(nil, [])]
        var size = 0
        for p in paragraphs {
            if size > 60_000 {
                parts.append((nil, []))
                size = 0
            }
            parts[parts.count - 1].paragraphs.append(p)
            size += p.count
        }
        return parts
    }

    // MARK: - Informations

    /// « Candide - Voltaire » → titre et auteur. Un nom sans « - » garde le titre tel quel.
    static func titleAndAuthor(fromFilename name: String) -> (title: String, authors: [String])? {
        let parts = name.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], [parts[1]])
    }

    static func language(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(20_000)))
        return recognizer.dominantLanguage.map(\.rawValue)
    }
}

/// En-tête d'un texte du Project Gutenberg : informations, et texte du livre sans la licence.
struct GutenbergHeader {
    var title: String?
    var authors: [String] = []
    var language: String?
    /// Texte entre les marques « *** START OF … *** » et « *** END OF … *** ».
    var body: String?

    init?(_ text: String) {
        guard let start = text.range(of: #"\*{3} ?START OF (THE|THIS) PROJECT GUTENBERG E(BOOK|TEXT)[^\n]*"#,
                                     options: [.regularExpression, .caseInsensitive]) else { return nil }
        let header = text[..<start.lowerBound]
        func field(_ name: String) -> String? {
            guard let r = header.range(of: "(?m)^\(name): *(.+)$", options: .regularExpression) else { return nil }
            let line = header[r]
            return line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        title = field("Title")
        authors = field("Author").map { [$0] } ?? []
        language = field("Language").flatMap(Self.code)
        var rest = text[start.upperBound...]
        if let end = rest.range(of: #"\*{3} ?END OF (THE|THIS) PROJECT GUTENBERG E(BOOK|TEXT)"#,
                                options: [.regularExpression, .caseInsensitive]) {
            rest = rest[..<end.lowerBound]
        }
        body = String(rest)
    }

    /// « French » → « fr ».
    static func code(_ name: String) -> String? {
        let codes = ["english": "en", "french": "fr", "german": "de", "dutch": "nl", "spanish": "es", "italian": "it",
                     "portuguese": "pt", "latin": "la", "finnish": "fi", "swedish": "sv", "danish": "da",
                     "norwegian": "no", "polish": "pl", "russian": "ru", "greek": "el", "hungarian": "hu"]
        return codes[name.lowercased().split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""]
    }
}
