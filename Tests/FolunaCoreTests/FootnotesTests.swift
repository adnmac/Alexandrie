import Foundation
import Testing
@testable import FolunaCore

@Suite struct FootnotesTests {
    func xhtml(_ body: String) -> Data {
        Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><title>Notes</title></head>
            <body>\(body)</body>
            </html>
            """.utf8)
    }

    /// EPUB 3 : la note est un `aside` balisé ; son numéro et son lien de retour ne font pas partie du texte.
    @Test func epub3AsideIsReadWithoutItsNumberAndBackLink() {
        let data = xhtml("""
            <p>Texte<sup><a epub:type="noteref" href="#n1" id="r1">1</a></sup>.</p>
            <aside epub:type="footnote" id="n1"><p><a href="#r1">1.</a> Voir   la <i>première</i>
            édition. <a role="doc-backlink" href="#r1">↩</a></p></aside>
            """)
        #expect(Footnotes.paragraphs(of: "n1", in: data, label: "1") == ["Voir la première édition."])
    }

    /// EPUB 2 : l'identifiant est sur l'ancre au début de la note ; la note est le paragraphe qui la contient.
    @Test func anchorInsideParagraphGivesTheParagraph() {
        let data = xhtml("""
            <p class="note"><a id="note12" href="ch1.xhtml#ref12">[12]</a> Lettre du 3 mars 1871.</p>
            <p class="note"><a id="note13" href="ch1.xhtml#ref13">[13]</a> Autre note.</p>
            """)
        #expect(Footnotes.paragraphs(of: "note12", in: data, label: "12") == ["Lettre du 3 mars 1871."])
        #expect(Footnotes.paragraphs(of: "note13", in: data, label: "[13]") == ["Autre note."])
    }

    /// Note de fin en liste, sur plusieurs paragraphes.
    @Test func endnoteKeepsItsParagraphs() {
        let data = xhtml("""
            <section epub:type="endnotes"><ol>
            <li id="en2" epub:type="endnote"><p>Premier paragraphe.</p><p>Second paragraphe.</p></li>
            </ol></section>
            """)
        #expect(Footnotes.paragraphs(of: "en2", in: data) == ["Premier paragraphe.", "Second paragraphe."])
    }

    @Test func missingAnchorGivesNil() {
        #expect(Footnotes.paragraphs(of: "absente", in: xhtml("<p id='autre'>Texte</p>")) == nil)
    }

    /// HTML négligé (balises non fermées) : la réparation de libxml le rend lisible.
    @Test func sloppyHTMLIsRepaired() {
        let data = Data("<html><body><p id=n5>Note <b>sans fin<p>Suivant</body></html>".utf8)
        #expect(Footnotes.paragraphs(of: "n5", in: data)?.first?.hasPrefix("Note sans fin") == true)
    }

    /// Note dans un autre fichier du livre ; un fichier hors du livre n'est jamais lu.
    @Test func noteIsReadFromItsFileOnlyInsideTheBook() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Text"), withIntermediateDirectories: true)
        let notes = root.appendingPathComponent("Text/notes.xhtml")
        try xhtml("<aside id='n1' epub:type='footnote'><p>1. Une note.</p></aside>").write(to: notes)
        var cache: [String: Data] = [:]
        let url = try #require(URL(string: notes.absoluteString + "#n1"))
        let note = try #require(Footnotes.note(at: url, label: "1", under: root, cache: &cache))
        #expect(note.paragraphs == ["Une note."])
        #expect(note.isShort)
        #expect(cache.count == 1)
        let outside = try #require(URL(string: "file:///etc/hosts#n1"))
        #expect(Footnotes.note(at: outside, label: "1", under: root, cache: &cache) == nil)
    }

    @Test func longNoteIsNotShort() {
        let note = Footnote(id: "x", label: "1", paragraphs: [String(repeating: "mot ", count: 100)])
        #expect(!note.isShort)
    }
}

@Suite struct SectionAlignmentTests {
    /// Deux éditions aux mêmes chapitres, la traduction plus longue de 10 à 25 % : chapitre en face de chapitre.
    @Test func translationKeepsChaptersFacing() {
        let original = [4000, 12000, 9000, 15000, 7000]
        let translation = [4800, 13500, 11000, 17000, 8700]
        let alignment = SectionAlignment(left: original, right: translation)
        #expect(alignment.beads.map(\.left) == [0..<1, 1..<2, 2..<3, 3..<4, 4..<5])
        #expect(alignment.beads.map(\.right) == [0..<1, 1..<2, 2..<3, 3..<4, 4..<5])
        let middle = alignment.counterpart(chapter: 2, fraction: 0.5)
        #expect(middle.chapter == 2 && abs(middle.fraction - 0.5) < 0.001)
    }

    /// Une édition a une page de titre et une préface en plus : les chapitres suivants restent en face.
    @Test func extraFrontMatterIsSkipped() {
        let original = [10000, 10000, 10000, 10000]
        let edition = [200, 1500, 10500, 9800, 10200, 9900]
        let alignment = SectionAlignment(left: original, right: edition)
        #expect(alignment.counterpart(chapter: 0, fraction: 0).chapter == 2)
        #expect(alignment.counterpart(chapter: 3, fraction: 0.5).chapter == 5)
        // Depuis la préface, sans pendant : début du premier chapitre en face.
        let preface = alignment.counterpart(chapter: 1, fraction: 0.3, fromLeft: false)
        #expect(preface.chapter == 0 && preface.fraction == 0)
    }

    /// Un chapitre coupé en deux dans l'autre édition : la position suit les deux moitiés.
    @Test func splitChapterIsFollowed() {
        let original = [10000, 20000, 10000]
        let edition = [10000, 10000, 10000, 10000]
        let alignment = SectionAlignment(left: original, right: edition)
        #expect(alignment.beads.contains { $0.left == 1..<2 && $0.right == 1..<3 })
        #expect(alignment.counterpart(chapter: 1, fraction: 0.25).chapter == 1)
        let late = alignment.counterpart(chapter: 1, fraction: 0.75)
        #expect(late.chapter == 2 && abs(late.fraction - 0.5) < 0.01)
        // Et dans l'autre sens.
        let back = alignment.counterpart(chapter: 2, fraction: 0.5, fromLeft: false)
        #expect(back.chapter == 1 && abs(back.fraction - 0.75) < 0.01)
    }

    @Test func emptyBookGivesStart() {
        let alignment = SectionAlignment(left: [100, 200], right: [])
        let start = alignment.counterpart(chapter: 1, fraction: 0.5)
        #expect(start.chapter == 0 && start.fraction == 0)
    }
}
