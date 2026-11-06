import AlexandrieCore
import AppKit
import Foundation

/// Self-test : exécute les fonctions que l'interface appelle (`LibraryStore`) sur des livres générés,
/// dans un dossier de test vide, et affiche PASS ou FAIL par étape. Code de sortie 0 si tout passe.
///
///     ALEXANDRIE_STORE=/tmp/alexandrie-selftest build/Alexandrie.app/Contents/MacOS/Alexandrie --selftest
@MainActor
struct SelfTest {
    private var failures = 0

    static func launch() {
        setvbuf(stdout, nil, _IOLBF, 0)  // une erreur fatale garde les lignes PASS déjà écrites
        guard let store = AppDirectories.testStore else {
            print("FAIL ALEXANDRIE_STORE manquant : le self-test n'utilise jamais les vraies données")
            exit(2)
        }
        guard store.standardizedFileURL != AppDirectories.realBase.standardizedFileURL else {
            print("FAIL ALEXANDRIE_STORE désigne les vraies données de l'app")
            exit(2)
        }
        if let content = try? FileManager.default.contentsOfDirectory(atPath: store.path), !content.isEmpty {
            print("FAIL le dossier de test \(store.path) n'est pas vide (scripts/selftest.sh le vide avant chaque passage)")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task {
            var test = SelfTest()
            await test.run(store: store)
            print(test.failures == 0 ? "SELFTEST ok" : "SELFTEST \(test.failures) échec(s)")
            exit(test.failures == 0 ? 0 : 1)
        }
        app.run()
    }

    private mutating func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok {
            print("PASS \(name)")
        } else {
            let more = detail()
            print("FAIL \(name)" + (more.isEmpty ? "" : " — \(more)"))
            failures += 1
        }
    }

    private mutating func run(store: URL) async {
        let fm = FileManager.default
        let folder = store.appendingPathComponent("Livres", isDirectory: true)
        let outside = store.appendingPathComponent("À importer", isDirectory: true)
        let sources: [URL]
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            sources = [
                try Self.makeEPUB(title: "Le Livre d'Essai", author: "Jeanne Dupont", in: folder),
                try Self.makeEPUB(title: "Second Livre", author: "Paul Martin", in: folder),
            ]
        } catch {
            check("livres de test générés", false, error.localizedDescription)
            return
        }
        let originals = sources.map { try? Data(contentsOf: $0) }

        let library = LibraryStore()
        check("dossier de données de test", library.directories.base.standardizedFileURL == store.standardizedFileURL,
              library.directories.base.path)
        await Self.wait { !library.isScanning }

        // Indexation : choix du dossier, comme le panneau « Choisir le dossier de livres ».
        library.chooseFolder(folder)
        await Self.wait { !library.isScanning && library.books.count == 2 }
        let titles = Set(library.books.map(\.title))
        check("indexation du dossier", titles == ["Le Livre d'Essai", "Second Livre"], "\(titles)")
        check("couvertures extraites", library.books.allSatisfy { library.coverURL($0).map { fm.fileExists(atPath: $0.path) } ?? false })
        check("vérification en ligne coupée", !library.autoCheckCatalog)

        // Retouche des métadonnées, comme la fiche du livre.
        guard var book = library.books.first(where: { $0.title == "Le Livre d'Essai" }) else { return }
        book.title = "Titre corrigé"
        book.authors = ["Jeanne Dupont-Durand"]
        library.update(book)
        library.saveNow()
        await Self.wait { (try? LibraryIndex.load(library.directories.index))?.contains { $0.title == "Titre corrigé" } ?? false }
        let saved = (try? LibraryIndex.load(library.directories.index)) ?? []
        check("retouche enregistrée dans l'index", saved.contains { $0.title == "Titre corrigé" && $0.authors == ["Jeanne Dupont-Durand"] })

