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
    /// Un passage est sélectionné : il peut être surligné (S-070).
    private(set) var hasSelection = false
    /// Commandes de surlignage des menus contextuels de la page.
    @ObservationIgnored var actions = ReaderHighlightActions()
    /// Couleur affichée d'un surlignage : son thème ou sa couleur de base (S-076).
    @ObservationIgnored var markOf: (Clipping) -> HighlightMark = { HighlightMark($0.highlightColor) }
    /// Passage surligné sous le dernier clic droit, signalé par la page avant l'ouverture du menu (S-073).
    @ObservationIgnored fileprivate var menuTarget: Clipping.ID?
    /// Clic sur un passage surligné (S-071) : sa note s'ouvre, posée sur ce rectangle de la page.
    @ObservationIgnored var onOpenNote: (Clipping.ID, CGRect) -> Void = { _, _ in }
    /// Surlignages faits dans l'app pour ce livre ; ceux du chapitre affiché sont dessinés.
    @ObservationIgnored var highlights: [Clipping] = [] {
        didSet { if highlights != oldValue { Task { _ = await js(highlightsScript) } } }
    }

    @ObservationIgnored private(set) lazy var webView: ReaderWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController.add(ScriptRelay { [weak self] message in
            switch message {
            case .selection(let selected): self?.hasSelection = selected
            case .open(let id, let rect): self?.onOpenNote(id, rect)
            case .menuTarget(let id): self?.menuTarget = id
            }
        }, name: "alx")
        let view = ReaderWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.controller = self
        view.setValue(false, forKey: "drawsBackground")
        return view
    }()

    /// Ce qu'il faut faire une fois le chapitre chargé.
    private enum Landing { case fraction(Double), last, fragment(String), text(String, Int), range(Int, Int) }
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

    /// Ouvre un chapitre sur un passage trouvé (S-083) : la `occurrence`-ième apparition exacte de `text`,
    /// sélectionnée, à sa page.
    func open(chapter: Int, text: String, occurrence: Int) {
        load(chapter, landing: .text(text, occurrence))
    }

    /// Ouvre un chapitre sur un surlignage (S-072) : ses positions dans le texte du corps, sélectionnées, à leur page.
    func open(chapter: Int, start: Int, end: Int) {
        load(chapter, landing: .range(start, end))
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
            // Le fond des surlignages suit le papier.
            await js(highlightsScript)
            await js("alx.setFraction(\(before))")
            await refresh()
        }
    }

    private var settingsScript: String {
        "alx.configure({scale: \(settings.scale), paper: '\(settings.theme.paper)', ink: '\(settings.theme.ink)', "
            + "recolor: \(settings.theme != .light)})"
    }

    /// Redessine les surlignages : une couleur de thème a pu changer.
    func redraw() { Task { _ = await js(highlightsScript) } }

    // MARK: Surlignages (S-070)

    /// Passage sélectionné, repéré dans le texte du chapitre ; nil sans sélection.
    func selectedPassage(fingerprint: String) async -> (anchor: ReaderAnchor, text: String)? {
        guard let s = await js("alx.selection()") as? [Any], s.count == 4,
              let start = (s[0] as? NSNumber)?.intValue, let end = (s[1] as? NSNumber)?.intValue,
              let text = s[2] as? String, let length = (s[3] as? NSNumber)?.intValue, end > start else { return nil }
        let order = ReaderAnchor.estimatedLocation(chapter: chapter, offset: start, textLength: length, weights: book.weights)
        return (ReaderAnchor(book: fingerprint, chapter: chapter, start: start, end: end, order: order), text)
    }

    func clearSelection() {
        Task { _ = await js("window.getSelection().removeAllRanges()") }
    }

    /// Rectangle du passage surligné dans la page affichée, pour y poser sa note (S-071).
    func noteRect(for id: Clipping.ID) async -> CGRect? {
        await js(highlightsScript)
        guard let r = await js("alx.rectOf(\(Self.quoted(id)))") as? [NSNumber], r.count == 4 else { return nil }
        return CGRect(x: r[0].doubleValue, y: r[1].doubleValue, width: r[2].doubleValue, height: r[3].doubleValue)
    }

    private var highlightsScript: String {
        let marks = highlights.compactMap { h -> String? in
            guard let a = h.anchor, a.chapter == chapter else { return nil }
            return "{id: \(Self.quoted(h.id)), start: \(a.start), end: \(a.end), note: \(Self.quoted(h.note ?? "")), "
                + "key: \(Self.quoted(markOf(h).key)), bg: '\(settings.theme.highlight(markOf(h)))'}"
        }
        return "alx.setHighlights([\(marks.joined(separator: ", "))])"
    }

    // MARK: WebKit

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasSelection = false
        Task {
            await js(settingsScript)
            await js(highlightsScript)
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
        case .range(let start, let end): await js("alx.selectPos(\(start), \(end))")
        case .text(let text, let occurrence):
            // Sans la graphie exacte (blancs du livre différents), le premier mot à la place.
            if await js("alx.findText(\(Self.quoted(text)), \(occurrence))") as? Bool != true,
               let word = text.split(separator: " ").first.map(String.init) {
                await js("alx.findText(\(Self.quoted(word)), 0)")
            }
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
        settings: { scale: 1, paper: '#FFFFFF', ink: '#1D1D1F', recolor: false },
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
            mark.alx-hl { color: inherit; border-radius: 2px; cursor: pointer; }
            mark.alx-hl.alx-note { border-bottom: 1px dotted ${s.ink}; }
            mark.alx-hl.alx-note-end::after { content: ''; display: inline-block; width: 0.5em; height: 0.5em;
                   margin-left: 0.15em; vertical-align: super; border-radius: 50%; background: ${s.ink}; opacity: 0.7; }
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
        // Surlignages (S-070) : un passage = ses positions dans le texte du corps (textContent).
        textPos(node, off) { const r = document.createRange(); r.setStart(document.body, 0); r.setEnd(node, off); return r.toString().length; },
        selection() {
          const s = window.getSelection();
          if (!s || s.isCollapsed || !s.rangeCount) return null;
          const r = s.getRangeAt(0);
          if (!document.body.contains(r.commonAncestorContainer)) return null;
          const raw = r.toString(), text = raw.trim();
          if (!text) return null;
          const lead = raw.length - raw.trimStart().length, trail = raw.length - raw.trimEnd().length;
          return [this.textPos(r.startContainer, r.startOffset) + lead, this.textPos(r.endContainer, r.endOffset) - trail,
                  text, document.body.textContent.length];
        },
        unmark() {
          document.querySelectorAll('mark.alx-hl').forEach(m => {
            const p = m.parentNode;
            while (m.firstChild) p.insertBefore(m.firstChild, m);
            p.removeChild(m);
          });
          document.body.normalize();
        },
        mark(h) {
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), nodes = [];
          for (let n = walker.nextNode(); n; n = walker.nextNode()) nodes.push(n);
          let pos = 0;
          for (const t of nodes) {
            const len = t.data.length, a = Math.max(h.start, pos) - pos, b = Math.min(h.end, pos + len) - pos;
            pos += len;
            if (a < b) {
              let node = t;
              if (b < len) node.splitText(b);
              if (a > 0) node = node.splitText(a);
              // Les blancs entre deux paragraphes ne sont pas surlignés.
              if (/\\S/.test(node.data)) {
                const m = document.createElement('mark');
                m.className = 'alx-hl' + (h.note ? ' alx-note' : '');
                m.setAttribute('data-mark', h.key);
                // Couleur du thème ou de base, pour le papier choisi (S-073, S-076).
                m.style.setProperty('background', h.bg, 'important');
                m.setAttribute('data-alx', h.id);
                if (h.note) m.title = h.note;
                node.parentNode.insertBefore(m, node);
                m.appendChild(node);
              }
            }
            if (pos >= h.end) break;
          }
          // Repère de note (S-071) : un point après le dernier morceau du passage.
          const parts = document.querySelectorAll(`mark[data-alx="${CSS.escape(h.id)}"]`);
          if (h.note && parts.length) parts[parts.length - 1].classList.add('alx-note-end');
        },
        box(el) { const r = el.getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; },
        // Premier morceau du passage visible dans la page affichée.
        rectOf(id) {
          const parts = [...document.querySelectorAll(`mark[data-alx="${CSS.escape(id)}"]`)];
          const shown = parts.find(m => { const r = m.getBoundingClientRect(); return r.left >= 0 && r.left < window.innerWidth; });
          return shown ? this.box(shown) : null;
        },
        setHighlights(list) { this.unmark(); list.forEach(h => this.mark(h)); },
        // Surlignage ouvert depuis les notes (S-072) : positions dans le texte du corps, sélectionnées, à leur page.
        selectPos(start, end) {
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          let pos = 0, a = null, b = null;
          for (let x = walker.nextNode(); x; x = walker.nextNode()) {
            const len = x.data.length;
            if (!a && start <= pos + len) a = [x, start - pos];
            if (!b && end <= pos + len) { b = [x, end - pos]; break; }
            pos += len;
          }
          if (!a || !b) return false;
          const r = document.createRange();
          r.setStart(a[0], a[1]); r.setEnd(b[0], b[1]);
          const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
          this.goTo(Math.floor((r.getBoundingClientRect().left + root().scrollLeft) / this.width()));
          return true;
        },
        // Passage trouvé (S-083) : n-ième apparition exacte dans le texte du corps, sélectionnée, à sa page.
        findText(t, n) {
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), nodes = [];
          for (let x = walker.nextNode(); x; x = walker.nextNode()) nodes.push(x);
          const full = nodes.map(x => x.data).join('');
          let at = -1;
          for (let k = 0; k <= n; k++) { at = full.indexOf(t, at + 1); if (at < 0) return false; }
          const point = (pos) => {
            let p = 0;
            for (const x of nodes) { if (pos <= p + x.data.length) return [x, pos - p]; p += x.data.length; }
            return null;
          };
          const a = point(at), b = point(at + t.length);
          if (!a || !b) return false;
          const r = document.createRange();
          r.setStart(a[0], a[1]); r.setEnd(b[0], b[1]);
          const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
          this.goTo(Math.floor((r.getBoundingClientRect().left + root().scrollLeft) / this.width()));
          return true;
        },
      };
      window.alx = alx;
      alx.layout();
      document.addEventListener('selectionchange', () => {
        const s = window.getSelection();
        window.webkit.messageHandlers.alx.postMessage(!!s && !s.isCollapsed && s.toString().trim().length > 0);
      });
      // Clic droit : le passage surligné visé, pour les entrées du menu (S-073).
      document.addEventListener('contextmenu', e => {
        const m = e.target.closest && e.target.closest('mark.alx-hl');
        window.webkit.messageHandlers.alx.postMessage({ menu: m ? m.getAttribute('data-alx') : '' });
      });
      // Clic sur un passage surligné, sans sélection en cours : sa note s'ouvre (S-071).
      document.addEventListener('click', e => {
        const m = e.target.closest && e.target.closest('mark.alx-hl'), s = window.getSelection();
        if (!m || (s && !s.isCollapsed) || e.target.closest('a')) return;
        window.webkit.messageHandlers.alx.postMessage({ open: m.getAttribute('data-alx'), rect: alx.box(m) });
      });
      window.addEventListener('resize', () => {
        const f = alx.fraction();
        alx.layout();
        requestAnimationFrame(() => alx.setFraction(f));
      });
    })();
    """
}

/// Relaie les messages de la page sans retenir le contrôleur : WebKit garde ses relais.
final class ScriptRelay: NSObject, WKScriptMessageHandler {
    enum Message {
        /// Une sélection existe ou non.
        case selection(Bool)
        /// Clic sur un passage surligné : son identifiant et son rectangle dans la page.
        case open(Clipping.ID, CGRect)
        /// Clic droit, sur un passage surligné ou non.
        case menuTarget(Clipping.ID?)
    }

    let receive: @MainActor (Message) -> Void

    init(_ receive: @escaping @MainActor (Message) -> Void) {
        self.receive = receive
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let parsed: Message
        if let body = message.body as? [String: Any], let id = body["menu"] as? String {
            parsed = .menuTarget(id.isEmpty ? nil : id)
        } else if let body = message.body as? [String: Any], let id = body["open"] as? String {
            let r = (body["rect"] as? [NSNumber])?.map(\.doubleValue) ?? []
            parsed = .open(id, r.count == 4 ? CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) : .zero)
        } else {
            parsed = .selection(message.body as? Bool ?? false)
        }
        MainActor.assumeIsolated { receive(parsed) }
    }
}

/// Vue web de la fenêtre de lecture : les flèches, Espace et les touches de page tournent les pages.
final class ReaderWebView: WKWebView {
    weak var controller: EPUBPageController?

    /// Menu contextuel de la page : les commandes d'Alexandrie en tête (S-070, S-073). WebKit ne dit pas
    /// encore à l'app qu'une sélection existe : « Copier » dans son menu en tient lieu.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let controller else { return }
        let selection = menu.items.contains { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }
        for item in menu.items where item.identifier?.rawValue == "WKMenuItemIdentifierCopyLinkWithHighlight" {
            menu.removeItem(item)
        }
        HighlightMenu.insert(HighlightMenu.items(selection: selection, highlight: controller.menuTarget, actions: controller.actions),
                             into: menu)
        HighlightMenu.tidy(menu)
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
