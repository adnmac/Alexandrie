import AlexandrieCore
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
                        entries.append(ReaderBook.Entry(title: child.label ?? "Page \(index + 1)", chapter: index,
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

    private func pageChanged() {
        guard let document, let current = view.currentPage else { return }
        page = document.index(for: current)
        onMove(ReadingPosition(chapter: page, fraction: 0, percent: percent))
    }
}

/// Vue PDF de la fenêtre de lecture : flèches, Espace et touches de page tournent les pages.
final class ReaderPDFView: PDFView {
    weak var controller: PDFPageController?

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
