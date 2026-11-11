import FolunaCore
import AppKit
import SwiftUI

struct FolunaApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    // Partagés avec les actions Raccourcis (AppServices), qui n'ont pas de vue.
    @State private var library = AppServices.shared.library
    @State private var kindle = AppServices.shared.kindle
    @State private var updates = AppServices.shared.updates
    @State private var reading = AppServices.shared.reading
    @State private var researches = AppServices.shared.researches
    @State private var contentIndexer = AppServices.shared.contentIndexer
    @State private var opds = AppServices.shared.opds
    @State private var backups = AppServices.shared.backups
    @State private var zotero = AppServices.shared.zotero
    /// Observé ici : l'App reconstruit les menus Livre et Kindle quand la sélection change.
    @ObservedObject private var menu = MenuState.shared
    /// Observé ici : le menu Lecture suit la fenêtre de lecture au premier plan.
    @ObservedObject private var readerMenu = ReaderMenuState.shared

    var body: some Scene {
        WindowGroup("Foluna", id: "main") {
            ContentView()
                .environment(library)
                .environment(kindle)
                .environment(updates)
                .environment(reading)
                .environment(researches)
                .environment(contentIndexer)
                .environment(opds)
                .environment(zotero)
                .frame(minWidth: 960, minHeight: 600)
                // FOLUNA_GRID=1 : grille de 8 pt, zones et sondes dessinées sur la fenêtre.
                .overlay { if GridOverlay.enabled { GridOverlay() } }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Rechercher les mises à jour…") { Task { await updates.checkManually() } }
            }
            CommandGroup(after: .newItem) {
                Button("Importer des livres…") { Panels.importBooks(into: library) }
                    .keyboardShortcut("o")
                Button("Rescanner la bibliothèque") { Task { await library.rescan() } }
                    .keyboardShortcut("r")
            }
            LibraryViewCommands()
            BookMenuCommands(state: menu.values)
            ReaderCommands(state: readerMenu.values)
            KindleCommands(kindle: kindle, state: menu.values)
        }

        // Fenêtre de lecture (S-066) : une par livre ; rouvrir un livre ramène sa fenêtre devant.
        WindowGroup("Lecture", id: "lecture", for: String.self) { $bookID in
            ReaderWindow(bookID: bookID)
                .environment(library)
                .environment(kindle)
                .environment(reading)
                .environment(researches)
                .frame(minWidth: 480, minHeight: 560)
        }
        .defaultSize(width: 760, height: 940)
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(backups)
                .environment(zotero)
                .environment(library)
                .environment(kindle)
                .environment(updates)
        }
        .windowResizability(.contentSize)
    }
}

/// Menu Livre : commandes sur les livres sélectionnés dans la fenêtre au premier plan.
struct BookMenuCommands: Commands {
    let state: MenuState.Values
    /// Relues au moment du choix : la sélection a pu changer depuis la construction du menu.
    private var books: BookCommands? { MenuState.shared.current }

    var body: some Commands {
        // Mêmes intitulés que le menu du livre (clic droit) et la fiche. Envoyer à la liseuse (⌘K) est
        // dans le menu Kindle : un raccourci ne vit que dans un menu.
        CommandMenu("Livre") {
            // ⌘Y comme dans le Finder ; Espace est gérée par la grille, pour ne pas voler l'espace des champs.
            Button("Lire") { books?.read() }
                .keyboardShortcut("l")
                .disabled(!state.canRead)
            Button("Coup d'œil") { books?.toggleQuickLook() }
                .keyboardShortcut("y")
                .disabled(!state.canQuickLook)
            // ⌘D comme les signets de Safari (S-107) ; ⌥⌘D reste « Rassembler les doublons ».
            Button(state.favoriteTitle) { books?.toggleFavorite() }
                .keyboardShortcut("d")
                .disabled(!state.canFavorite)
            // Pas de ⌘↓ : il déplacerait le curseur en fin de texte dans les champs.
            Button("Ouvrir") { books?.open() }
                .disabled(!state.canOpen)
            Button("Afficher dans le Finder") { books?.reveal() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!state.canReveal)
            // Sous-menu du système (AirDrop, Mail, Messages…), avec les fichiers de la sélection.
            ShareLink(items: state.shareURLs) { Text("Partager") }
                .disabled(state.shareURLs.isEmpty)
            Divider()
            Button("Exporter en EPUB…") { books?.exportEPUB() }
                .disabled(!state.canExportEPUB)
            Divider()
            Button("Mettre à la corbeille") { books?.trash() }
                .keyboardShortcut(.delete)
                .disabled(!state.canTrash)
        }
    }
}

/// Menu Kindle. Envoyer agit sur la sélection de la fenêtre au premier plan (`BookCommands`) ;
/// Actualiser et Éjecter restent actifs : sans Kindle à éjecter, un message l'explique.
struct KindleCommands: Commands {
    let kindle: KindleMonitor
    let state: MenuState.Values
    private var books: BookCommands? { MenuState.shared.current }

