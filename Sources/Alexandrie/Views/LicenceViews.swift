import AlexandrieCore
import SwiftUI

/// Réglages > Licence : état de l'essai ou de la licence, saisie de la clé, achat, textes légaux.
struct LicenceSettings: View {
    @Environment(\.openURL) private var openURL
    private let licensing = Licensing.shared
    @State private var key = ""
    @State private var refused = false

    var body: some View {
        Form {
            Section("Licence") {
                if let license = licensing.license {
                    LabeledContent("Licence de", value: license.name.isEmpty ? "—" : license.name)
                    LabeledContent("Numéro", value: license.id)
                    LabeledContent("Délivrée le", value: license.issued)
                    Button("Retirer la licence de ce Mac") { licensing.deactivate() }
                        .help("Pour l'installer sur un autre Mac ; la même clé pourra être saisie à nouveau")
                } else {
                    let days = licensing.remainingTrialDays
                    LabeledContent("État") {
                        Text(days > 0 ? "Essai : \(days) jour\(days > 1 ? "s" : "") restant\(days > 1 ? "s" : "")" : "Essai terminé")
                            .foregroundStyle(days > 3 ? Color.secondary : Palette.warning)
                    }
                    Text("Pendant l'essai, tout fonctionne. Ensuite, l'envoi à la Kindle demande une licence ; la bibliothèque, la lecture, les notes et la recherche restent disponibles.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Clé de licence") {
                        // La police à chasse fixe pour la clé seulement : le libellé reste celui des Réglages.
                        TextField("Clé de licence", text: $key, prompt: Text("ALX1-…"), axis: .vertical)
                            .labelsHidden()
                            .lineLimit(2...4)
                            .font(.callout.monospaced())
                            .multilineTextAlignment(.leading)
                            .onSubmit(activate)
                    }
                    HStack {
                        if refused {
                            Text("Cette clé n'est pas valide. Collez-la en entier, telle que reçue par e-mail.")
                                .font(.caption).foregroundStyle(Palette.danger)
                        }
                        Spacer()
                        if let store = licensing.storeURL {
                            Button("Acheter une licence…") { openURL(store) }
                        }
                        Button("Activer", action: activate)
                            .buttonStyle(.borderedProminent)
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            if licensing.termsURL != nil || licensing.privacyURL != nil {
                Section("Informations légales") {
                    if let terms = licensing.termsURL {
                        Button("Conditions de vente et de licence") { openURL(terms) }.buttonStyle(.link)
                    }
                    if let privacy = licensing.privacyURL {
                        Button("Politique de confidentialité") { openURL(privacy) }.buttonStyle(.link)
                    }
                }
            }
        }
    }

    private func activate() {
        refused = !licensing.activate(key)
        if !refused { key = "" }
    }
}

/// Bandeau des derniers jours d'essai, puis de l'essai terminé, dans la fenêtre principale.
struct TrialBanner: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL
    private let licensing = Licensing.shared

    var body: some View {
        let days = licensing.remainingTrialDays
        HStack(spacing: Space.md) {
            Image(systemName: "key.fill").foregroundStyle(Palette.warning).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(days > 0 ? "Plus que \(days) jour\(days > 1 ? "s" : "") d'essai" : "L'essai d'Alexandrie est terminé")
                    .font(.callout.weight(.semibold))
                Text(days > 0 ? "Ensuite, l'envoi à la Kindle demandera une licence."
                     : "L'envoi à la Kindle demande une licence ; le reste de l'app reste disponible.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.sm)
            if let store = licensing.storeURL {
                Button("Acheter…") { openURL(store) }
            }
            Button("Saisir la clé…") {
                UserDefaults.standard.set(SettingsTab.licence.rawValue, forKey: SettingsTab.storageKey)
                openSettings()
            }
        }
        .banner(Palette.warning)
        .overlay(alignment: .bottom) { Divider() }
    }
}
