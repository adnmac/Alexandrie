import AlexandrieCore
import AppKit
import SwiftUI

/// Sauvegardes de l'index : dernière copie, restauration (avec confirmation).
struct BackupsRow: View {
    @Environment(LibraryStore.self) private var library
    @State private var chosen: IndexBackups.Backup?

    var body: some View {
        let backups = library.backups
        LabeledContent("Dernière sauvegarde") {
            HStack {
                Text(backups.first.map { $0.date.formatted(date: .long, time: .omitted) } ?? "aucune")
                    .foregroundStyle(.secondary)
                Menu("Restaurer…") {
                    ForEach(backups, id: \.url) { b in
                        Button(b.date.formatted(date: .complete, time: .omitted)) { chosen = b }
                    }
                }
                .fixedSize()
                .disabled(backups.isEmpty)
                Button("Afficher") { NSWorkspace.shared.activateFileViewerSelecting([library.directories.backups]) }
            }
        }
        .confirmationDialog("Revenir à la sauvegarde du \(chosen?.date.formatted(date: .long, time: .omitted) ?? "") ?",
                            isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } })) {
            Button("Restaurer") {
                if let b = chosen { Task { await library.restoreBackup(b) } }
            }
        } message: {
            Text("Les corrections, étagères et autres changements faits depuis seront remplacés. L'état actuel est d'abord mis de côté dans le dossier des sauvegardes ; vos fichiers de livres ne sont pas touchés.")
        }
    }
}

/// Liseuse dans les réglages : renommer, oublier.
struct ReaderRow: View {
    @Environment(KindleMonitor.self) private var kindle
    @Environment(LibraryStore.self) private var library
    let reader: Reader
    @State private var name = ""

    var body: some View {
        LabeledContent {
            HStack {
                if kindle.deviceID == reader.id {
                    Label("Branchée", systemImage: "circle.fill").labelStyle(.iconOnly).foregroundStyle(Palette.success)
                        .help("Branchée en ce moment")
                }
                Text("vue le \(reader.lastSeenAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Oublier", role: .destructive) {
                    library.clearShelf(reader.id)
                    kindle.forget(reader.id)
                }
                .help("Oublier cette liseuse et vider son étagère (aucun livre n'est supprimé) ; elle sera de nouveau nommée à sa prochaine connexion")
            }
        } label: {
            TextField("Nom", text: $name).onSubmit { kindle.rename(reader.id, to: name) }
                .textFieldStyle(.plain)
        }
        .onAppear { name = reader.name }
    }
}

/// Onglets des réglages, dans l'ordre des réglages Mac.
enum SettingsTab: String, CaseIterable {
    case general, library, kindle

    static let storageKey = "settingsTab"

    var title: String {
        switch self {
        case .general: "Général"
        case .library: "Bibliothèque"
        case .kindle: "Kindle"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .library: "books.vertical"
        case .kindle: "ipad.landscape"
        }
    }
}

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(KindleMonitor.self) private var kindle
    @Environment(UpdateMonitor.self) private var updates

    /// Onglet affiché, rouvert au même endroit (et choisi par le mode capture).
    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Form {
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
                        Text(updates.currentVersion + (updates.currentCommit.map { " (\($0.prefix(7)))" } ?? ""))
                            .font(.callout.monospaced())
                    }
                    LabeledContent("État") {
                        HStack {
                            Text(updateStatus).foregroundStyle(.secondary)
                            Button("Vérifier") { Task { await updates.check() } }
                                .disabled(updates.status == .checking)
                        }
                    }
                    Text("Seul l'identifiant de la version installée est envoyé à GitHub (github.com/\(UpdateChecker.repository)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .fitsContent()
            .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.symbol) }
            .tag(SettingsTab.general)

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
                    let missing = library.booksWithoutCover
                    LabeledContent("Livres sans couverture") {
                        HStack {
                            if let p = library.coverSearch {
                                ProgressView(value: Double(p.done), total: Double(max(1, p.total))).frame(width: 80)
                                Text("\(p.done)/\(p.total)").font(.caption.monospacedDigit())
                            } else {
                                if let r = library.lastCoverSearch {
                                    Text("\(r.found) trouvée(s) sur \(r.searched)").font(.caption).foregroundStyle(.secondary)
                                }
                                Text("\(missing.count)")
                                Button("Chercher sur Open Library") { Task { await library.findCovers(for: missing) } }
                                    .disabled(missing.isEmpty)
                            }
                        }
                    }
                    LabeledContent("Conversions pour la Kindle") {
                        HStack {
                            Text(library.cacheSize.map { size($0.conversions) } ?? "…")
                            Button("Vider") { Task { await library.clearConversions() } }
                                .disabled(library.cacheSize?.conversions ?? 0 == 0)
                        }
                    }
                }
                Section("Sauvegardes") {
                    BackupsRow()
                    Text("Chaque jour, au premier lancement, l'index (vos corrections, étagères, corbeille…) est copié avant tout changement ; les 10 dernières copies sont gardées.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .fitsContent()
            .tabItem { Label(SettingsTab.library.title, systemImage: SettingsTab.library.symbol) }
            .tag(SettingsTab.library)

            Form {
                Section("Liseuses") {
                    if kindle.readers.isEmpty {
                        Text("Aucune liseuse pour l'instant : branchez une Kindle pour lui donner un nom.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(kindle.readers) { reader in
                        ReaderRow(reader: reader)
                    }
                    Text("Chaque Kindle est reconnue par son numéro de série et garde son nom d'une connexion à l'autre.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Kindle") {
                    LabeledContent("Disque USB", value: "Pris en charge")
                    LabeledContent("MTP (modèles récents)") {
                        if kindle.mtpAvailable {
                            Label("libmtp chargée", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.success)
                        } else {
                            VStack(alignment: .trailing, spacing: 4) {
                                Label("libmtp absente", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                                Text("brew install libmtp").font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .fitsContent()
            .tabItem { Label(SettingsTab.kindle.title, systemImage: SettingsTab.kindle.symbol) }
            .tag(SettingsTab.kindle)
        }
        // Largeur des réglages Mac ; la hauteur suit l'onglet (fitsContent).
        .frame(width: Layout.settingsWidth)
        .noInitialFocus()
        .task { await library.refreshCacheSize() }
    }

    private var updateStatus: String {
        switch updates.status {
        case .idle: "Pas encore vérifié"
        case .checking: "Vérification…"
        case .upToDate: "À jour"
        case .available(let info): info.newCommits == 1 ? "1 modification disponible" : "\(info.newCommits) modifications disponibles"
        case .release(let r): "Version \(r.version) disponible"
        case .failed: "Vérification impossible"
        }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
