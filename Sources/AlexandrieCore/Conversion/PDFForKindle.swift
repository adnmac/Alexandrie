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
        case .asIs: "Tel quel"
        case .cropped: "Marges rognées"
        case .reflowable: "Texte redimensionnable"
        }
    }

    /// Ce que la fiche explique sous le choix.
    public var explanation: String {
        switch self {
        case .asIs: "La Kindle reçoit le PDF d'origine, page par page."
        case .cropped: "Les marges blanches sont retirées : le texte paraît plus grand. Le fichier d'origine n'est pas modifié."
        case .reflowable: "Le texte devient un livre Kindle dont vous réglez la taille. Images, tableaux et colonnes peuvent se perdre."
        }
    }

    /// Choix possibles : sans texte (PDF scanné), pas de texte redimensionnable.
    public static func available(hasText: Bool) -> [PDFKindleMode] {
        hasText ? allCases : [.asIs, .cropped]
    }
}

// MARK: - Rognage (S-064)

public enum PDFCrop {
    /// Marge gardée autour du contenu, en points.
    static let padding: CGFloat = 6

    /// Cadre commun du contenu visible (repère de la page), calculé sur un échantillon de pages.
    /// Les pages pleine page (couverture, illustration) sont ignorées. Nil : rien à rogner.
    public static func contentBox(of document: PDFDocument, samples: Int = 16) -> CGRect? {
        guard document.pageCount > 0, let first = document.page(at: 0) else { return nil }
        let pageBox = first.bounds(for: .mediaBox)
        let step = max(1, document.pageCount / samples)
        var union: CGRect?
        for index in stride(from: 0, to: document.pageCount, by: step) {
            guard let page = document.page(at: index), let box = inkBox(of: page) else { continue }
            // Page presque pleine : une image, pas du texte ; elle élargirait le cadre de toutes les pages.
            if box.width * box.height > pageBox.width * pageBox.height * 0.9 { continue }
            union = union.map { $0.union(box) } ?? box
        }
        guard let content = union?.insetBy(dx: -padding, dy: -padding).intersection(pageBox),
              content.width * content.height < pageBox.width * pageBox.height * 0.95 else { return nil }
        return content.integral
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
        guard let document = PDFDocument(url: input) else { throw BookError.unreadable("PDF invalide") }
        if let content = contentBox(of: document) {
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let crop = content.intersection(page.bounds(for: .mediaBox))
                guard !crop.isEmpty else { continue }
                page.setBounds(crop, for: .mediaBox)
                page.setBounds(crop, for: .cropBox)
            }
        }
        PDFReflow.applyAttributes(edits, to: document)
        guard document.write(to: output) else { throw BookError.conversionFailed("écriture du PDF rogné") }
    }
}

// MARK: - Texte redimensionnable (S-065)

public enum PDFReflow {
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
            let endsSentence = line.last.map { ".!?…:»\"”)".contains($0) } ?? false
            if endsSentence && Double(line.count) < Double(typical) * 0.8 { flush() }
        }
        flush()
        return paragraphs
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
                    starts.append((item.label ?? "Chapitre \(starts.count + 1)", index))
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
        guard let document = PDFDocument(url: input) else { throw BookError.unreadable("PDF invalide") }
        guard hasText(input) else { throw BookError.unsupported("ce PDF ne contient pas de texte") }
        var meta = BookMetadata(title: edits.title, authors: edits.authors, language: edits.language ?? "fr")
        meta.apply(edits)
        var epub = EPUBBuilder(metadata: meta)
        for (n, chapter) in chapters(of: document, title: edits.title).enumerated() {
            let texts = chapter.pages.compactMap { document.page(at: $0)?.string }
            let body = paragraphs(pages: texts).map { "<p>\(escape($0))</p>" }.joined(separator: "\n")
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

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
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
