import FolunaCore
import SwiftUI

/// « Ajouter une liseuse USB » (S-098) : un disque amovible qui lit l'EPUB (PocketBook, Tolino…) devient une liseuse,
/// reconnue ensuite à chaque branchement. Jamais proposé pour un disque système ou un dossier de livres de la bibliothèque.
struct AddReaderSheet: View {
    @Environment(KindleMonitor.self) private var kindle
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [VolumeKindle]?
    @State private var chosen: String?
    @State private var folder = ""
    @State private var folders: [String] = []
    @State private var name = ""

    private var volume: VolumeKindle? { candidates?.first { $0.identifier == chosen } }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Label("Ajouter une liseuse USB", systemImage: "externaldrive.badge.plus").font(.title3.weight(.semibold))
            Text("Pour une liseuse qui lit l'EPUB et se branche comme un disque (PocketBook, Tolino…). Les Kindle et les Kobo sont reconnues d'elles-mêmes. Branchez la liseuse, puis choisissez-la.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let candidates {
                if candidates.isEmpty {
                    Label("Aucun disque amovible avec des livres n'est branché.", systemImage: "externaldrive.badge.questionmark")
                        .foregroundStyle(.secondary)
                } else {
                    Form {
                        Picker("Disque", selection: $chosen) {
                            ForEach(candidates, id: \.identifier) { Text($0.name).tag(String?.some($0.identifier)) }
                        }
                        Picker("Dossier des livres", selection: $folder) {
                            Text("Racine du disque").tag("")
                            ForEach(folders, id: \.self) { Text($0).tag($0) }
                        }
                        TextField("Nom", text: $name, prompt: Text("ex. PocketBook de Léa"))
                    }
                    .formStyle(.grouped)
                    .padding(.horizontal, -Space.margin)
                    Text("Les livres y sont envoyés en EPUB (ou en PDF), avec vos corrections ; ses notes ne sont pas lues.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Recherche des disques…").frame(maxWidth: .infinity)
            }
            HStack {
                Button("Actualiser") { Task { await load() } }
                Spacer()
                Button("Annuler") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Ajouter") {
                    guard let volume else { return }
                    Task {
                        await kindle.addGenericReader(volume, folder: folder, name: name)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(volume == nil)
            }
        }
        .padding(Space.margin)
        .frame(width: Layout.sheet)
        .noInitialFocus()
        .task { await load() }
        .onChange(of: chosen) { _, _ in pick() }
    }

    private func load() async {
        let excluded = library.folders.map { URL(fileURLWithPath: $0.path) }
        candidates = await kindle.genericCandidates(excludingFolders: excluded)
        if chosen == nil || volume == nil { chosen = candidates?.first?.identifier }
        pick()
    }

    /// Disque choisi : ses dossiers de premier niveau, le dossier proposé et son nom.
    private func pick() {
        guard let volume else { folders = []; return }
        folders = ((try? FileManager.default.contentsOfDirectory(at: volume.root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        folder = volume.suggestedBooksFolder
        name = volume.name
    }
}
