import AlexandrieCore
import AppKit
import SwiftUI

/// Un dossier de livres dans Réglages > Bibliothèque : chemin, nombre de livres, retrait confirmé (S-060, S-063).
struct FolderRow: View {
    @Environment(LibraryStore.self) private var library
    let folder: LibraryFolders.Entry
    @State private var confirming = false

    var body: some View {
        let unavailable = library.unavailableFolders.contains(folder.path)
        let count = library.books(inFolder: folder.path).count
        LabeledContent {
            HStack {
                Text(unavailable ? String(localized: "Indisponible") : String(localized: "\(count) livres"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Retirer…") { confirming = true }
                    .disabled(library.folders.count < 2)
                    .help(library.folders.count < 2 ? String(localized: "La bibliothèque garde au moins un dossier de livres")
                          : String(localized: "Retirer ce dossier de la bibliothèque ; ses fichiers restent sur le disque"))
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(LibraryFolders.name(of: folder.path))
                    Text(folder.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            } icon: {
                Image(systemName: unavailable ? "externaldrive.badge.xmark" : "folder")
            }
            .help(unavailable ? String(localized: "Disque débranché ou dossier introuvable : ses livres reviendront quand il sera rebranché") : folder.path)
        }
        .confirmationDialog("Retirer « \(LibraryFolders.name(of: folder.path)) » de la bibliothèque ?", isPresented: $confirming) {
            Button("Retirer le dossier", role: .destructive) { library.removeFolder(folder.path) }
        } message: {
            Text(count == 1 ? String(localized: "1 livre quitte la bibliothèque, avec sa place sur les étagères et dans l'attente d'envoi. Le fichier reste sur le disque.")
                 : String(localized: "\(count) livres quittent la bibliothèque, avec leur place sur les étagères et dans l'attente d'envoi. Les fichiers restent sur le disque."))
        }
    }
}

/// Sauvegardes de l'index : dernière copie, restauration (avec confirmation).
struct BackupsRow: View {
    @Environment(LibraryStore.self) private var library
    @State private var chosen: IndexBackups.Backup?

    var body: some View {
        let backups = library.backups
        LabeledContent("Dernière sauvegarde") {
            HStack {
                // Text(String) ne traduit pas : « aucune » passe par sa propre clé du catalogue.
                Group {
                    if let last = backups.first {
                        Text(last.date.formatted(date: .long, time: .omitted))
                    } else {
                        Text("aucune")
                    }
                }
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
                Text("\(reader.brand.label) · vue le \(reader.lastSeenAt.formatted(date: .abbreviated, time: .omitted))")
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
    case general, library, formats, backup, kindle

    static let storageKey = "settingsTab"

    var title: String {
        switch self {
        case .general: String(localized: "Général")
        case .library: String(localized: "Bibliothèque")
        case .formats: String(localized: "Formats")
        case .backup: String(localized: "Sauvegarde")
        case .kindle: String(localized: "Liseuses")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .library: "books.vertical"
        case .formats: "puzzlepiece.extension"
        case .backup: "externaldrive.badge.icloud"
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
    @State private var addsReader = false

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
                ZoteroSection()
                LanguageSection()
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
                Section("Dossiers de livres") {
                    ForEach(library.folders, id: \.path) { folder in FolderRow(folder: folder) }
                    LabeledContent {
                        Button("Ajouter un dossier…") { Panels.addLibraryFolder(library) }
                    } label: {
                        Text("Ces dossiers sont lus sans jamais être modifiés. Les livres importés, les couvertures et les conversions sont stockés dans le dossier de l'app.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Bibliothèque") {
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
                    LabeledContent("Conversions pour les liseuses") {
                        HStack {
                            Text(library.cacheSize.map { size($0.conversions) } ?? "…")
                            Button("Vider") { Task { await library.clearConversions() } }
                                .disabled(library.cacheSize?.conversions ?? 0 == 0)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .fitsContent()
            .tabItem { Label(SettingsTab.library.title, systemImage: SettingsTab.library.symbol) }
            .tag(SettingsTab.library)

            Form {
                FormatsSection()
            }
            .formStyle(.grouped)
            .fitsContent()
            .tabItem { Label(SettingsTab.formats.title, systemImage: SettingsTab.formats.symbol) }
            .tag(SettingsTab.formats)

            // Sauvegardes : copie hors du Mac (iCloud Drive, disque externe) d'abord, copies locales ensuite.
            Form {
                ExternalBackupSection()
                Section("Sauvegardes sur ce Mac") {
                    BackupsRow()
                    Text("Chaque jour, au premier lancement, l'index (vos corrections, étagères, corbeille…) est copié avant tout changement ; les 10 dernières copies sont gardées.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .fitsContent()
            .tabItem { Label(SettingsTab.backup.title, systemImage: SettingsTab.backup.symbol) }
            .tag(SettingsTab.backup)

            Form {
                Section("Liseuses") {
                    if kindle.readers.isEmpty {
                        Text("Aucune liseuse pour l'instant : branchez une Kindle ou une Kobo pour lui donner un nom.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(kindle.readers) { reader in
                        ReaderRow(reader: reader)
                    }
                    LabeledContent {
                        Button("Ajouter une liseuse USB…") { addsReader = true }
                    } label: {
                        Text("Kindle et Kobo sont reconnues d'elles-mêmes et gardent leur nom d'une connexion à l'autre. Une autre liseuse qui lit l'EPUB (PocketBook, Tolino…) s'ajoute ici.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .sheet(isPresented: $addsReader) { AddReaderSheet() }
                Section("Kindle") {
                    LabeledContent("Disque USB", value: String(localized: "Pris en charge"))
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
        case .idle: String(localized: "Pas encore vérifié")
        case .checking: String(localized: "Vérification…")
        case .upToDate: String(localized: "À jour")
        case .available(let info): info.newCommits == 1 ? String(localized: "1 modification disponible") : String(localized: "\(info.newCommits) modifications disponibles")
        case .release(let r): String(localized: "Version \(r.version) disponible")
        case .failed: String(localized: "Vérification impossible")
        }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Formats pris en charge par les importeurs, activables un par un. Tous le sont à l'installation.
struct FormatsSection: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Section {
            ForEach(BookFormat.allCases.filter(\.isOptional), id: \.self) { format in
                Toggle(isOn: Binding(get: { !library.disabledFormats.contains(format) },
                                     set: { library.setFormat(format, enabled: $0) })) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(Self.name(format))
                        Text(Self.detail(format)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Formats supplémentaires")
        } footer: {
            Text("EPUB, MOBI, AZW3, AZW et PDF sont toujours pris en charge. Désactiver un format ne supprime rien : ses livres restent dans la bibliothèque avec leurs corrections et leurs notes, sans être lus ni envoyés, et reviennent dès qu'il est réactivé.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    static func name(_ format: BookFormat) -> String {
        switch format {
        case .prc: String(localized: "PRC (Mobipocket)")
        case .fb2: String(localized: "FictionBook (FB2)")
        case .cbz: String(localized: "Bandes dessinées (CBZ)")
        case .txt: String(localized: "Texte brut (TXT)")
        default: format.label
        }
    }

    static func detail(_ format: BookFormat) -> String {
        switch format {
        case .prc: String(localized: "Anciens livres Kindle et Mobipocket, lus comme un MOBI.")
        case .fb2: String(localized: "Fichiers .fb2 et .fb2.zip, convertis en EPUB, ou en AZW3 pour la Kindle.")
        case .cbz: String(localized: "Une image par page : envoyées telles quelles à la Kobo, en PDF à la Kindle.")
        case .txt: String(localized: "Ajoutés par import ou glisser-déposer seulement, pas en parcourant les dossiers. Convertis en EPUB, ou en AZW3 pour la Kindle.")
        default: ""
        }
    }
}
