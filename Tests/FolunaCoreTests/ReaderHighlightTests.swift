import Foundation
import Testing
@testable import FolunaCore

@Suite struct ReaderHighlightTests {
    func kindle(_ location: String, _ text: String) -> Clipping {
        Clipping(title: "Livre", author: "A", kind: .highlight, location: location, added: "", text: text)
    }

    func app(_ order: Int, _ text: String, chapter: Int = 0, pdf: Bool = false) -> Clipping {
        .readerHighlight(title: "Livre", author: "A", text: text,
                         anchor: ReaderAnchor(book: "f", chapter: chapter, start: 0, end: text.utf16.count, order: order),
                         isPDF: pdf)
    }

    @Test func appAndKindleHighlightsSortTogetherByPosition() {
        // Ordre d'ajout : ceux de la Kindle d'abord, puis ceux de l'app.
        let all = [kindle("page 12 · emplacement 300-302", "b"), kindle("emplacement 900", "d"),
                   app(120, "a"), app(650, "c"), app(900, "e")]
        #expect(KindleClippings.readingOrder(all).map(\.text) == ["a", "b", "c", "d", "e"])
    }

    @Test func pdfHighlightsSortByPageLikeTheKindle() {
        let all = [kindle("page 4", "b"), app(2, "a", chapter: 1, pdf: true), app(5, "c", chapter: 4, pdf: true)]
        #expect(KindleClippings.readingOrder(all).map(\.text) == ["a", "b", "c"])
        #expect(all[1].location == "page 2" && all[2].position == 5)
    }

    @Test func estimatedLocationCountsPreviousChaptersAndPartRead() {
        let weights = [1500, 3000, 600]
        #expect(ReaderAnchor.estimatedLocation(chapter: 0, offset: 0, textLength: 100, weights: weights) == 1)
        // 1500 octets avant, plus la moitié de 3000 : 3000 octets, emplacement 21.
        #expect(ReaderAnchor.estimatedLocation(chapter: 1, offset: 50, textLength: 100, weights: weights) == 21)
        #expect(ReaderAnchor.estimatedLocation(chapter: 7, offset: 0, textLength: 1, weights: weights) == 1)
    }

    @Test func appHighlightHasItsOwnIdAndSurvivesSaving() throws {
        let a = app(10, "Même texte"), b = app(10, "Même texte")
        #expect(a.id != b.id && a.isFromApp && !kindle("emplacement 1", "x").isFromApp)
        #expect(a.added.contains(" 20"))
        let url = tempDirectory().appendingPathComponent("clippings.json")
        try KindleClippings.save([a, kindle("emplacement 1", "x")], to: url)
        let loaded = KindleClippings.load(url)
        #expect(loaded[0] == a && loaded[0].anchor?.order == 10 && loaded[1].anchor == nil)
        // Un import de la Kindle ne touche pas aux surlignages de l'app.
        #expect(KindleClippings.merge(loaded, [kindle("emplacement 1", "x")]).count == 2)
    }

    @Test func noteIsSavedWithItsHighlightWithoutChangingItsID() throws {
        var a = app(10, "Passage"), k = kindle("emplacement 5", "Relevé")
        let ids = (a.id, k.id)
        a.note = "Pourquoi le quai ?"
        k.note = "À relire"
        #expect(a.hasNote && (a.id, k.id) == ids && !app(1, "x").hasNote)
        let url = tempDirectory().appendingPathComponent("clippings.json")
        try KindleClippings.save([a, k], to: url)
        let loaded = KindleClippings.load(url)
        #expect(loaded.map(\.note) == ["Pourquoi le quai ?", "À relire"])
        // La note d'un relevé de la Kindle survit à un nouvel import du même relevé.
        #expect(KindleClippings.merge(loaded, [kindle("emplacement 5", "Relevé")]).map(\.note) == loaded.map(\.note))
    }

    @Test func noteIsSearchedAndExported() {
        var a = app(10, "Le dernier ferry")
        a.note = "Fin du chapitre"
        #expect(a.matches("chapitre") && a.matches("ferry") && !a.matches("quai"))
        let md = KindleClippings.markdown(title: "Livre", author: "A", clippings: [a])
        #expect(md.contains("> Le dernier ferry\n\n📝 Fin du chapitre\n\n<small>"))
    }

