import AlexandrieCore
import AppKit
import SwiftUI
import WebKit

/// Pages d'un livre EPUB (S-066, S-067) : un chapitre à la fois, mis en colonnes de la largeur de la
/// fenêtre ; tourner la page fait défiler d'une colonne, et passe au chapitre voisin aux extrémités.
@MainActor @Observable
final class EPUBPageController: NSObject, WKNavigationDelegate {
    let book: ReaderBook
    private(set) var chapter = 0
    private(set) var page = 0
    private(set) var pageCount = 1
    /// Avancée dans le chapitre (0 à 1), relue après chaque page tournée.
    private(set) var fraction = 0.0
    /// Appelé après chaque page tournée : la position est enregistrée.
    @ObservationIgnored var onMove: (ReadingPosition) -> Void = { _ in }

    @ObservationIgnored private(set) lazy var webView: ReaderWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = ReaderWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.controller = self
        view.setValue(false, forKey: "drawsBackground")
        return view
    }()

    /// Ce qu'il faut faire une fois le chapitre chargé.
    private enum Landing { case fraction(Double), last, fragment(String) }
    @ObservationIgnored private var landing: Landing = .fraction(0)
    @ObservationIgnored private var settings = (scale: 1.0, theme: ReaderTheme.light)

    init(book: ReaderBook) {
        self.book = book
    }

    var percent: Double { ReadingPosition.percent(chapter: chapter, fraction: fraction, weights: book.weights) }

    // MARK: Navigation

    func open(chapter: Int, fraction: Double = 0) {
        load(chapter, landing: .fraction(fraction))
    }

    func open(_ entry: ReaderBook.Entry) {
        load(entry.chapter, landing: entry.fragment.map(Landing.fragment) ?? .fraction(0))
    }

    func next() {
        Task {
            if await js("alx.next()") as? String == "end" {
                if chapter + 1 < book.chapters.count { load(chapter + 1, landing: .fraction(0)) }
            } else {
                await refresh()
            }
        }
    }

    func previous() {
        Task {
            if await js("alx.prev()") as? String == "start" {
                if chapter > 0 { load(chapter - 1, landing: .last) }
            } else {
                await refresh()
            }
        }
    }

    private func load(_ index: Int, landing: Landing) {
        guard book.chapters.indices.contains(index) else { return }
        self.landing = landing
        if index == chapter, webView.url != nil {
            Task { await land() }
        } else {
            chapter = index
            webView.loadFileURL(book.chapters[index], allowingReadAccessTo: book.root)
        }
    }

    // MARK: Réglages (S-069)

    func apply(scale: Double, theme: ReaderTheme) {
        settings = (scale, theme)
        Task {
            let before = fraction
            await js(settingsScript)
            await js("alx.setFraction(\(before))")
            await refresh()
        }
    }

    private var settingsScript: String {
        "alx.configure({scale: \(settings.scale), paper: '\(settings.theme.paper)', ink: '\(settings.theme.ink)', "
            + "highlight: '\(settings.theme.highlight)', recolor: \(settings.theme != .light)})"
    }

    // MARK: WebKit

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task {
            await js(settingsScript)
            await land()
        }
    }

    /// Liens du livre : un autre chapitre s'ouvre ici ; une adresse web part dans le navigateur.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
        if url.isFileURL {
            let path = url.standardizedFileURL.path
            if let index = book.chapters.firstIndex(where: { $0.standardizedFileURL.path == path }) {
                load(index, landing: url.fragment.map(Landing.fragment) ?? .fraction(0))
            }
        } else if ["http", "https", "mailto"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    private func land() async {
        switch landing {
        case .fraction(let f): await js("alx.setFraction(\(f))")
        case .last: await js("alx.last()")
        case .fragment(let id): await js("alx.show(\(Self.quoted(id)))")
        }
        await refresh()
    }

    /// Relit la page affichée et la signale (position enregistrée).
    private func refresh() async {
        guard let state = await js("[alx.page(), alx.pageCount(), alx.fraction()]") as? [Any], state.count == 3 else { return }
        page = (state[0] as? NSNumber)?.intValue ?? 0
        pageCount = (state[1] as? NSNumber)?.intValue ?? 1
        fraction = (state[2] as? NSNumber)?.doubleValue ?? 0
        onMove(ReadingPosition(chapter: chapter, fraction: fraction, percent: percent))
    }

    @discardableResult
    func js(_ source: String) async -> Any? {
        try? await webView.evaluateJavaScript(source)
    }

    static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// Mise en pages : le chapitre est découpé en colonnes de la largeur de la fenêtre ; une page = une colonne.
    static let script = """
    (() => {
      if (window.alx) return;
      const style = document.createElement('style');
      (document.head || document.documentElement).appendChild(style);
      const root = () => document.scrollingElement || document.documentElement;
      const alx = {
        settings: { scale: 1, paper: '#FFFFFF', ink: '#1D1D1F', highlight: 'rgba(255,204,0,0.42)', recolor: false },
        margin() { return Math.max(24, Math.min(64, Math.round(window.innerWidth * 0.07))); },
        configure(s) { Object.assign(this.settings, s); this.layout(); },
        layout() {
          const w = window.innerWidth, h = window.innerHeight, m = this.margin(), s = this.settings;
          // Lignes d'une longueur confortable : sur une fenêtre large, la page se centre.
          const x = Math.max(m, Math.round((w - 680 * s.scale) / 2));
          style.textContent = `
            html { height: ${h}px !important; overflow: hidden !important; background: ${s.paper} !important;
                   font-size: ${Math.round(100 * s.scale)}% !important; -webkit-text-size-adjust: none; }
            body { margin: 0 !important; padding: ${m}px ${x}px !important; box-sizing: border-box !important;
                   height: ${h}px !important; width: auto !important; max-width: none !important;
                   column-width: ${w - 2 * x}px !important; column-gap: ${2 * x}px !important; column-fill: auto !important;
                   color: ${s.ink} !important; background: transparent !important; line-height: 1.5; } /* grid: ok interligne CSS du livre */
            ${s.recolor ? `body *:not(a) { color: ${s.ink} !important; background-color: transparent !important; }` : ''}
            img, svg, video { max-width: 100% !important; max-height: ${h - 2 * m}px !important; object-fit: contain; }
            mark.alx-hl { background: ${s.highlight}; color: inherit; border-radius: 2px; }
            mark.alx-hl.alx-note { border-bottom: 2px solid ${s.ink}; }
          `;
        },
        width() { return window.innerWidth; },
        pageCount() { return Math.max(1, Math.ceil(root().scrollWidth / this.width() - 0.01)); },
        page() { return Math.round(root().scrollLeft / this.width()); },
        goTo(p) { const n = this.pageCount(); p = Math.max(0, Math.min(n - 1, p)); root().scrollLeft = p * this.width(); return p; },
        next() { const p = this.page(); if (p >= this.pageCount() - 1) return 'end'; this.goTo(p + 1); return 'ok'; },
        prev() { const p = this.page(); if (p <= 0) return 'start'; this.goTo(p - 1); return 'ok'; },
        last() { this.goTo(this.pageCount() - 1); },
        fraction() { const n = this.pageCount(); return n <= 1 ? 0 : this.page() / (n - 1); },
        setFraction(f) { const n = this.pageCount(); this.goTo(Math.round(f * (n - 1))); },
        pageOf(el) { return Math.floor((el.getBoundingClientRect().left + root().scrollLeft) / this.width()); },
        show(id) { const el = document.getElementById(id); if (el) this.goTo(this.pageOf(el)); },
      };
      window.alx = alx;
      alx.layout();
      window.addEventListener('resize', () => {
        const f = alx.fraction();
        alx.layout();
        requestAnimationFrame(() => alx.setFraction(f));
      });
    })();
    """
}

/// Vue web de la fenêtre de lecture : les flèches, Espace et les touches de page tournent les pages.
final class ReaderWebView: WKWebView {
    weak var controller: EPUBPageController?

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

    /// Geste du trackpad en cours : il tourne une page à la fin, jamais une demi-colonne.
    private var swipe: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        guard let controller, event.momentumPhase == [] else { return }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? -event.scrollingDeltaX : -event.scrollingDeltaY
        if event.phase == [] {
            // Molette d'une souris : un cran, une page.
            if delta > 0 { controller.next() } else if delta < 0 { controller.previous() }
            return
        }
        if event.phase == .began { swipe = 0 }
        swipe += delta
        if event.phase == .ended || event.phase == .cancelled {
            if swipe > 24 { controller.next() } else if swipe < -24 { controller.previous() }
            swipe = 0
        }
    }
}

struct EPUBPageView: NSViewRepresentable {
    let controller: EPUBPageController

    func makeNSView(context: Context) -> ReaderWebView { controller.webView }
    func updateNSView(_ view: ReaderWebView, context: Context) {}
}
