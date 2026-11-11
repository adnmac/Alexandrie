import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// Ce que la Kindle reçoit pour un PDF (fiche > « Sur la Kindle », S-064 et S-065).
public enum PDFKindleMode: String, Codable, CaseIterable, Sendable {
    /// Le fichier d'origine.
    case asIs
    /// Copie aux marges blanches retirées : le texte paraît plus grand.
    case cropped
    /// Texte extrait en livre Kindle (AZW3) dont on règle la taille du texte.
    case reflowable

    public var label: String {
        switch self {
        case .asIs: String(localized: "Tel quel")
        case .cropped: String(localized: "Marges rognées")
        case .reflowable: String(localized: "Texte redimensionnable")
        }
    }

    /// Ce que la fiche explique sous le choix.
    public var explanation: String {
        switch self {
        case .asIs: String(localized: "La Kindle reçoit le PDF d'origine, page par page.")
        case .cropped: String(localized: "Les marges blanches sont retirées : le texte paraît plus grand. Le fichier d'origine n'est pas modifié.")
        case .reflowable: String(localized: "Le texte devient un livre Kindle dont vous réglez la taille. Images, tableaux et colonnes peuvent se perdre.")
        }
    }

    /// Choix possibles : sans texte (PDF scanné), pas de texte redimensionnable.
    public static func available(hasText: Bool) -> [PDFKindleMode] {
        hasText ? allCases : [.asIs, .cropped]
    }
}

// MARK: - Rognage (S-064)

public enum PDFCrop {
    /// Version du calcul : la changer refait les copies rognées déjà en cache.
    public static let version = 2
    /// Marge gardée autour du contenu, en points.
    static let padding: CGFloat = 6

    /// Cadres rognés, un par page : même taille partout, pour que le texte garde sa taille d'une page à
    /// l'autre, et centrés sur le contenu, pour des marges égales des deux côtés. Une page peu remplie
    /// (fin de chapitre) se cale sur les pages pleines du même côté (pair ou impair) au lieu d'être centrée.
    /// Les pages pleine page (couverture, illustration) ne comptent pas. Nil : rien à rogner.
    public static func cropBoxes(of document: PDFDocument) -> [CGRect]? {
        guard document.pageCount > 0, let first = document.page(at: 0) else { return nil }
        let pageBox = first.bounds(for: .mediaBox)
        let pages = (0..<document.pageCount).map { document.page(at: $0) }
        let inks: [CGRect?] = pages.map { page in
            guard let page, let box = inkBox(of: page) else { return nil }
            // Page presque pleine : une image, pas du texte ; elle agrandirait le cadre de toutes les pages.
            return box.width * box.height > pageBox.width * pageBox.height * 0.9 ? nil : box
        }
        let text = inks.compactMap { $0 }
        guard let maxWidth = text.map(\.width).max(), let maxHeight = text.map(\.height).max() else { return nil }
        let size = CGSize(width: min(pageBox.width, maxWidth + 2 * padding), height: min(pageBox.height, maxHeight + 2 * padding))
        guard size.width * size.height < pageBox.width * pageBox.height * 0.95 else { return nil }

        let isFull: (CGRect) -> Bool = { $0.width >= maxWidth * 0.8 && $0.height >= maxHeight * 0.8 }
        // Position habituelle du texte, par côté : centre médian des pages pleines, sans la première
        // (souvent une page de titre) quand il y en a d'autres.
        func reference(parity: Int) -> CGPoint? {
            let full = inks.enumerated().compactMap { i, ink in ink.flatMap { i % 2 == parity && isFull($0) ? (i, $0) : nil } }
            let body = full.count > 1 ? full.filter { $0.0 > 0 }.map(\.1) : full.map(\.1)
            guard !body.isEmpty else { return nil }
            func median(_ values: [CGFloat]) -> CGFloat { values.sorted()[(values.count - 1) / 2] }
            return CGPoint(x: median(body.map(\.midX)), y: median(body.map(\.midY)))
        }
        let references = [reference(parity: 0), reference(parity: 1)]
        return pages.enumerated().map { i, page in
            let media = page?.bounds(for: .mediaBox) ?? pageBox
            let anchor = inks[i].flatMap { isFull($0) ? CGPoint(x: $0.midX, y: $0.midY) : nil }
                ?? references[i % 2] ?? references[1 - i % 2] ?? CGPoint(x: media.midX, y: media.midY)
            let x = min(max(anchor.x - size.width / 2, media.minX), media.maxX - size.width)
            let y = min(max(anchor.y - size.height / 2, media.minY), media.maxY - size.height)
            return CGRect(x: x.rounded(), y: y.rounded(), width: size.width.rounded(), height: size.height.rounded())
                .intersection(media)
        }
    }

