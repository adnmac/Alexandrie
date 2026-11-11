import AppKit
import FolunaCore
import SwiftUI

/// Étiquettes de la fiche en jetons (S-106) : une étiquette par jeton, validée par Retour ou une virgule,
/// avec la complétion des étiquettes déjà présentes dans la bibliothèque.
///
/// La liste n'est enregistrée qu'à la validation d'un jeton, à sa suppression ou à la sortie du champ :
/// les lettres en cours de frappe ne deviennent jamais des étiquettes.
struct TagTokenField: NSViewRepresentable {
    @Binding var tags: [String]
    /// Étiquettes de la bibliothèque, proposées pendant la frappe.
    let suggestions: [String]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.tokenStyle = .rounded
        field.isBordered = false
        field.drawsBackground = false
        field.alignment = .right
        field.completionDelay = 0
        field.placeholderString = String(localized: "Ajouter une étiquette")
        field.setAccessibilityLabel(String(localized: "Étiquettes"))
        field.objectValue = tags
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        // Pendant la frappe, le champ garde sa saisie ; après ⌘Z ou un autre livre, il suit la fiche.
        if field.currentEditor() == nil, (field.objectValue as? [String]) ?? [] != tags {
            field.objectValue = tags
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: TagTokenField

        init(_ parent: TagTokenField) { self.parent = parent }

        /// Jetons validés du champ, sans la saisie en cours.
        private func committed(_ field: NSTokenField) -> [String] {
            TagNames.clean((field.objectValue as? [Any] ?? []).compactMap { $0 as? String })
        }

        private func publish(_ tags: [String]) {
            if tags != parent.tags { parent.tags = tags }
        }

        func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
            // Le champ ne contient le nouveau jeton qu'après ce retour.
            DispatchQueue.main.async { [weak self, weak tokenField] in
                guard let self, let tokenField else { return }
                self.publish(self.committed(tokenField))
            }
            return tokens
        }

        func controlTextDidChange(_ notification: Notification) {
            // Un jeton supprimé (touche Effacer) : la liste raccourcit sans passer par shouldAdd.
            guard let field = notification.object as? NSTokenField else { return }
            let tags = committed(field)
            if tags.count < parent.tags.count, Set(tags.map(TagNames.key)).isSubset(of: parent.tags.map(TagNames.key)) {
                publish(tags)
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            publish(committed(field))
        }

        func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String,
                        indexOfToken tokenIndex: Int, indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            let typed = TagNames.key(substring)
            guard !typed.isEmpty else { return [] }
            let present = Set(parent.tags.map(TagNames.key))
            return parent.suggestions.filter { TagNames.key($0).hasPrefix(typed) && !present.contains(TagNames.key($0)) }
        }
    }
}
