import SwiftUI

/// État du menu Lecture : celui de la fenêtre de lecture au premier plan (S-103, S-104).
/// Comme `MenuState`, un `ObservableObject` observé par l'`App`, qui passe ses valeurs au menu :
/// un menu ne lit jamais l'état d'une fenêtre (voir `docs/FIXLOG.md`).
@MainActor
final class ReaderMenuState: ObservableObject {
    static let shared = ReaderMenuState()

    /// Ce que le menu affiche : éléments actifs et cochés.
    struct Values: Equatable {
        /// La fenêtre au premier plan lit un EPUB (ou un MOBI, un AZW3) : notes et comparaison possibles.
        var canRead = false
        var showsNotes = false
        var isComparing = false
        var isLocked = true
    }

    /// Commandes de la fenêtre au premier plan, appelées au choix d'un élément.
    struct Actions {
        var toggleNotes: () -> Void = {}
        var chooseCompanion: () -> Void = {}
        var toggleLock: () -> Void = {}
        var swapSides: () -> Void = {}
        var stopComparing: () -> Void = {}
    }

    @Published private(set) var values = Values()
    private(set) var actions = Actions()
    /// Fenêtre qui a rempli le menu : une autre qui passe à l'arrière-plan ne le vide pas.
    private var owner: UUID?

    func update(owner: UUID, values: Values, actions: Actions) {
        self.owner = owner
        self.actions = actions
        if values != self.values { self.values = values }
    }

    /// La fenêtre quitte le premier plan ou se ferme : le menu se grise, sauf si une autre l'a déjà repris.
    func clear(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        actions = Actions()
        if values != Values() { values = Values() }
    }
}

/// Menu Lecture : notes de bas de page et comparaison de la fenêtre de lecture au premier plan.
/// Les raccourcis y vivent : un raccourci ne vit que dans un menu.
struct ReaderCommands: Commands {
    let state: ReaderMenuState.Values
    /// Relues au moment du choix, comme `MenuState.current`.
    private var actions: ReaderMenuState.Actions { ReaderMenuState.shared.actions }

    var body: some Commands {
        CommandMenu("Lecture") {
            Toggle("Notes de bas de page", isOn: Binding(get: { state.showsNotes }, set: { _ in actions.toggleNotes() }))
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!state.canRead || state.isComparing)
            Divider()
            Button("Comparer avec un autre livre…") { actions.chooseCompanion() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!state.canRead)
            Toggle("Synchroniser les deux textes", isOn: Binding(get: { state.isComparing && state.isLocked }, set: { _ in actions.toggleLock() }))
                .disabled(!state.isComparing)
            Button("Échanger les côtés") { actions.swapSides() }
                .disabled(!state.isComparing)
            Button("Arrêter la comparaison") { actions.stopComparing() }
                .disabled(!state.isComparing)
        }
    }
}
