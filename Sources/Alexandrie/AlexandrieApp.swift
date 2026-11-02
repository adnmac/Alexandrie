import AlexandrieCore
import AppKit
import SwiftUI

@main
struct AlexandrieApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var library = LibraryStore()
    @State private var kindle = KindleMonitor()
    @State private var updates = UpdateMonitor()

    var body: some Scene {
        WindowGroup("Alexandrie", id: "main") {
            ContentView()
                .environment(library)
                .environment(kindle)
                .environment(updates)
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Importer des livres…") { Panels.importBooks(into: library) }
                    .keyboardShortcut("o")
                Button("Rescanner la bibliothèque") { Task { await library.rescan() } }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView()
                .environment(library)
                .environment(kindle)
                .environment(updates)
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

    /// Confirmation avant de supprimer un livre importé (copie dans le dossier de l'app).
    static func confirmRemoveImported(_ book: Book) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Supprimer définitivement le fichier importé de « \(book.title) » ?"
        alert.informativeText = """
            Ce fichier (\(book.format.label)), copié dans le dossier d'Alexandrie lors de l'import, sera effacé du disque \
            et retiré de la bibliothèque. Les autres fichiers du même livre et le fichier d'origine, s'il existe encore \
            ailleurs, ne sont pas touchés.

            Pour seulement retirer le livre d'une liste (envoyés, en attente), utilisez « Retirer de la liste ».
            """
        alert.addButton(withTitle: "Supprimer").hasDestructiveAction = true
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
