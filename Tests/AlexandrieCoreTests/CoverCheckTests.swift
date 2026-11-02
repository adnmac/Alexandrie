import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AlexandrieCore

@Suite struct CoverCheckTests {
    // Textes réellement lus sur des couvertures de la bibliothèque.
    let piketty = CoverText(lines: ["THOMAS", "PIKETTY", "CAPITAL", "ET", "IDÉOLOGIE", "SEUIL"])
    let leon = CoverText(lines: ["POINTS", "DONNA", "LEON", "LE PRIX", "DE LA CHAIR", "UNE ENQUÊTE DU COMMISSAIRE BRUNETTI"])
    let strauss = CoverText(lines: ["Raphaëlle Bacqué", "Ariane Chemin", "Les Strauss-Kahn", "Albin Michel"])

    func diff(_ f: CatalogField, _ current: String?, _ proposed: String) -> CatalogDifference {
        CatalogDifference(field: f, current: current, proposed: proposed)
    }

    @Test func publisherContradictedByCover() {
        let book = MetadataEdits(title: "Capital et idéologie", authors: ["Thomas Piketty"], publisher: "Le Seuil")
        #expect(CoverCheck.verdict(for: diff(.publisher, "Le Seuil", "Éditions Points"), book: book, cover: piketty,
                                   publishers: []) == .contradicted("Le Seuil"))
        // Sans éditeur actuel, le nom lu vient de la liste des éditeurs connus.
        let noPublisher = MetadataEdits(title: "Les Strauss-Kahn", authors: ["Raphaëlle Bacqué"])
        #expect(CoverCheck.verdict(for: diff(.publisher, nil, "Éd. Points"), book: noPublisher, cover: strauss,
                                   publishers: ["Michel Lafon"]) == .contradicted("Albin Michel"))
    }

    @Test func publisherConfirmedByCover() {
        let book = MetadataEdits(title: "Le prix de la chair", authors: ["Donna Leon"])
        #expect(CoverCheck.verdict(for: diff(.publisher, nil, "Éditions Points"), book: book, cover: leon,
                                   publishers: []) == .confirmed)
    }

    @Test func publisherNameInsideTitleProvesNothing() {
        let cover = CoverText(lines: ["Jean Dupont", "AU SEUIL", "DE LA NUIT"])
        let book = MetadataEdits(title: "Au seuil de la nuit", authors: ["Jean Dupont"])
        #expect(CoverCheck.verdict(for: diff(.publisher, nil, "Gallimard"), book: book, cover: cover, publishers: []) == nil)
    }

    @Test func titleAndAuthors() {
        let book = MetadataEdits(title: "Capital et idéologie", authors: ["Piketty, Thomas"])
        #expect(CoverCheck.verdict(for: diff(.title, book.title, "Capital et idéologie : essai"), book: book,
                                   cover: piketty, publishers: []) == .confirmed)
        #expect(CoverCheck.verdict(for: diff(.title, book.title, "Le Capital"), book: book,
                                   cover: piketty, publishers: []) == .contradicted(nil))
        #expect(CoverCheck.verdict(for: diff(.authors, "Piketty, Thomas", "Thomas Piketty"), book: book,
                                   cover: piketty, publishers: []) == .confirmed)
        #expect(CoverCheck.verdict(for: diff(.isbn, nil, "9782021338041"), book: book, cover: piketty, publishers: []) == nil)
    }

    @Test func recognizesTextOnImage() throws {
        let url = temp("png")
        try renderPNG(["Capital", "SEUIL"], to: url)
        let text = try CoverText.recognize(imageAt: url)
        #expect(text.contains("Seuil"))
        #expect(text.contains("capital"))
    }

    func renderPNG(_ lines: [String], to url: URL) throws {
        let (w, h) = (600, 800)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 72, nil)
        for (i, text) in lines.enumerated() {
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)])
            ctx.textPosition = CGPoint(x: 60, y: CGFloat(h - 200 - i * 200))
            CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