    /// Cadre des pixels non blancs d'une page, rendue à 72 points par pouce, en points de la page.
    static func inkBox(of page: PDFPage) -> CGRect? {
        let box = page.bounds(for: .mediaBox)
        let width = Int(box.width.rounded(.up)), height = Int(box.height.rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        page.draw(with: .mediaBox, to: context)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for row in 0..<height {
            let line = data + row * context.bytesPerRow
            for col in 0..<width where line[col] < 235 {
                minX = min(minX, col); maxX = max(maxX, col)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard maxX >= 0 else { return nil }
        // Ligne 0 du tampon = haut de la page ; le repère PDF part du bas.
        return CGRect(x: box.minX + CGFloat(minX), y: box.minY + CGFloat(height - 1 - maxY),
                      width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    }

    /// Écrit une copie rognée (l'original n'est jamais modifié), avec les informations corrigées.
    public static func write(_ input: URL, to output: URL, edits: MetadataEdits?) throws {
        guard let document = PDFDocument(url: input) else { throw BookError.unreadable(String(localized: "PDF invalide")) }
        if let boxes = cropBoxes(of: document) {
            for (index, crop) in boxes.enumerated() where !crop.isEmpty {
                guard let page = document.page(at: index) else { continue }
                page.setBounds(crop, for: .mediaBox)
                page.setBounds(crop, for: .cropBox)
            }
        }
        PDFReflow.applyAttributes(edits, to: document)
        guard document.write(to: output) else { throw BookError.conversionFailed(String(localized: "écriture du PDF rogné")) }
    }
}

// MARK: - Texte redimensionnable (S-065)

public enum PDFReflow {
    /// Version de l'extraction : la changer refait les livres déjà convertis en cache.
    public static let version = 2

    /// Le PDF contient-il du texte (et non des pages scannées) ? Lu sur les premières pages.
    public static func hasText(_ url: URL) -> Bool {
        guard let document = PDFDocument(url: url) else { return false }
        var characters = 0
        for index in 0..<min(document.pageCount, 12) {
            characters += document.page(at: index)?.string?.filter { $0.isLetter }.count ?? 0
            if characters >= 200 { return true }
        }
        return false
    }

    /// Paragraphes du texte de pages successives : lignes recollées, coupures de mots retirées,
    /// numéros de page et en-têtes ou pieds répétés enlevés.
    public static func paragraphs(pages: [String]) -> [String] {
        let pages = pages.map { $0.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) } }
        let repeated = repeatedMargins(pages)
        var lines: [String] = []
        for page in pages {
            let content = page.enumerated().filter { i, line in
                !isPageNumber(line) && !(isMargin(i, in: page) && repeated.contains(marginKey(line)))
            }.map(\.element)
            // Fin de page : aucune ligne vide forcée, un paragraphe peut continuer sur la suivante.
            lines += content.drop { $0.isEmpty }
        }
        lines = mergingPunctuation(lines)
        let lengths = lines.filter { !$0.isEmpty }.map(\.count).sorted()
        // Longueur d'une ligne pleine : les fins de paragraphe, plus courtes, ne la font pas baisser.
        let typical = lengths.isEmpty ? 0 : lengths[min(lengths.count - 1, lengths.count * 4 / 5)]
        var paragraphs: [String] = [], current = ""
        func flush() {
            let p = current.trimmingCharacters(in: .whitespaces)
            if !p.isEmpty { paragraphs.append(p) }
            current = ""
        }
        for line in lines {
            if line.isEmpty { flush(); continue }
            if current.isEmpty {
                current = line
            } else if current.hasSuffix("-"), current.dropLast().last?.isLetter == true, line.first?.isLowercase == true {
                current = String(current.dropLast()) + line
            } else {
                current += " " + line
            }
            let endsSentence = lastVisible(line).map { ".!?…:»\"”)".contains($0) } ?? false
            if endsSentence && Double(line.count) < Double(typical) * 0.8 { flush() }
        }
        flush()
        return paragraphs
    }

    /// Ponctuation isolée par l'extraction (« » », « . », « ; quant à… ») recollée à la ligne d'avant,
    /// guillemet ouvrant en fin de ligne recollé à la suivante.
    static func mergingPunctuation(_ lines: [String]) -> [String] {
        var merged: [String] = []
        for line in lines {
            guard let last = merged.last, !last.isEmpty, let first = line.first else {
                merged.append(line)
                continue
            }
            if ".,)]…".contains(first) || line.hasPrefix(noteOpen) {
                merged[merged.count - 1] = last + line
            } else if "»;:!?”".contains(first) || last.hasSuffix("«") {
                merged[merged.count - 1] = last + " " + line
            } else {
                merged.append(line)
            }
        }
        return merged
    }

    /// Dernier caractère lu, appel de note en exposant mis à part.
    static func lastVisible(_ line: String) -> Character? {
        line.replacingOccurrences(of: "\(noteOpen)[0-9]+\(noteClose)$", with: "", options: .regularExpression).last
    }

    /// Notes de bas de page : une note commence par son numéro.
    static func noteParagraphs(_ lines: [String]) -> [String] {
        var notes: [String] = []
        for line in mergingPunctuation(lines) where !line.isEmpty {
            if line.range(of: #"^[0-9]+[.\s]"#, options: .regularExpression) != nil || notes.isEmpty {
                notes.append(line)
            } else if notes[notes.count - 1].hasSuffix("-"), line.first?.isLowercase == true {
                notes[notes.count - 1] = String(notes[notes.count - 1].dropLast()) + line
            } else {
                notes[notes.count - 1] += " " + line
            }
        }
        return notes
    }

    // MARK: Texte d'une page, d'après la taille des caractères

    /// Marques d'un appel de note en exposant, remplacées par <sup> dans le livre produit.
    static let noteOpen = "\u{E000}", noteClose = "\u{E001}"

    /// Une page : texte courant (en-tête courant retiré, appels de note marqués) et notes de bas de page.
    struct PageText: Equatable {
        var body: [String]
        var notes: [String]
    }

    /// Taille du texte courant : la plus fréquente, comptée en caractères sur un échantillon de pages.
    static func bodySize(of document: PDFDocument) -> CGFloat? {
        var weights: [Int: Int] = [:]
        let step = max(1, document.pageCount / 24)
        for index in stride(from: 0, to: document.pageCount, by: step) {
            guard let text = document.page(at: index)?.attributedString else { continue }
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard let font = value as? NSFont else { return }
                weights[Int((font.pointSize * 2).rounded()), default: 0] += range.length
            }
        }
        return weights.max { $0.value < $1.value }.map { CGFloat($0.key) / 2 }
    }

    /// Lignes d'une page avec la taille dominante de chacune ; les chiffres en très petit corps
    /// deviennent des appels de note (recollés à la ligne d'avant s'ils ouvrent une ligne).
    static func lines(of text: NSAttributedString, bodySize: CGFloat) -> [(text: String, size: CGFloat)] {
        let string = text.string as NSString
        var lines: [(text: String, size: CGFloat)] = []
        var location = 0
        while location < string.length {
            let range = string.lineRange(for: NSRange(location: location, length: 0))
            var line = "", weights: [CGFloat: Int] = [:]
            text.enumerateAttribute(.font, in: range) { value, run, _ in
                let size = (value as? NSFont)?.pointSize ?? bodySize
                let piece = string.substring(with: run)
                let digits = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if size < bodySize * 0.75, !digits.isEmpty, digits.allSatisfy(\.isNumber) {
                    line += noteOpen + digits + noteClose
                } else {
                    line += piece
                    weights[size, default: 0] += piece.trimmingCharacters(in: .whitespacesAndNewlines).count
                }
            }
            lines.append((line.trimmingCharacters(in: .whitespacesAndNewlines), weights.max { $0.value < $1.value }?.key ?? bodySize))
            location = NSMaxRange(range)
        }
        return lines
    }

    /// Sépare l'en-tête courant (première ligne en plus petit corps), le texte et les notes
    /// (lignes en plus petit corps en bas de page, au-dessus du numéro de page).
    static func pageText(_ lines: [(text: String, size: CGFloat)], bodySize: CGFloat) -> PageText {
        let small: (CGFloat) -> Bool = { $0 < bodySize * 0.9 }
        var start = 0
        while start < lines.count, lines[start].text.isEmpty { start += 1 }
        if start < lines.count, small(lines[start].size) { start += 1 }
        var end = lines.count
        while end > start, lines[end - 1].text.isEmpty || isPageNumber(lines[end - 1].text) { end -= 1 }
        var noteStart = end
        while noteStart > start, lines[noteStart - 1].text.isEmpty || small(lines[noteStart - 1].size) { noteStart -= 1 }
        return PageText(body: lines[start..<noteStart].map(\.text), notes: lines[noteStart..<end].map(\.text).filter { !$0.isEmpty })
    }

    /// Lignes qui reviennent en haut ou en bas de la plupart des pages (titre courant, nom de l'auteur).
    static func repeatedMargins(_ pages: [[String]]) -> Set<String> {
        guard pages.count >= 3 else { return [] }
        var counts: [String: Int] = [:]
        for page in pages {
            let keys = Set(page.indices.filter { isMargin($0, in: page) && !page[$0].isEmpty }.map { marginKey(page[$0]) })
            for key in keys { counts[key, default: 0] += 1 }
        }
        let threshold = max(3, pages.count / 2)
        return Set(counts.filter { $0.value >= threshold }.keys)
    }

    /// Deux premières et deux dernières lignes non vides d'une page.
    static func isMargin(_ index: Int, in page: [String]) -> Bool {
        let filled = page.indices.filter { !page[$0].isEmpty }
        return filled.prefix(2).contains(index) || filled.suffix(2).contains(index)
    }

    /// Numéros remplacés : « Chapitre 3 — 41 » et « Chapitre 3 — 42 » sont le même en-tête.
    static func marginKey(_ line: String) -> String {
        line.lowercased().replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression)
    }

