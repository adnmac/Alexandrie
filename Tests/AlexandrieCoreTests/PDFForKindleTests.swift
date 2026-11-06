import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import AlexandrieCore

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
        let content = try #require(PDFCrop.contentBox(of: document))
        let firstPage = try #require(document.page(at: 0))
        let ink = try #require(PDFCrop.inkBox(of: firstPage))
        #expect(content.contains(ink))
        #expect(content.width < 420 * 0.9 && content.height < 595 * 0.5)

        try PDFCrop.write(input, to: output, edits: MetadataEdits(title: "Titre corrigé", authors: ["Claire Morel"]))
        let cropped = try #require(PDFDocument(url: output))
        let page = try #require(cropped.page(at: 2))
        #expect(page.bounds(for: .mediaBox).width < 420 && page.bounds(for: .mediaBox).height < 595)
        #expect(page.string?.contains("brume couvrait") == true)
        #expect(cropped.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Titre corrigé")
        #expect(try Data(contentsOf: input) == original)
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