    var body: some Commands {
        CommandMenu("Liseuse") {
            Button(state.sendTitle) { books?.send() }
                .keyboardShortcut("k")
                .disabled(!state.canSend)
            Divider()
            Button("Actualiser") { Task { await kindle.refresh() } }
            Button("Éjecter la liseuse") { Task { await kindle.eject() } }
                .keyboardShortcut("e")
        }
    }
}

/// Menu Présentation. Les menus ne suivent pas l'état observé de l'app : le réglage est lu directement
/// (`@AppStorage`), et `LibraryStore` se met à jour quand il change.
struct LibraryViewCommands: Commands {
    @AppStorage(LibraryStore.showDuplicatesKey) private var showDuplicates = false

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Toggle("Rassembler les doublons", isOn: Binding(get: { !showDuplicates }, set: { showDuplicates = !$0 }))
                .keyboardShortcut("d", modifiers: [.command, .option])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nécessaire quand le binaire est lancé hors bundle (swift run).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Rapports de plantage remis par macOS au lancement suivant (audit, § 4).
        CrashReports.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
enum Panels {
    /// Accueil (premier dossier) et Réglages > Bibliothèque > Ajouter un dossier….
    static func addLibraryFolder(_ library: LibraryStore) {
        let panel = NSOpenPanel()
        panel.title = library.folders.isEmpty ? String(localized: "Choisir le dossier de livres") : String(localized: "Ajouter un dossier de livres")
        panel.message = String(localized: "Foluna indexe ce dossier sans jamais le modifier.")
        panel.prompt = library.folders.isEmpty ? String(localized: "Choisir") : String(localized: "Ajouter")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let refusal = library.addFolder(url) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Dossier non ajouté")
        alert.informativeText = refusal
        alert.runModal()
    }

    static func importBooks(into library: LibraryStore) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Importer des livres")
        panel.allowedContentTypes = BookFormat.allCases.compactMap { .init(filenameExtension: $0.rawValue) }
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { library.importFiles(panel.urls) }
    }

    /// Confirmation avant de placer les fichiers d'un livre de la corbeille dans la Corbeille de macOS.
    static func confirmDeletePermanently(_ book: Book, fileCount: Int) -> Bool {
        confirm(title: String(localized: "Supprimer définitivement « \(book.title) » ?"),
                message: (fileCount == 1 ? String(localized: "Son fichier sera placé") : String(localized: "Ses \(fileCount) fichiers seront placés"))
                    + String(localized: " dans la Corbeille de macOS et le livre quittera Foluna. Les fichiers resteront récupérables ")
                    + String(localized: "dans la Corbeille de macOS tant que vous ne la videz pas."),
                action: String(localized: "Supprimer"))
    }

    static func confirmEmptyTrash(fileCount: Int) -> Bool {
        confirm(title: String(localized: "Vider la corbeille de Foluna ?"),
                message: (fileCount == 1 ? String(localized: "Le fichier sera placé") : String(localized: "Les \(fileCount) fichiers seront placés"))
                    + String(localized: " dans la Corbeille de macOS et ces livres quitteront Foluna. Ils resteront récupérables ")
                    + String(localized: "dans la Corbeille de macOS tant que vous ne la videz pas."),
                action: String(localized: "Vider la corbeille"))
    }

    /// Étiquettes (S-106) : supprimer retire l'étiquette des livres, sans toucher aux livres.
    static func confirmDeleteTag(_ name: String, bookCount: Int) -> Bool {
        confirm(title: String(localized: "Supprimer l'étiquette « \(name) » ?"),
                message: bookCount == 1 ? String(localized: "Elle sera retirée du livre qui la porte. Le livre reste dans la bibliothèque.")
                    : String(localized: "Elle sera retirée des \(bookCount) livres qui la portent. Les livres restent dans la bibliothèque."),
                action: String(localized: "Supprimer"))
    }

    /// Nom d'une étiquette, nouvelle ou renommée ; nil si l'on annule ou si le nom est vide.
    static func askTagName(title: String, action: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: initial)
        field.placeholderString = String(localized: "Nom de l'étiquette")
        field.frame.size.width = Layout.alertFieldWidth
        alert.accessoryView = field
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: String(localized: "Annuler"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return TagNames.key(name).isEmpty ? nil : name
    }

    private static func confirm(title: String, message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Annuler"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Convertit un MOBI/AZW3 en EPUB puis propose où l'enregistrer.
    static func exportEPUB(_ book: Book, library: LibraryStore) async {
        let directories = library.directories
        do {
            let file = try await Task.detached(priority: .userInitiated) {
                try KindleTransfer.exportEPUB(book, directories: directories)
            }.value
            let panel = NSSavePanel()
            panel.title = String(localized: "Exporter en EPUB")
            panel.nameFieldStringValue = "\(book.title)".safeFilename + ".epub"
            panel.allowedContentTypes = [.init(filenameExtension: "epub")!]
            if panel.runModal() == .OK, let dest = panel.url {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: file, to: dest)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            }
        } catch {
            library.lastError = error.localizedDescription
        }
    }
}