        // Préparation de l'envoi : conversion EPUB → AZW3 avec la retouche.
        let directories = library.directories
        let edited = library.book(id: book.id) ?? book
        let prepared = await Task.detached { () -> Result<String, Error> in
            Result {
                let url = try KindleTransfer.prepare(edited, directories: directories)
                return try MobiBook(url: url).metadata().title
            }
        }.value
        switch prepared {
        case .success(let title): check("conversion EPUB → AZW3 avec la retouche", title == "Titre corrigé", title)
        case .failure(let error): check("conversion EPUB → AZW3 avec la retouche", false, error.localizedDescription)
        }

        // Import : le fichier est copié dans le dossier de l'app.
        if let extra = try? Self.makeEPUB(title: "Livre importé", author: "Ada Lovelace", in: outside) {
            library.importFiles([extra])
            await Self.wait { !library.isScanning && library.books.count == 3 }
            let imported = library.books.first { $0.title == "Livre importé" }
            check("import copié dans Imports", imported?.isImported == true
                  && imported?.path.hasPrefix(directories.imports.path) == true, imported?.path ?? "absent")
        }

        // Corbeille d'Alexandrie : rien ne bouge sur le disque.
        library.moveToTrash(edited)
        check("mise à la corbeille", !library.visibleBooks.contains { $0.id == edited.id }
              && library.trashedBooks.contains { $0.id == edited.id })
        library.restoreFromTrash(edited)
        check("restauration depuis la corbeille", library.visibleBooks.contains { $0.id == edited.id })
        check("fichiers source intacts", sources.map { try? Data(contentsOf: $0) } == originals
              && sources.allSatisfy { fm.fileExists(atPath: $0.path) })

        // Smoke : moniteurs et minuteries en marche quelques secondes (erreurs sur les files d'arrière-plan).
        let kindle = KindleMonitor()
        let updates = UpdateMonitor()
        try? await Task.sleep(for: .seconds(3))
        check("démarrage des moniteurs", withExtendedLifetime((kindle, updates)) { true })

        // Commandes de la barre des menus, sur une sélection, comme la fenêtre les publie.
        let undo = UndoManager()
        library.undoManager = undo
        let selection = library.visibleBooks.filter { $0.title != "Livre importé" }
        if kindle.isConnected {
            print("SKIP Kindle > Envoyer : une Kindle est branchée, le self-test n'y envoie rien")
        } else {
            let commands = BookCommands(books: selection, list: .all, library: library, kindle: kindle)
            check("Kindle > Envoyer active sur la sélection", commands.canSend && commands.sendTitle.hasPrefix("Envoyer à la connexion"),
                  commands.sendTitle)
            commands.send()
            check("Kindle > Envoyer met la sélection en attente", selection.allSatisfy { library.book(id: $0.id)?.isPendingSend == true })
            let again = BookCommands(books: selection.compactMap { library.book(id: $0.id) }, list: .all, library: library, kindle: kindle)
            check("Kindle > Envoyer grisée quand tout est déjà en attente", !again.canSend)
            undo.undo()
            check("⌘Z retire de l'attente", selection.allSatisfy { library.book(id: $0.id)?.isPendingSend == false })
            let none = BookCommands(books: [], list: .all, library: library, kindle: kindle)
            check("Kindle > Envoyer grisée sans sélection", !none.canSend)
        }

