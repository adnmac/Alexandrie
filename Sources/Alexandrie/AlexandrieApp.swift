import AlexandrieCore
import AppKit
import SwiftUI

struct AlexandrieApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var library = LibraryStore()
    @State private var kindle = KindleMonitor()
    @State private var updates = UpdateMonitor()
    /// Observé ici : l'App reconstruit les menus Livre et Kindle quand la sélection change.
    @ObservedObject private var menu = MenuState.shared

    var body: some Scene {
        WindowGroup("Alexandrie", id: "main") {
            ContentView()
                .environment(library)
                .environment(kindle)
                .environment(updates)
                .frame(minWidth: 960, minHeight: 600)
                // ALEXANDRIE_GRID=1 : grille de 8 pt, zones et sondes dessinées sur la fenêtre.
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
            KindleCommands(kindle: kindle, state: menu.values)
        }

        Settings {
            SettingsView()
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
        // Mêmes intitulés que le menu du livre (clic droit) et la fiche. Envoyer à la Kindle (⌘K) est
        // dans le menu Kindle : un raccourci ne vit que dans un menu.
        CommandMenu("Livre") {
            // ⌘Y comme dans le Finder ; Espace est gérée par la grille, pour ne pas voler l'espace des champs.
            Button("Coup d'œil") { books?.toggleQuickLook() }
                .keyboardShortcut("y")
                .disabled(!state.canQuickLook)
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
        CommandMenu("Kindle") {
            Button(state.sendTitle) { books?.send() }
                .keyboardShortcut("k")
                .disabled(!state.canSend)
            Divider()
            Button("Actualiser") { Task { await kindle.refresh() } }
            Button("Éjecter la Kindle") { Task { await kindle.eject() } }
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
enum Panels {
    static func chooseLibraryFolder(_ library: LibraryStore) {
        let panel = NSOpenPanel()
        panel.title = "Choisir le dossier de livres"
        panel.message = "Alexandrie indexe ce dossier sans jamais le modifier."
        panel.prompt = "Choisir"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { library.chooseFolder(url) }
    }

    static func importBooks(into library: LibraryStore) {
        let panel = NSOpenPanel()
        panel.title = "Importer des livres"
        panel.allowedContentTypes = BookFormat.allCases.compactMap { .init(filenameExtension: $0.rawValue) }
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { library.importFiles(panel.urls) }
    }

    /// Confirmation avant de placer les fichiers d'un livre de la corbeille dans la Corbeille de macOS.
    static func confirmDeletePermanently(_ book: Book, fileCount: Int) -> Bool {
        confirm(title: "Supprimer définitivement « \(book.title) » ?",
                message: (fileCount == 1 ? "Son fichier sera placé" : "Ses \(fileCount) fichiers seront placés")
                    + " dans la Corbeille de macOS et le livre quittera Alexandrie. Les fichiers resteront récupérables "
                    + "dans la Corbeille de macOS tant que vous ne la videz pas.",
                action: "Supprimer")
    }

    static func confirmEmptyTrash(fileCount: Int) -> Bool {
        confirm(title: "Vider la corbeille d'Alexandrie ?",
                message: (fileCount == 1 ? "Le fichier sera placé" : "Les \(fileCount) fichiers seront placés")
                    + " dans la Corbeille de macOS et ces livres quitteront Alexandrie. Ils resteront récupérables "
                    + "dans la Corbeille de macOS tant que vous ne la videz pas.",
                action: "Vider la corbeille")
    }

    private static func confirm(title: String, message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action).hasDestructiveAction = true
        alert.addButton(withTitle: "Annuler")
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
            panel.title = "Exporter en EPUB"
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
