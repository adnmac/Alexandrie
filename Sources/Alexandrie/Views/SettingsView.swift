import AlexandrieCore
import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    @Environment(UpdateMonitor.self) private var updates

    var body: some View {
        Form {
            Section("Bibliothèque") {
                LabeledContent("Dossier de livres") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(library.rootURL?.path ?? "Aucun").lineLimit(1).truncationMode(.middle)
                        Button("Changer…") { Panels.chooseLibraryFolder(library) }
                    }
                }
                Text("Ce dossier est lu sans jamais être modifié. Les livres importés, les couvertures et les conversions sont stockés dans le dossier de l'app.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Données de l'app") {
                    Button("Afficher dans le Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([library.directories.base])
                    }
                }
                LabeledContent("Fichiers indexés", value: "\(library.visibleBooks.count)")
                let hidden = library.hiddenDuplicates.count
                Toggle("Rassembler les doublons (\(hidden) copies masquées)", isOn: Binding(
                    get: { library.groupDuplicates }, set: { library.groupDuplicates = $0 }))
                Text("Pour un même livre et un même format, un seul fichier est affiché : le plus récent. Les autres copies restent sur le disque, intactes. Aussi dans le menu Présentation (⌥⌘D).")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Couvertures", value: library.cacheSize.map { size($0.covers) } ?? "…")
                LabeledContent("Conversions pour la Kindle") {
                    HStack {
                        Text(library.cacheSize.map { size($0.conversions) } ?? "…")
                        Button("Vider") { Task { await library.clearConversions() } }
                            .disabled(library.cacheSize?.conversions ?? 0 == 0)
                    }
                }
            }
            Section("Vérification en ligne") {
                Toggle("Vérifier automatiquement les nouveaux livres", isOn: Binding(
                    get: { library.autoCheckCatalog }, set: { library.autoCheckCatalog = $0 }))
                let unchecked = library.visibleBooks.filter { $0.catalogCheckedAt == nil }.count
                LabeledContent("Livres jamais vérifiés", value: "\(unchecked)")
                Button("Vérifier ces livres maintenant") { library.checkUncheckedBooks() }
                    .disabled(unchecked == 0)
                Text("L'ISBN, ou à défaut le titre et l'auteur, est envoyé au catalogue de la BnF puis à Open Library. Aucune information n'est modifiée sans votre accord : les corrections proposées apparaissent dans la fiche du livre.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Mises à jour") {
                Toggle("Vérifier au démarrage s'il existe une version plus récente", isOn: Binding(
                    get: { updates.autoCheck }, set: { updates.autoCheck = $0 }))
                LabeledContent("Version installée") {
                    Text(updates.currentCommit.map { String($0.prefix(7)) } ?? "inconnue (lancée hors bundle)")
                        .font(.callout.monospaced())
                }
                LabeledContent("État") {
                    HStack {
                        Text(updateStatus).foregroundStyle(.secondary)
                        Button("Vérifier") { Task { await updates.check() } }
                            .disabled(updates.currentCommit == nil || updates.status == .checking)
                    }
                }
                Text("Seul l'identifiant de la version installée est envoyé à GitHub (github.com/\(UpdateChecker.repository)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Kindle") {
                LabeledContent("Disque USB", value: "Pris en charge")
                LabeledContent("MTP (modèles récents)") {
                    if kindle.mtpAvailable {
                        Label("libmtp chargée", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        VStack(alignment: .trailing, spacing: 4) {
                            Label("libmtp absente", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("brew install libmtp").font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Hauteur limitée : le contenu défile (barre de défilement visible) au lieu de dépasser de l'écran.
        .scrollIndicators(.visible)
        .frame(width: 520, height: 620)
        .task { await library.refreshCacheSize() }
    }

    private var updateStatus: String {
        switch updates.status {
        case .idle: "Pas encore vérifié"
        case .checking: "Vérification…"
        case .upToDate: "À jour"
        case .available(let info): info.newCommits == 1 ? "1 modification disponible" : "\(info.newCommits) modifications disponibles"
        case .failed: "Vérification impossible"
        }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