        // Livre > Mettre à la corbeille (⌘⌫) : la sélection part, le suivant est sélectionné, ⌘Z la rend.
        let groups = BookGroups.make(library.visibleBooks, identities: library.identities)
        if let first = groups.first {
            var picked: Set<String> = [first.id]
            let trashCommand = BookCommands(books: [first.primary], list: .all, library: library, kindle: kindle,
                                            afterTrash: { picked = ContentView.nextSelection(after: picked, in: groups) })
            check("Livre > Mettre à la corbeille active dans Tous les livres", trashCommand.canTrash)
            trashCommand.trash()
            check("Livre > Mettre à la corbeille", library.trashedBooks.contains { $0.id == first.primary.id })
            check("sélection passée au livre suivant", picked == (groups.count > 1 ? [groups[1].id] : []), "\(picked)")
            undo.undo()
            check("⌘Z rend le livre mis à la corbeille", library.visibleBooks.contains { $0.id == first.primary.id })
            check("Livre > Coup d'œil active avec une sélection, grisée sans",
                  trashCommand.canQuickLook && !BookCommands(books: [], list: .all, library: library, kindle: kindle).canQuickLook)
            let one = BookCommands(books: [first.primary], list: .all, library: library, kindle: kindle)
            let two = BookCommands(books: Array(library.visibleBooks.prefix(2)), list: .all, library: library, kindle: kindle)
            check("menu Livre : Ouvrir pour un livre, Afficher dans le Finder pour la sélection",
                  one.canOpen && !two.canOpen && two.canReveal && !BookCommands(books: [], list: .all, library: library, kindle: kindle).canReveal)
            check("menu Livre : Exporter en EPUB grisée pour un EPUB", !one.canExportEPUB)
            // Menus : MenuState publie les valeurs que l'App passe aux menus Livre et Kindle.
            let menu = MenuState()
            menu.update(one)
            let withBook = menu.values
            menu.update(BookCommands(books: [], list: .all, library: library, kindle: kindle))
            let empty = menu.values
            check("menus actifs avec un livre sélectionné", withBook.canOpen && withBook.canReveal && withBook.canTrash)
            check("Livre > Partager : le fichier du livre sélectionné", withBook.shareURLs == [first.primary.url] && empty.shareURLs.isEmpty)
            check("menus grisés sans sélection", !empty.canSend && !empty.canTrash && !empty.canQuickLook
                  && !empty.canOpen && !empty.canReveal && !empty.canExportEPUB)
            // Glisser une carte : une copie du fichier pour le Finder, la liste des livres pour une liseuse.
            // Transferable.exported(as:) n'existe qu'à partir de macOS 15.2.
            if #available(macOS 15.2, *) {
                let item = BookDragItem(payload: BookDrag.payload([first.primary]), file: first.primary.url)
                let fileData = try? await item.exported(as: .data)
                check("glisser vers le Finder : copie identique du fichier",
                      fileData != nil && fileData == (try? Data(contentsOf: first.primary.url)))
                let text = (try? await item.exported(as: .utf8PlainText)).flatMap { String(data: $0, encoding: .utf8) }
                check("glisser vers une liseuse : livres relus", text.flatMap(BookDrag.ids) == [first.primary.id], text ?? "rien")
            }
            for page: SidebarItem in [.sent, .pending, .trash] {
                let other = BookCommands(books: [first.primary], list: page, library: library, kindle: kindle)
                check("Mettre à la corbeille grisée dans \(page)", !other.canTrash)
            }
        }

        // Page de la barre latérale gardée d'un lancement à l'autre (@SceneStorage) : aller-retour en texte.
        let pages: [SidebarItem] = [.all, .recent, .sent, .toReview, .kindle, .pending, .trash, .notes, .shelf("A1B2"),
                                    .format(.azw3), .author("dupont jeanne"), .series("commissaire: vidal"), .genre("policier")]
        let lost = pages.filter { SidebarItem(storageKey: $0.storageKey) != $0 }
        check("page de la barre latérale gardée au lancement", lost.isEmpty && SidebarItem(storageKey: "inconnu") == nil, "\(lost)")

        library.saveNow()
        check("index relu après fermeture", ((try? LibraryIndex.load(directories.index)) ?? []).count == 3)
    }

    /// Attend une condition (au plus `timeout` secondes) en laissant tourner les tâches de l'app.
    private static func wait(timeout: Double = 20, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func makeEPUB(title: String, author: String, in folder: URL) throws -> URL {
        try SeedData.makeEPUB(BookMetadata(title: title, authors: [author], language: "fr"),
                              cover: SeedData.coverPNG(title: title, color: .systemBlue), in: folder)
    }
}
