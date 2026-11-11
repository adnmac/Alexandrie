import FolunaCore
import AppKit
import PDFKit
import SwiftUI

/// Pages d'un PDF (S-066) : une page à la fois, ajustée à la fenêtre. La taille du texte (S-069)
/// y devient un zoom : le PDF garde sa mise en page.
@MainActor @Observable
final class PDFPageController {
    let document: PDFDocument?
    private(set) var page = 0
    var pageCount: Int { document?.pageCount ?? 0 }
    @ObservationIgnored var onMove: (ReadingPosition) -> Void = { _ in }
    /// Du texte est sélectionné : il peut être surligné (S-070).
    private(set) var hasSelection = false
    /// Commandes de surlignage des menus contextuels de la page.
    @ObservationIgnored var actions = ReaderHighlightActions()
    /// Couleur affichée d'un surlignage : son thème ou sa couleur de base (S-076).
    @ObservationIgnored var markOf: (Clipping) -> HighlightMark = { HighlightMark($0.highlightColor) }
    /// Clic sur un passage surligné (S-071) : sa note s'ouvre, posée sur ce rectangle de la vue.
    @ObservationIgnored var onOpenNote: (Clipping.ID, CGRect) -> Void = { _, _ in }
    /// Surlignage auquel appartient chaque annotation dessinée.
    @ObservationIgnored private var annotationIDs: [ObjectIdentifier: Clipping.ID] = [:]
    /// Surlignages faits dans l'app, dessinés en annotations sur les pages. Le document n'est jamais
    /// enregistré : le fichier du PDF ne change pas.
    @ObservationIgnored var highlights: [Clipping] = [] {
        didSet { if highlights != oldValue { drawHighlights() } }
    }

    @ObservationIgnored private(set) lazy var view: ReaderPDFView = {
        let view = ReaderPDFView()
        view.document = document
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.autoScales = true
        view.controller = self
        NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pageChanged() }
        }
        NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hasSelection = !(self.view.currentSelection?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        return view
    }()

    init(url: URL) {
        document = PDFDocument(url: url)
    }

    var percent: Double { ReadingPosition.percent(page: page, of: pageCount) }

    /// Table du PDF (ses signets), à plat avec la profondeur de chaque entrée.
    var toc: [ReaderBook.Entry] {
        guard let document, let root = document.outlineRoot else { return [] }
        var entries: [ReaderBook.Entry] = []
        func walk(_ item: PDFOutline, depth: Int) {
            for i in 0..<item.numberOfChildren {
                guard let child = item.child(at: i) else { continue }
                if let page = child.destination?.page {
                    let index = document.index(for: page)
                    if index != NSNotFound {
                        entries.append(ReaderBook.Entry(title: child.label ?? String(localized: "Page \(index + 1)"), chapter: index,
                                                        fragment: nil, depth: depth))
                    }
                }
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return entries
    }

    func go(to index: Int) {
        guard let page = document?.page(at: max(0, min(index, pageCount - 1))) else { return }
        view.go(to: page)
        pageChanged()
    }

    /// Montre un passage trouvé (S-083) : sa page, et la `occurrence`-ième apparition exacte de `text` sélectionnée.
    func show(page index: Int, text: String, occurrence: Int) {
        go(to: index)
        guard let document, let page = document.page(at: index) else { return }
        let found = document.findString(text, withOptions: []).filter { $0.pages.contains(page) }
        let pick = found.indices.contains(occurrence) ? found[occurrence] : found.first
        guard let pick else { return }
        view.setCurrentSelection(pick, animate: true)
        view.go(to: pick)
    }

    /// Montre un surlignage (S-072) : sa page, et le passage sélectionné.
    func show(page index: Int, range: NSRange) {
        go(to: index)
        guard let page = document?.page(at: index), let selection = page.selection(for: range) else { return }
        view.setCurrentSelection(selection, animate: true)
        view.go(to: selection)
    }

    func next() { view.goToNextPage(nil) }
    func previous() { view.goToPreviousPage(nil) }

    /// Taille du texte : zoom autour de l'ajustement à la fenêtre.
    func apply(scale: Double) {
        view.autoScales = true
        guard scale != 1 else { return }
        let fit = view.scaleFactorForSizeToFit
        view.autoScales = false
        view.scaleFactor = fit * scale
    }

    // MARK: Surlignages (S-070)

    /// Passage sélectionné sur sa page (la première, en vue page par page) ; nil sans texte sélectionné.
    func selectedPassage(fingerprint: String) -> (anchor: ReaderAnchor, text: String)? {
        guard let document, let selection = view.currentSelection, let page = selection.pages.first else { return nil }
        let count = selection.numberOfTextRanges(on: page)
        let text = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard count > 0, !text.isEmpty else { return nil }
        let first = selection.range(at: 0, on: page), last = selection.range(at: count - 1, on: page)
        let index = document.index(for: page)
        let anchor = ReaderAnchor(book: fingerprint, chapter: index, start: first.location,
                                  end: last.location + last.length, order: index + 1)
        return (anchor, text)
    }

    func clearSelection() { view.clearSelection() }

    private static let marker = "Alexandrie"  // nom d'origine, inscrit dans les PDF annotés : ne pas changer

    /// Redessine les surlignages : une couleur de thème a pu changer.
    func redraw() { drawHighlights() }

    private func drawHighlights() {
        guard let document else { return }
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for a in page.annotations where a.userName == Self.marker { page.removeAnnotation(a) }
        }
        annotationIDs = [:]
        for h in highlights {
            guard let anchor = h.anchor, let page = document.page(at: anchor.chapter),
                  let selection = page.selection(for: NSRange(location: anchor.start, length: anchor.end - anchor.start))
            else { continue }
            for (i, line) in selection.selectionsByLine().enumerated() {
                let annotation = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
                annotation.color = ReaderTheme.pdfHighlight(markOf(h))
                annotation.userName = Self.marker
                // Repère de note (S-071) : PDFKit pose sa bulle de commentaire sur un surlignage qui a un contenu.
                if i == 0, h.hasNote { annotation.contents = h.note }
                add(annotation, to: page, for: h.id)
            }
        }
    }

    private func add(_ annotation: PDFAnnotation, to page: PDFPage, for id: Clipping.ID) {
        page.addAnnotation(annotation)
        annotationIDs[ObjectIdentifier(annotation)] = id
    }

    /// Surlignage sous ce point de la vue, s'il y en a un.
    func highlight(at point: CGPoint) -> (id: Clipping.ID, rect: CGRect)? {
        guard let page = view.page(for: point, nearest: false),
              let annotation = page.annotation(at: view.convert(point, to: page)),
              let id = annotationIDs[ObjectIdentifier(annotation)] else { return nil }
        return (id, view.convert(annotation.bounds, from: page))
    }

    /// Rectangle du passage surligné sur la page affichée, pour y poser sa note (S-071).
    func noteRect(for id: Clipping.ID) -> CGRect? {
        guard let current = view.currentPage,
              let annotation = current.annotations.first(where: { annotationIDs[ObjectIdentifier($0)] == id }) else { return nil }
        return view.convert(annotation.bounds, from: current)
    }

    private func pageChanged() {
        guard let document, let current = view.currentPage else { return }
        page = document.index(for: current)
        onMove(ReadingPosition(chapter: page, fraction: 0, percent: percent))
    }
}

