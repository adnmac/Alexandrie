import AlexandrieCore
import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle

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
                LabeledContent("Livres indexés", value: "\(library.books.count)")
            }
            Section("Vérification en ligne") {
                Toggle("Vérifier automatiquement les nouveaux livres", isOn: Binding(
                    get: { library.autoCheckCatalog }, set: { library.autoCheckCatalog = $0 }))
                let unchecked = library.books.filter { $0.catalogCheckedAt == nil }.count
                LabeledContent("Livres jamais vérifiés", value: "\(unchecked)")
                Button("Vérifier ces livres maintenant") { library.checkUncheckedBooks() }
                    .disabled(unchecked == 0)
                Text("L'ISBN, ou à défaut le titre et l'auteur, est envoyé au catalogue de la BnF puis à Open Library. Aucune information n'est modifiée sans votre accord : les corrections proposées apparaissent dans la fiche du livre.")
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
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
