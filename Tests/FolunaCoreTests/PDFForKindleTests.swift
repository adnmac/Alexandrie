import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import FolunaCore

/// PDF de test : pages A5 (420 × 595 points), lignes de texte posées à gauche à partir de `top`.
func makePDF(pages: [[String]], at url: URL, left: CGFloat = 100, top: CGFloat = 450, drawText: Bool = true) throws {
    var box = CGRect(x: 0, y: 0, width: 420, height: 595)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw BookError.conversionFailed("PDF de test") }
    let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
    for lines in pages {
        context.beginPDFPage(nil)
        if drawText {
            for (i, line) in lines.enumerated() {
                let attributed = NSAttributedString(string: line, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
                context.textPosition = CGPoint(x: left, y: top - CGFloat(i) * 14)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
        } else {
            // Page « scannée » : de l'encre, aucun texte.
            context.setFillColor(gray: 0.2, alpha: 1)
            context.fill(CGRect(x: left, y: top - 200, width: 200, height: 200))
        }
        context.endPDFPage()
    }
    context.closePDF()
}

@Suite struct PDFForKindleTests {
    let lines = ["Les Heures lentes", "Le matin, la brume couvrait encore le fleuve et les quais.",
                 "Personne ne parlait ; on attendait que le soleil passe les toits.", "Fin du passage."]

    @Test func cropKeepsAllTextAndRemovesMargins() throws {
        let dir = tempDirectory()
        let input = dir.appendingPathComponent("marges.pdf"), output = dir.appendingPathComponent("rogne.pdf")
        try makePDF(pages: Array(repeating: lines, count: 4), at: input)
        let original = try Data(contentsOf: input)

        let document = try #require(PDFDocument(url: input))
        let boxes = try #require(PDFCrop.cropBoxes(of: document))
        let firstPage = try #require(document.page(at: 0))
        let ink = try #require(PDFCrop.inkBox(of: firstPage))
        #expect(boxes.count == 4)
        #expect(boxes[0].contains(ink))
        #expect(boxes[0].width < 420 * 0.9 && boxes[0].height < 595 * 0.5)

        try PDFCrop.write(input, to: output, edits: MetadataEdits(title: "Titre corrigé", authors: ["Claire Morel"]))
        let cropped = try #require(PDFDocument(url: output))
        let page = try #require(cropped.page(at: 2))
        #expect(page.bounds(for: .mediaBox).width < 420 && page.bounds(for: .mediaBox).height < 595)
        #expect(page.string?.contains("brume couvrait") == true)
        #expect(cropped.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Titre corrigé")
        #expect(try Data(contentsOf: input) == original)
    }

    /// Cas réel : une page de titre plus large que les autres ne doit pas décentrer les pages suivantes.
    @Test func croppedPagesKeepEvenMargins() throws {
        let input = tempDirectory().appendingPathComponent("titre.pdf")
        var box = CGRect(x: 0, y: 0, width: 420, height: 595)
        let context = try #require(CGContext(input as CFURL, mediaBox: &box, nil))
        // Page 1 : titre large qui commence plus à gauche et plus haut ; pages 2 à 4 : texte ;
        // page 5 : fin de chapitre, deux lignes seulement.
        let blocks: [(x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat)] = [
            (50, 560, 320, 500), (80, 520, 260, 440), (80, 520, 260, 440), (80, 520, 260, 440), (80, 520, 120, 30),
        ]
        for b in blocks {
            context.beginPDFPage(nil)
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: b.x, y: b.top - b.height, width: b.width, height: b.height))
            context.endPDFPage()
        }
        context.closePDF()

        let document = try #require(PDFDocument(url: input))
        let boxes = try #require(PDFCrop.cropBoxes(of: document))
        #expect(boxes.allSatisfy { $0.size == boxes[0].size }, "même taille partout : \(boxes.map(\.size))")
        for i in 1...3 {
            let left = 80 - boxes[i].minX, right = boxes[i].maxX - 340
            let bottom = 80 - boxes[i].minY, top = boxes[i].maxY - 520
            #expect(abs(left - right) <= 1 && abs(top - bottom) <= 1, "page \(i + 1) : \(boxes[i])")
        }
        // La fin de chapitre reste là où commence le texte des pages pleines du même côté.
        #expect(boxes[4] == boxes[2], "\(boxes[4]) / \(boxes[2])")
    }

    @Test func paragraphsJoinLinesAndDropPageFurniture() {
        // Comme dans un vrai livre : la dernière ligne d'un paragraphe est courte.
        let pages = [
            "Les Heures lentes\nLe matin, la brume couvrait encore le fleuve et les quais de la\nville, depuis l'été.\nPersonne ne parlait.\nOn attendait que le soleil passe les toits, selon une tradi-\n12",
            "Les Heures lentes\ntion très ancienne que les bateliers gardaient entre eux et\nleurs enfants.\nLe soir venait vite.\n13",
            "Les Heures lentes\nLe fleuve montait doucement sous les arches du vieux pont de\npierre.\nIl pleuvait.\n14",
        ]
        let result = PDFReflow.paragraphs(pages: pages)
        #expect(result == [
            "Le matin, la brume couvrait encore le fleuve et les quais de la ville, depuis l'été.",
            "Personne ne parlait.",
            "On attendait que le soleil passe les toits, selon une tradition très ancienne que les bateliers gardaient entre eux et leurs enfants.",
            "Le soir venait vite.",
            "Le fleuve montait doucement sous les arches du vieux pont de pierre.",
            "Il pleuvait.",
        ])
    }

    /// Cas réel (essai de 316 pages) : texte en 12,2 pt, en-tête courant en 10,3, notes en 9,8,
    /// appels de note en exposant, ponctuation isolée par l'extraction, caractère de contrôle U+0007.
    @Test func pageFurnitureIsSortedBySize() {
        let o = PDFReflow.noteOpen, c = PDFReflow.noteClose
        let lines: [(text: String, size: CGFloat)] = [
            ("le problème à trois corps du capitalisme", 10.3),
            ("conduit à ouvrir de nouveaux fronts, en une série de crises « qui s’entre-stimulent", 12.2),
            ("les unes les autres", 12.2), ("»", 12.2),
            ("\(o)6\(c). Le principe de la « polycrise » se résume ainsi, sans", 12.2),
            ("détacher un problème numéro un\(o)7\(c)", 12.2), (".", 12.2),
            ("5 Adam Tooze, « Welcome to the world of polycrisis », Financial", 9.8),
            ("Times, 28 octobre 2022.", 9.8), ("6 Edgar Morin, Terre Patrie, Seuil, 1993.", 9.8),
            ("16", 10.5),
        ]
        let page = PDFReflow.pageText(lines, bodySize: 12.2)
        #expect(!page.body.contains("le problème à trois corps du capitalisme"))
        #expect(page.notes.count == 3)
        #expect(PDFReflow.noteParagraphs(page.notes) == [
            "5 Adam Tooze, « Welcome to the world of polycrisis », Financial Times, 28 octobre 2022.",
            "6 Edgar Morin, Terre Patrie, Seuil, 1993.",
        ])
        let paragraph = PDFReflow.paragraphs(pages: [page.body.joined(separator: "\n")])
        #expect(paragraph == ["conduit à ouvrir de nouveaux fronts, en une série de crises « qui s’entre-stimulent les unes les autres »\(o)6\(c). Le principe de la « polycrise » se résume ainsi, sans détacher un problème numéro un\(o)7\(c)."])
        #expect(PDFReflow.escape("autres\u{7} »\(o)6\(c) & <fin>") == "autres »<sup>6</sup> &amp; &lt;fin&gt;")
    }

    @Test func pageNumbersAreRecognized() {
        for line in ["12", "- 12 -", "xiv", "Page 3"] { #expect(PDFReflow.isPageNumber(line), "\(line)") }
        for line in ["Il pleuvait.", "1984 fut une année étrange"] { #expect(!PDFReflow.isPageNumber(line), "\(line)") }
    }

    @Test func textPDFBecomesAnAZW3() throws {
        let dir = tempDirectory()
        let input = dir.appendingPathComponent("texte.pdf")
        let epub = dir.appendingPathComponent("texte.epub"), azw3 = dir.appendingPathComponent("texte.azw3")
        try makePDF(pages: Array(repeating: lines + lines + lines, count: 3), at: input)
        #expect(PDFReflow.hasText(input))

        let edits = MetadataEdits(title: "Les Heures lentes", authors: ["Claire Morel"], language: "fr")
        try PDFReflow.writeEPUB(input, to: epub, edits: edits)
        try EPUBToAZW3.convert(input: epub, output: azw3, edits: edits, asin: EPUBToAZW3.makeASIN())
        let meta = try MobiBook(url: azw3).metadata()
        #expect(meta.title == "Les Heures lentes")
        #expect(meta.authors == ["Claire Morel"])
    }

    @Test func scannedPDFHasNoText() throws {
        let input = tempDirectory().appendingPathComponent("scan.pdf")
        try makePDF(pages: Array(repeating: [], count: 3), at: input, drawText: false)
        #expect(!PDFReflow.hasText(input))
        #expect(throws: BookError.self) {
            try PDFReflow.writeEPUB(input, to: tempDirectory().appendingPathComponent("x.epub"), edits: MetadataEdits(title: "Scan", authors: []))
        }
    }
}