/// Vue PDF de la fenêtre de lecture : flèches, Espace et touches de page tournent les pages.
final class ReaderPDFView: PDFView {
    weak var controller: PDFPageController?

    /// Commandes de PDFKit retirées du menu contextuel (S-073) : ses surlignages et notes, qui ne
    /// seraient pas enregistrés, et le zoom et les modes d'affichage, que la fenêtre de lecture règle elle-même.
    private static let hiddenActions: Set<String> = [
        "_removeMarkup:", "_removeNote:", "_setAutoSize:", "zoomIn:", "zoomOut:", "_setActualSize:",
        "_setSinglePage:", "_setSinglePageScrolling:", "_setDoublePage:", "_setDoublePageScrolling:",
    ]

    /// Menu contextuel : les commandes de Foluna en tête, celles de PDFKit qui n'ont pas lieu d'être retirées.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        for item in menu.items {
            let action = item.action.map(NSStringFromSelector) ?? ""
            // Le choix de couleur de PDFKit est une vue, sans action.
            if Self.hiddenActions.contains(action) || item.view != nil { menu.removeItem(item) }
        }
        guard let controller else { return menu }
        let selection = !(currentSelection?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hit = controller.highlight(at: convert(event.locationInWindow, from: nil))?.id
        HighlightMenu.insert(HighlightMenu.items(selection: selection, highlight: hit, actions: controller.actions), into: menu)
        HighlightMenu.tidy(menu)
        return menu
    }

    /// Surlignage sous le clic : sa note s'ouvre au relâchement, si aucun texte n'a été sélectionné (S-071).
    private var pressed: Clipping.ID?

    override func mouseDown(with event: NSEvent) {
        pressed = event.clickCount == 1 ? controller?.highlight(at: convert(event.locationInWindow, from: nil))?.id : nil
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        defer { pressed = nil }
        guard let pressed, let controller, !controller.hasSelection,
              let hit = controller.highlight(at: convert(event.locationInWindow, from: nil)), hit.id == pressed else { return }
        controller.onOpenNote(hit.id, hit.rect)
    }

    override func keyDown(with event: NSEvent) {
        guard let controller, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return super.keyDown(with: event)
        }
        let shift = event.modifierFlags.contains(.shift)
        switch Int(event.keyCode) {
        case 49: shift ? controller.previous() : controller.next()   // Espace, ⇧Espace
        case 124, 125, 121: controller.next()                        // → ↓ ⇟
        case 123, 126, 116: controller.previous()                    // ← ↑ ⇞
        default: super.keyDown(with: event)
        }
    }
}

struct PDFPageView: NSViewRepresentable {
    let controller: PDFPageController

    func makeNSView(context: Context) -> ReaderPDFView { controller.view }
    func updateNSView(_ view: ReaderPDFView, context: Context) {}
}