    @Test func colorIsSavedAndYellowIsTheDefault() throws {
        let yellow = Clipping.readerHighlight(title: "Livre", author: "A", text: "x",
                                              anchor: ReaderAnchor(book: "f", chapter: 0, start: 0, end: 1, order: 1), isPDF: false)
        let green = Clipping.readerHighlight(title: "Livre", author: "A", text: "y",
                                             anchor: ReaderAnchor(book: "f", chapter: 0, start: 2, end: 3, order: 1), isPDF: false,
                                             color: .green)
        // Le jaune n'est pas écrit : un relevé de la Kindle, sans couleur, est jaune.
        #expect(yellow.color == nil && yellow.highlightColor == .yellow && kindle("emplacement 1", "z").highlightColor == .yellow)
        let url = tempDirectory().appendingPathComponent("clippings.json")
        try KindleClippings.save([yellow, green], to: url)
        #expect(KindleClippings.load(url).map(\.highlightColor) == [.yellow, .green])
        #expect(HighlightColor.allCases.map(\.label) == ["Jaune", "Vert", "Bleu", "Rose", "Violet"])
    }

    @Test func exportKeepsOnlyChosenColors() {
        var green = app(2, "vert"), blue = app(3, "bleu")
        green.color = .green
        blue.color = .blue
        let note = Clipping(title: "Livre", author: "A", kind: .note, location: "emplacement 4", added: "", text: "note")
        let all = [kindle("emplacement 1", "jaune"), green, blue, note]
        let key = { (c: Clipping) in c.highlightColor.rawValue }
        #expect(KindleClippings.withMarks(all, [], mark: key).count == 4)
        #expect(KindleClippings.withMarks(all, ["yellow", "green"], mark: key).map(\.text) == ["jaune", "vert"])
        #expect(KindleClippings.withMarks(all, ["blue"], mark: key).map(\.text) == ["bleu"])
        let md = KindleClippings.markdown(title: "Livre", author: "A", clippings: [green])
        #expect(md.contains("<small>Surlignement · Vert · chapitre 1"))
    }

    @Test func thematicNamesItsColorsAndAddsNewOnes() throws {
        var research = Research.new(name: "Rénovation des voiries")
        #expect(research.themes.map(\.color) == HighlightColor.allCases.map(\.hex))
        #expect(research.themes.map(\.displayName) == ["Jaune", "Vert", "Bleu", "Rose", "Violet"])
        research.themes[0].name = "Construction"
        let added = research.addTheme(name: "Mesures de trafic")
        let second = research.addTheme()
        #expect(added.color == Research.extraColors[0] && second.color == Research.extraColors[1] && second.displayName == "Nouvelle catégorie")
        var list = ResearchList(researches: [research])
        list.activeByBook["livre"] = research.id
        let url = tempDirectory().appendingPathComponent("researches.json")
        try ResearchList.save(list, to: url)
        let loaded = ResearchList.load(url)
        #expect(loaded == list && loaded.nextMark(in: research.id, base: .green).label == "Construction")
        #expect(loaded.nextMark(in: nil, base: .green).label == "Vert")
    }