    static func isPageNumber(_ line: String) -> Bool {
        line.count <= 12 && line.range(of: #"^[-–—\s]*([0-9]+|[ivxlcdm]+|page\s+[0-9]+)[-–—\s]*$"#,
                                       options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Chapitres : la table du PDF quand elle existe, sinon un seul chapitre au titre du livre.
    static func chapters(of document: PDFDocument, title: String) -> [(title: String, pages: Range<Int>)] {
        var starts: [(String, Int)] = []
        if let root = document.outlineRoot {
            for i in 0..<root.numberOfChildren {
                guard let item = root.child(at: i), let page = item.destination?.page else { continue }
                let index = document.index(for: page)
                if index != NSNotFound, starts.last.map({ $0.1 < index }) ?? true {
                    starts.append((item.label ?? String(localized: "Chapitre \(starts.count + 1)"), index))
                }
            }
        }
        guard !starts.isEmpty else { return [(title, 0..<document.pageCount)] }
        if starts[0].1 > 0 { starts.insert((title, 0), at: 0) }
        return starts.enumerated().map { i, start in
            (start.0, start.1..<(i + 1 < starts.count ? starts[i + 1].1 : document.pageCount))
        }
    }

    /// EPUB du texte du PDF (un fichier par chapitre), à convertir ensuite en AZW3.
    public static func writeEPUB(_ input: URL, to output: URL, edits: MetadataEdits) throws {
        guard let document = PDFDocument(url: input) else { throw BookError.unreadable(String(localized: "PDF invalide")) }
        guard hasText(input) else { throw BookError.unsupported(String(localized: "ce PDF ne contient pas de texte")) }
        var meta = BookMetadata(title: edits.title, authors: edits.authors, language: edits.language ?? "fr")
        meta.apply(edits)
        var epub = EPUBBuilder(metadata: meta)
        let size = bodySize(of: document)
        for (n, chapter) in chapters(of: document, title: edits.title).enumerated() {
            var texts: [String] = [], notes: [String] = []
            for index in chapter.pages {
                guard let page = document.page(at: index) else { continue }
                if let size, let attributed = page.attributedString {
                    let text = pageText(lines(of: attributed, bodySize: size), bodySize: size)
                    texts.append(text.body.joined(separator: "\n"))
                    notes += text.notes
                } else {
                    texts.append(page.string ?? "")
                }
            }
            var body = paragraphs(pages: texts).map { "<p>\(escape($0))</p>" }.joined(separator: "\n")
            let noteList = noteParagraphs(notes)
            if !noteList.isEmpty {
                body += "\n<h3>Notes</h3>\n" + noteList.map { "<p class=\"note\">\(escape($0))</p>" }.joined(separator: "\n")
            }
            let path = "Text/chapter\(n + 1).xhtml"
            let html = """
                <?xml version="1.0" encoding="utf-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(escape(meta.language ?? "fr"))">
                <head><title>\(escape(chapter.title))</title></head>
                <body><h2>\(escape(chapter.title))</h2>
                \(body)
                </body>
                </html>
                """
            epub.add(path, mediaType: "application/xhtml+xml", data: Data(html.utf8), inSpine: true)
            epub.toc.append(TOCNode(title: chapter.title, path: path))
        }
        try epub.write(to: output)
    }

    /// Texte sûr pour XHTML : caractères interdits en XML retirés (le PDF en contient parfois,
    /// comme U+0007), appels de note en exposant.
    static func escape(_ s: String) -> String {
        var allowed = String.UnicodeScalarView()
        for u in s.unicodeScalars where u == "\t" || u == "\n" || u == "\r" || (0x20...0xD7FF).contains(u.value)
            || (0xE000...0xFFFD).contains(u.value) || u.value >= 0x10000 {
            allowed.append(u)
        }
        return String(allowed).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: noteOpen, with: "<sup>").replacingOccurrences(of: noteClose, with: "</sup>")
    }

    /// Titre et auteurs corrigés, lus par la Kindle dans le PDF.
    static func applyAttributes(_ edits: MetadataEdits?, to document: PDFDocument) {
        guard let edits else { return }
        var attributes = document.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.titleAttribute] = edits.title
        if !edits.authors.isEmpty { attributes[PDFDocumentAttribute.authorAttribute] = edits.authors.joined(separator: ", ") }
        document.documentAttributes = attributes
    }
}
