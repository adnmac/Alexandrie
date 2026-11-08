import AlexandrieCore
import SwiftUI

/// Réglages › Général : lien avec Zotero (S-092). Les envois se font depuis les notes d'un livre ou une thématique.
struct ZoteroSection: View {
    @Environment(ZoteroStore.self) private var zotero

    var body: some View {
        Section("Zotero") {
            LabeledContent("État") {
                HStack {
                    statusLabel
                    Button("Vérifier") { Task { await zotero.check() } }
                        .disabled(zotero.status == .checking)
                }
            }
            if zotero.status == .ready(authorized: true) {
                LabeledContent("Autorisation d'écrire") {
                    Button("Oublier") { zotero.forgetAuthorization() }
                        .help("Zotero redemandera l'autorisation au prochain envoi ; elle se retire aussi dans Zotero (Réglages › Avancés)")
                }
            }
            Text("« Envoyer à Zotero » (menu Exporter des notes d'un livre ou d'une thématique) copie les passages dans une note rattachée à la référence du livre, retrouvée ou créée ; un nouvel envoi met la note à jour. Vos notes restent dans Alexandrie. Zotero doit être ouvert, avec Réglages › Avancés › « Autoriser d'autres applications de cet ordinateur à communiquer avec Zotero » ; au premier envoi, choisissez « Toujours autoriser ». Rien ne passe par Internet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { if zotero.status == .unknown { await zotero.check() } }
    }

    @ViewBuilder private var statusLabel: some View {
        switch zotero.status {
        case .unknown, .checking:
            ProgressView().controlSize(.small)
        case .notRunning:
            Text("Zotero n'est pas ouvert").foregroundStyle(.secondary)
        case .disabled:
            Label("Accès des autres applications désactivé", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Palette.warning)
                .help(ZoteroError.localAPIDisabled.errorDescription ?? "")
        case .ready(let authorized):
            Label(authorized ? String(localized: "Relié") : String(localized: "Prêt (autorisation au premier envoi)"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Palette.success)
        case .failed(let message):
            Label("Injoignable", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Palette.warning)
                .help(message)
        }
    }
}