    @Test func colorAndThematicsAreSeparate() {
        var voiries = Research.new(name: "Voiries")
        voiries.themes[0].name = "Construction"
        var memoire = Research.new(name: "Mémoire")
        memoire.themes[0].name = "Anthropologie"
        let traffic = voiries.addTheme(name: "Mesures de trafic")
        let list = ResearchList(researches: [voiries, memoire])
        var h = app(1, "passage")
        h.setThematic(voiries.id, on: true)
        h.setThematic(memoire.id, on: true)
        // Le même jaune se lit dans la légende de chaque thématique.
        #expect(list.mark(of: h).label == "Construction" && list.mark(of: h, in: memoire.id).label == "Anthropologie")
        h.apply(HighlightMark(traffic))
        #expect(h.hue == traffic.color && h.color == nil && h.thematicIDs == [voiries.id, memoire.id])
        #expect(list.mark(of: h).label == "Mesures de trafic" && list.mark(of: h, in: memoire.id).label == "Couleur personnalisée")
        h.apply(HighlightMark(.pink))
        #expect(h.highlightColor == .pink && h.hue == nil && list.mark(of: h).label == "Rose")
        h.setThematic(voiries.id, on: false)
        #expect(h.thematicIDs == [memoire.id])
        #expect(list.marks(for: h).map(\.label).first == "Anthropologie")
        // Filtres combinés : couleur et thématique.
        var other = app(2, "autre")
        other.setThematic(voiries.id, on: true)
        let both = [h, other]
        #expect(KindleClippings.withThematics(both, [voiries.id]).map(\.text) == ["autre"])
        #expect(KindleClippings.withMarks(KindleClippings.withThematics(both, [memoire.id, voiries.id]), [HighlightColor.pink.hex],
                                          mark: \.colorHex).map(\.text) == ["passage"])
        // « Sans thématique » : les relevés qu'aucune thématique ne range, seuls ou avec une thématique.
        let loose = app(3, "sans thématique")
        let three = [h, other, loose]
        #expect(KindleClippings.withThematics(three, [KindleClippings.noThematic]).map(\.text) == ["sans thématique"])
        #expect(KindleClippings.withThematics(three, [voiries.id, KindleClippings.noThematic]).map(\.text) == ["autre", "sans thématique"])
        #expect(KindleClippings.withThematics(three, [voiries.id]).map(\.text) == ["autre"], "sans ce choix, il reste masqué")
    }

    @Test func formerResearchHighlightsAreMigrated() {
        var research = Research.new(name: "Mémoire")
        let history = research.addTheme(name: "Histoire")
        let list = ResearchList(researches: [research])
        var old = app(1, "ancien")
        old.research = research.id
        old.theme = history.id
        var all = [old, app(2, "neuf")]
        #expect(list.migrate(&all))
        #expect(all[0].research == nil && all[0].theme == nil && all[0].thematicIDs == [research.id] && all[0].hue == history.color)
        #expect(!list.migrate(&all))
    }

    @Test func thematicExportGroupsByNamedColorThenBook() {
        var research = Research.new(name: "Mémoire")
        research.themes[0].name = "Anthropologie"
        research.themes[3].name = "Sociologie"
        func passage(_ book: String, _ order: Int, _ text: String, color: HighlightColor) -> Clipping {
            var c = Clipping.readerHighlight(title: book, author: "Auteur", text: text,
                                             anchor: ReaderAnchor(book: book, chapter: 0, start: 0, end: 1, order: order), isPDF: false)
            c.apply(HighlightMark(color))
            c.setThematic(research.id, on: true)
            return c
        }
        var noted = passage("Zola", 9, "z2", color: .pink)
        noted.note = "Pour le chapitre 2"
        var custom = passage("Zola", 1, "orange", color: .yellow)
        custom.apply(HighlightMark(hex: "#FF9500", label: ""))
        let all = [noted, passage("Zola", 3, "z1", color: .pink), passage("Balzac", 5, "b1", color: .pink),
                   passage("Balzac", 1, "b0", color: .yellow), custom, app(1, "hors thématique")]
        let md = ResearchExport.markdown(research, clippings: all)
        #expect(md.hasPrefix("# Mémoire\n\n*5 passages, 2 livres*"))
        let order = ["## Anthropologie", "> b0", "## Sociologie", "### Balzac — Auteur", "> b1", "### Zola — Auteur", "> z1", "> z2",
                     "📝 Pour le chapitre 2", "## Couleur personnalisée", "> orange"]
        var cursor = md.startIndex
        let found = order.allSatisfy { part in
            guard let r = md.range(of: part, range: cursor..<md.endIndex) else { return false }
            cursor = r.upperBound
            return true
        }
        #expect(found)
        #expect(!md.contains("## Vert") && !md.contains("hors thématique") && md.contains("<small>Zola · chapitre 1"))
    }

    @Test func thematicSortsByColorBookOrDate() {
        var research = Research.new(name: "Voiries")
        research.themes[0].name = "Construction"
        research.themes[3].name = "Analyse des coûts"
        func passage(_ book: String, _ order: Int, _ text: String, _ color: HighlightColor) -> Clipping {
            var c = Clipping.readerHighlight(title: book, author: "", text: text,
                                             anchor: ReaderAnchor(book: book, chapter: 0, start: 0, end: 1, order: order), isPDF: false)
            c.apply(HighlightMark(color))
            c.setThematic(research.id, on: true)
            return c
        }
        // Ordre d'ajout : z9, a5, z1, a2.
        let all = [passage("Zola", 9, "z9", .pink), passage("Aubry", 5, "a5", .yellow),
                   passage("Zola", 1, "z1", .yellow), passage("Aubry", 2, "a2", .pink), app(1, "ailleurs")]
        let byColor = ResearchExport.sections(research, clippings: all, order: .color)
        #expect(byColor.map(\.title) == ["Construction", "Analyse des coûts"])
        #expect(byColor.map { $0.clippings.map(\.text) } == [["a5", "z1"], ["a2", "z9"]])
        let byBook = ResearchExport.sections(research, clippings: all, order: .book)
        #expect(byBook.map(\.title) == ["Aubry", "Zola"] && byBook.map { $0.clippings.map(\.text) } == [["a2", "a5"], ["z1", "z9"]])
        let byDate = ResearchExport.sections(research, clippings: all, order: .added)
        #expect(byDate.first?.clippings.map(\.text) == ["a2", "z1", "a5", "z9"])
        let md = ResearchExport.markdown(research, clippings: all, order: .book)
        #expect(md.contains("## Aubry") && md.contains("<small>Analyse des coûts · chapitre 1"))
        #expect(md.range(of: "> a2")!.lowerBound < md.range(of: "> a5")!.lowerBound)
    }
}
