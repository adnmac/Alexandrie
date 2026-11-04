import AlexandrieCore
import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// Mode capture pour les agents (voir `scripts/snap.sh`) :
///
///     ALEXANDRIE_STORE=/tmp/… ALEXANDRIE_SEED=1 ALEXANDRIE_SNAPSHOT=/tmp/alexandrie-shots Alexandrie
///
/// écrit `<page>-light.png` et `<page>-dark.png` pour chaque page de la barre latérale, puis
/// `reglages-light.png` et `reglages-dark.png`, et quitte. `ALEXANDRIE_SNAPSHOT_PAGES=tous,notes`
/// limite les pages (ajouter `reglages` pour les réglages). Jamais sur les vraies données.
@MainActor
enum Snapshot {
    static var directory: String? {
        ProcessInfo.processInfo.environment["ALEXANDRIE_SNAPSHOT"].flatMap { $0.isEmpty ? nil : $0 }
    }

    struct Page {
        var name: String
        var item: SidebarItem
        /// Livre affiché dans la fiche (titre).
        var book: String? = nil
        var notes: String? = nil
    }

    static func pages(_ library: LibraryStore) -> [Page] {
        [
            Page(name: "tous", item: .all, book: "Le Port des brumes"),
            Page(name: "recents", item: .recent),
            Page(name: "envoyes", item: .sent),
            Page(name: "a-verifier", item: .toReview),
            Page(name: "notes", item: .notes, notes: ShelfSync.normalize("Le Port des brumes")),
            Page(name: "corbeille", item: .trash),
            Page(name: "en-attente", item: .pending),
            Page(name: "kindle", item: .kindle),
            Page(name: "format-azw3", item: .format(.azw3)),
            Page(name: "serie", item: .series(SeriesNames.key("Commissaire Vidal")), book: "Mort à marée basse"),
            Page(name: "genre", item: .genre(GenreNames.key("Policier"))),
            Page(name: "auteur", item: .author(AuthorNames.key("Inès Garnier")),
                 book: "Une très longue histoire de la cartographie des mers du Nord, de l'Antiquité à nos jours"),
        ]
    }

    static func run(library: LibraryStore, sidebar: Binding<SidebarItem?>, selection: Binding<Set<String>>,
                    notesBook: Binding<String?>, openSettings: OpenSettingsAction) async {
        guard let dir = directory else { return }
        guard AppDirectories.testStore != nil else {
            print("SNAPSHOT refusé : ALEXANDRIE_STORE doit désigner un dossier de test dans /tmp")
            NSApp.terminate(nil)
            return
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        let only = ProcessInfo.processInfo.environment["ALEXANDRIE_SNAPSHOT_PAGES"]
            .map { Set($0.split(separator: ",").map(String.init)) }
        // Un écran en veille ne donne rien à screencapture : l'activité déclarée le réveille.
        var activity: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Captures" as CFString, kIOPMUserActiveLocal, &activity)
        var awake: IOPMAssertionID = 0
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn), "Captures" as CFString, &awake)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Indexation des livres d'exemple, puis ce qu'une personne y aurait fait.
        let end = Date().addingTimeInterval(30)
        while (library.isScanning || library.books.count < SeedData.samples.count) && Date() < end {
            try? await Task.sleep(for: .milliseconds(100))
        }
        SeedData.prepare(library)
        try? await Task.sleep(for: .seconds(1.5))

        for mode in ["light", "dark"] {
            NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
            for page in pages(library) where only?.contains(page.name) ?? true {
                sidebar.wrappedValue = page.item
                selection.wrappedValue = page.book.flatMap { t in library.visibleBooks.first { $0.title == t } }
                    .map { [$0.id] } ?? []
                if let notes = page.notes { notesBook.wrappedValue = notes }
                try? await Task.sleep(for: .seconds(0.8))
                capture(to: "\(dir)/\(page.name)-\(mode).png")
            }
        }
        if only == nil || only?.contains("reglages") == true {
            let main = mainWindow
            openSettings()
            try? await Task.sleep(for: .seconds(1))
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                try? await Task.sleep(for: .seconds(0.8))
                let settings = NSApp.windows.first { $0.isVisible && $0 !== main && !$0.isSheet && $0.canBecomeKey }
                capture(to: "\(dir)/reglages-\(mode).png", window: settings)
            }
        }
        print("SNAPSHOT done \(dir)")
        // Une feuille ouverte refuse la fermeture de l'app, et la commande attendrait sans fin.
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.canBecomeMain && !$0.isSheet && $0.isVisible }
    }

    /// Capture la vraie fenêtre (`screencapture -l`) : barre latérale et matériaux comme à l'écran.
    /// Il faut l'autorisation Enregistrement de l'écran pour l'app qui lance la commande.
    private static func capture(to path: String, window: NSWindow? = nil) {
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        guard let window = window ?? mainWindow else {
            print("SNAPSHOT no window \(path)")
            return
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Sondes de mise en page à côté de chaque PNG (scripts/check-layout.swift).
        GridProbes.shared.write(to: path.replacingOccurrences(of: ".png", with: "-layout.json"),
                                window: window.contentView?.bounds.size ?? .zero)
        try? FileManager.default.removeItem(atPath: path)
        for _ in 1...3 {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try? shot.run()
            shot.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) {
                print("SNAPSHOT \(path)")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SNAPSHOT \(path) (fallback : pas d'autorisation Enregistrement de l'écran, barre latérale vide)")
        }
    }
}
