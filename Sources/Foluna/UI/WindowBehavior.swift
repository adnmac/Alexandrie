import AppKit
import SwiftUI

extension View {
    /// Aucun contrôle n'a le focus à l'ouverture de la fenêtre ou de la feuille : ni anneau ni curseur.
    /// La personne clique ou appuie sur Tab pour commencer.
    func noInitialFocus() -> some View {
        background(WindowHook())
    }

    /// Ajuste un `Form` ou une `ScrollView` à son contenu, jusqu'à `max` points : l'onglet des réglages
    /// ou la feuille grandit avec son contenu et ne défile qu'au-delà. Sous macOS 14, hauteur `max` fixe.
    func fitsContent(max: CGFloat = Layout.maxPanelHeight) -> some View {
        modifier(FitsContent(max: max))
    }
}

private struct FitsContent: ViewModifier {
    var max: CGFloat
    @State private var height: CGFloat?

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                // Seulement la hauteur du contenu : les marges changent avec la fenêtre et relanceraient
                // le redimensionnement sans fin.
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentSize.height.rounded(.up)
                } action: { _, new in
                    if abs(new - (height ?? 0)) >= 1 { height = new }
                }
                .frame(height: height.map { min($0, max) })
                .scrollBounceBehavior(.basedOnSize)
        } else {
            content.frame(height: max)
        }
    }
}

/// Vue de taille nulle qui atteint la fenêtre où elle se trouve.
private struct WindowHook: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ probe: Probe, context: Context) {}

    final class Probe: NSView {
        private var reopened = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            NotificationCenter.default.removeObserver(self)
            clear(window)
            // Une fenêtre fermée garde ses vues : on recommence à sa prochaine ouverture.
            NotificationCenter.default.addObserver(self, selector: #selector(willClose),
                                                   name: NSWindow.willCloseNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(didBecomeKey),
                                                   name: NSWindow.didBecomeKeyNotification, object: window)
        }

        @objc private func willClose(_ note: Notification) {
            reopened = true
        }

        @objc private func didBecomeKey(_ note: Notification) {
            guard reopened, let window else { return }
            reopened = false
            clear(window)
        }

        /// AppKit choisit un premier contrôle juste après l'affichage : on le retire ensuite.
        private func clear(_ window: NSWindow) {
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
        }
    }
}
