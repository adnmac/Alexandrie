import AlexandrieCore
import AppKit

/// Ce que la fenêtre de lecture fait des surlignages, appelé par les menus contextuels des pages (S-070 à S-073).
@MainActor
struct ReaderHighlightActions {
    /// Surligne la sélection ; vrai pour ouvrir aussitôt sa note.
    var highlight: (_ withNote: Bool) -> Void = { _ in }
    var editNote: (Clipping.ID) -> Void = { _ in }
    var delete: (Clipping.ID) -> Void = { _ in }
    /// Surlignage enregistré, pour son état dans le menu (note, couleur).
    var lookup: (Clipping.ID) -> Clipping? = { _ in nil }
    /// Couleurs ou thèmes proposés (S-076) : ceux d'un surlignage, ou (nil) ceux du prochain, dans la recherche choisie.
    var marks: (Clipping.ID?) -> [HighlightMark] = { _ in HighlightColor.allCases.map(HighlightMark.init) }
    /// Marque d'un surlignage, ou (nil) celle du prochain.
    var mark: (Clipping.ID?) -> HighlightMark = { _ in HighlightMark(.yellow) }
    /// Change la marque d'un surlignage, ou (nil) celle des prochains.
    var setMark: (Clipping.ID?, HighlightMark) -> Void = { _, _ in }
    /// Thématique choisie pour ce livre, nommée dans le menu.
    var researchName: () -> String? = { nil }
    /// Thématiques existantes (identifiant, nom), à cocher pour un surlignage (S-079).
    var thematics: () -> [(id: String, name: String)] = { [] }
    var setThematic: (Clipping.ID, String, Bool) -> Void = { _, _, _ in }
}

/// Entrées du menu contextuel d'une page : celles d'Alexandrie, en tête, à la place des commandes de
/// surlignage, de zoom et d'affichage de PDFKit et WebKit, qui n'enregistraient rien (S-073).
@MainActor
enum HighlightMenu {
    static func items(selection: Bool, highlight id: Clipping.ID?, actions: ReaderHighlightActions) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if selection {
            items.append(ClosureMenuItem(String(localized: "Surligner")) { actions.highlight(false) })
            items.append(ClosureMenuItem(String(localized: "Surligner et ajouter une note…")) { actions.highlight(true) })
            let title = actions.researchName().map { String(localized: "Couleur des surlignages (\($0))") } ?? String(localized: "Couleur des surlignages")
            items.append(markMenu(title, marks: actions.marks(nil), current: actions.mark(nil)) { actions.setMark(nil, $0) })
        }
        if let id, let clipping = actions.lookup(id) {
            if !items.isEmpty { items.append(.separator()) }
            items.append(ClosureMenuItem(clipping.hasNote ? String(localized: "Modifier la note…") : String(localized: "Ajouter une note…")) { actions.editNote(id) })
            items.append(markMenu("Couleur", marks: actions.marks(id), current: actions.mark(id)) { actions.setMark(id, $0) })
            let thematics = actions.thematics()
            if !thematics.isEmpty {
                // Thématiques à cocher : un passage peut en avoir plusieurs (S-079).
                let item = NSMenuItem(title: String(localized: "Thématiques"), action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: String(localized: "Thématiques"))
                for thematic in thematics {
                    let on = clipping.thematicIDs.contains(thematic.id)
                    let entry = ClosureMenuItem(thematic.name) { actions.setThematic(id, thematic.id, !on) }
                    entry.state = on ? .on : .off
                    submenu.addItem(entry)
                }
                item.submenu = submenu
                items.append(item)
            }
            items.append(ClosureMenuItem(String(localized: "Supprimer le surlignage")) { actions.delete(id) })
        }
        return items
    }

    /// Ajoute les entrées d'Alexandrie en tête du menu, séparées du reste.
    static func insert(_ items: [NSMenuItem], into menu: NSMenu) {
        guard !items.isEmpty else { return }
        if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
        for item in items.reversed() { menu.insertItem(item, at: 0) }
    }

    /// Retire les séparateurs en tête, en fin et en double laissés par les entrées retirées.
    static func tidy(_ menu: NSMenu) {
        var previousIsSeparator = true
        for item in menu.items {
            if item.isSeparatorItem && previousIsSeparator { menu.removeItem(item) } else { previousIsSeparator = item.isSeparatorItem }
        }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }

    /// Sous-menu des couleurs ou des thèmes : chaque entrée porte son nom à côté de sa pastille.
    private static func markMenu(_ title: String, marks: [HighlightMark], current: HighlightMark,
                                 choose: @escaping (HighlightMark) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        for mark in marks {
            let entry = ClosureMenuItem(mark.label) { choose(mark) }
            entry.state = mark.key == current.key ? .on : .off
            entry.image = swatch(mark)
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    private static func swatch(_ color: HighlightMark) -> NSImage {
        let side: CGFloat = 12
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor(color.swatch).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

/// Entrée de menu qui appelle une fonction.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) n'est pas utilisé") }

    @objc private func run() { handler() }
}
