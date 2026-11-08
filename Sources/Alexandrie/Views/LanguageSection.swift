import AppKit
import SwiftUI

/// Réglages › Général › Langue (S-102) : la langue du système, ou une langue choisie pour Alexandrie seulement
/// (`AppleLanguages` dans ses réglages, comme Réglages Système › Langue et région › Applications).
/// macOS ne change la langue d'une app qu'au lancement : l'app propose de se relancer.
struct LanguageSection: View {
    /// Langues de l'interface, chacune nommée dans sa propre langue.
    static let languages: [(code: String, name: String)] = [
        ("fr", "Français"), ("en", "English"), ("nl", "Nederlands"), ("de", "Deutsch"), ("es", "Español"),
    ]
    static let key = "AppleLanguages"

    @State private var chosen: String = LanguageSection.current ?? ""
    @State private var asksRelaunch = false

    /// Langue choisie pour Alexandrie (nil : celle du système), lue dans ses seuls réglages.
    static var current: String? {
        guard let id = Bundle.main.bundleIdentifier,
              let list = UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String] else { return nil }
        return list.first.map { String($0.prefix(2)) }
    }

    var body: some View {
        Section("Langue") {
            Picker("Langue de l'interface", selection: $chosen) {
                Text("Langue du système").tag("")
                Divider()
                ForEach(Self.languages, id: \.code) { Text(verbatim: $0.name).tag($0.code) }
            }
            .onChange(of: chosen) { _, code in
                guard code != (Self.current ?? "") else { return }
                if code.isEmpty {
                    UserDefaults.standard.removeObject(forKey: Self.key)
                } else {
                    UserDefaults.standard.set([code], forKey: Self.key)
                }
                asksRelaunch = true
            }
            Text("Les exports et les notes envoyées à Zotero suivent aussi cette langue. Les titres, les notes et les dates déjà enregistrées ne sont pas traduits.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .alert("Relancer Alexandrie pour changer de langue ?", isPresented: $asksRelaunch) {
            Button("Relancer maintenant") { Self.relaunch() }
            Button("Plus tard", role: .cancel) {}
        } message: {
            Text("La nouvelle langue s'applique au prochain lancement.")
        }
    }

    /// Relance l'app une fois fermée (les données sont enregistrées à la fermeture).
    static func relaunch() {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? shell.run()
        NSApp.terminate(nil)
    }
}
