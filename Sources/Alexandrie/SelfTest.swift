import AlexandrieCore
import AppKit
import Foundation
import PDFKit

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
        library.addFolder(folder)
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
            // Raccourcis > Envoyer à la Kindle : sans Kindle, le livre passe en attente.
            if let target = selection.first {
                let answer = await SendToKindle.run(target, library: library, kindle: kindle)
                check("Raccourcis > Envoyer à la Kindle met en attente", answer == "En attente de la Kindle"
                      && library.book(id: target.id)?.isPendingSend == true, answer)
                library.removeFromKindleQueue([target.id])
            }
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
                // Le Finder reçoit l'adresse d'une copie : même contenu, autre emplacement que la source.
                let urlData = try? await item.exported(as: .fileURL)
                let copy = urlData.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                check("glisser vers le Finder : copie du fichier, source à sa place",
                      copy != nil && copy?.standardizedFileURL != first.primary.url.standardizedFileURL
                      && (copy.flatMap { try? Data(contentsOf: $0) }) == (try? Data(contentsOf: first.primary.url))
                      && fm.fileExists(atPath: first.primary.url.path), copy?.path ?? "rien")
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
                                    .format(.azw3), .author("dupont jeanne"), .series("commissaire: vidal"), .genre("policier"),
                                    .folder("/Volumes/Disque: livres/Romans")]
        let lost = pages.filter { SidebarItem(storageKey: $0.storageKey) != $0 }
        check("page de la barre latérale gardée au lancement", lost.isEmpty && SidebarItem(storageKey: "inconnu") == nil, "\(lost)")

        library.saveNow()
        check("index relu après fermeture", ((try? LibraryIndex.load(directories.index)) ?? []).count == 3)

        await testFolders(library: library, first: folder, sources: sources, store: store)
        await testPDF(library: library, folder: folder)
        await testReading(library: library, folder: folder)
        await testHighlights(library: library, folder: folder)
        await testContentSearch(library: library, folder: folder)
    }

    /// Recherche dans le contenu (S-081 à S-083) : la bibliothèque indexée en arrière-plan, un mot trouvé dans
    /// un EPUB et dans un PDF, le passage ouvert et sélectionné, un livre retiré puis remis.
    private mutating func testContentSearch(library: LibraryStore, folder: URL) async {
        let directories = library.directories
        let books = library.visibleBooks
        guard let epub = books.first(where: { $0.format == .epub && $0.folderPath(in: folder) && BookText.canExtract($0) }),
              let pdf = books.first(where: { $0.format == .pdf && $0.title == "Manuel du fleuve" }) else {
            check("livres à chercher présents", false)
            return
        }
        // Barre latérale : un livre en plusieurs fichiers compte pour un, comme dans la grille.
        let shown = BookGroups.make(books, identities: library.identities)
        check("« Tous les livres » compte des livres, pas des fichiers", library.bookCount(books) == shown.count
              && (shown.contains(where: \.isGroup) ? shown.count < books.count : shown.count == books.count),
              "\(library.bookCount(books)) livre(s) pour \(books.count) fichier(s)")
        let indexer = ContentIndexer(directories: directories)
        indexer.refresh(books: books, identities: library.identities)
        await indexer.waitUntilIdle()
        let readable = BookText.filesToIndex(books, identities: library.identities)
        let textFiles = (try? FileManager.default.contentsOfDirectory(atPath: directories.texts.path)) ?? []
        check("texte des livres indexé en arrière-plan", !indexer.isIndexing && indexer.indexed == Set(readable.map(\.fingerprint))
              && textFiles.count == readable.count, "\(textFiles.count) texte(s) sur \(readable.count)")
        // Un livre en plusieurs fichiers n'est lu qu'une fois.
        let groups = BookGroups.make(books, identities: library.identities)
        check("un seul fichier indexé par livre", groups.allSatisfy { g in g.books.filter { indexer.indexed.contains($0.fingerprint) }.count <= 1 }
              && readable.count <= groups.count, "\(readable.count) fichier(s) pour \(groups.count) livre(s), \(groups.filter(\.isGroup).count) en plusieurs fichiers")
        check("livres protégés ignorés", books.filter(\.isDRMProtected).allSatisfy {
            !FileManager.default.fileExists(atPath: BookText.url(of: $0.fingerprint, in: directories).path) })

        // PDF : un mot de sa première page, sans accents ni majuscules.
        let fleuve = await indexer.search("BATELIERS", in: books)
        let pdfHit = fleuve.first { $0.book.id == pdf.id }
        check("PDF trouvé par un mot de son texte", pdfHit.map { $0.count >= 1 && $0.snippets.first?.match == "bateliers" } ?? false,
              fleuve.map(\.book.title).joined(separator: ", "))

        // Écriture exacte (S-084) : « Bateliers », absent avec cette majuscule, ne trouve plus le PDF.
        let exactWrong = await indexer.search("Bateliers", in: books, exact: true)
        let exactRight = await indexer.search("bateliers", in: books, exact: true)
        check("écriture exacte : majuscule respectée", !exactWrong.contains { $0.book.id == pdf.id }
              && exactRight.contains { $0.book.id == pdf.id })

        // EPUB : un mot long de son deuxième paragraphe, cherché par son début.
        let text = BookText.load(BookText.url(of: epub.fingerprint, in: directories))
        // Un mot long qui revient au moins deux fois : les renvois (S-085) ont un suivant.
        let words = text?.sections.first?.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 7 } ?? []
        let word = words.first { w in text.map { ContentSearch.matches(in: $0, query: w).count >= 2 } ?? false } ?? words.first
        guard let text, let word else {
            check("mot à chercher dans l'EPUB", false)
            return
        }
        let found = await indexer.search(String(word.prefix(5)), in: books)
        let epubHit = found.first { $0.book.id == epub.id }
        check("EPUB trouvé par le début d'un mot", epubHit != nil, "« \(word.prefix(5)) » : \(found.map(\.book.title))")

        // Ouvrir le passage : EPUB dans la vraie page, mot sélectionné.
        if let snippet = ContentSearch.matches(in: text, query: word).snippets.first {
            let directories = library.directories
            if let prepared = await Task.detached(operation: { try? ReaderBook.prepare(epub, directories: directories) }).value {
                let reader = EPUBPageController(book: prepared)
                reader.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
                reader.open(chapter: snippet.section, text: snippet.match, occurrence: snippet.occurrence)
                var selected: String?
                let end = Date().addingTimeInterval(20)
                while selected != snippet.match && Date() < end {
                    try? await Task.sleep(for: .milliseconds(150))
                    selected = await reader.js("window.getSelection().toString()") as? String
                }
                check("EPUB : passage ouvert, mot sélectionné", selected == snippet.match, selected ?? "rien")
                // Renvois (S-085) : tous les passages, dans l'ordre ; le suivant s'ouvre, mot sélectionné.
                let hits = await indexer.passages(of: epub, query: word, exact: false)
                let all = ContentSearch.matches(in: text, query: word, limit: .max)
                let ordered = zip(hits, hits.dropFirst()).allSatisfy { $0.section <= $1.section }
                check("renvois : tous les passages du livre, dans l'ordre", hits.count == all.count && hits.count == all.snippets.count
                      && ordered, "\(hits.count) renvoi(s) pour \(all.count) passage(s)")
                if let next = hits.dropFirst().first {
                    reader.open(chapter: next.section, text: next.match, occurrence: next.occurrence)
                    var position = 0.0
                    let deadline = Date().addingTimeInterval(20)
                    var landed = false
                    while !landed && Date() < deadline {
                        try? await Task.sleep(for: .milliseconds(150))
                        // Le passage suivant : même mot, rang suivant dans sa section.
                        let r = await reader.js("""
                            (() => { const s = getSelection(); if (!s.rangeCount) return -1;
                              const r = document.createRange(); r.setStart(document.body, 0);
                              r.setEnd(s.getRangeAt(0).startContainer, s.getRangeAt(0).startOffset); return r.toString().length; })()
                            """) as? NSNumber
                        position = r?.doubleValue ?? -1
                        let selected = await reader.js("window.getSelection().toString()") as? String
                        landed = reader.chapter == next.section && position >= 0 && selected == next.match
                    }
                    check("renvoi suivant : sa page, mot sélectionné", landed, "chapitre \(reader.chapter + 1), position \(position)")
                }
            }
        }
        // PDF : la page du passage, mot sélectionné.
        if let snippet = pdfHit?.snippets.first {
            let reader = PDFPageController(url: pdf.url)
            reader.view.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
            reader.show(page: snippet.section, text: snippet.match, occurrence: snippet.occurrence)
            check("PDF : page du passage, mot sélectionné",
                  reader.page == snippet.section && reader.view.currentSelection?.string == snippet.match,
                  "page \(reader.page + 1), « \(reader.view.currentSelection?.string ?? "") »")
            // Renvois (S-085) : « fleuve » revient sur plusieurs pages ; chaque renvoi ouvre sa page, mot sélectionné.
            let hits = await indexer.passages(of: pdf, query: "fleuve", exact: false)
            var visited: [String] = []
            for hit in hits.prefix(4) {
                reader.show(page: hit.section, text: hit.match, occurrence: hit.occurrence)
                visited.append("p\(reader.page + 1):\(reader.view.currentSelection?.string ?? "-")")
            }
            check("PDF : renvois parcourus, chacun à sa page", hits.count >= 2 && zip(hits.prefix(4), visited).allSatisfy {
                $1 == "p\($0.section + 1):\($0.match)" }, visited.joined(separator: " "))
        }

        // Livre retiré de la bibliothèque : il quitte l'index ; remis, il y revient.
        indexer.refresh(books: books.filter { $0.id != pdf.id }, identities: library.identities)
        let gone = await indexer.search("bateliers", in: books)
        check("livre retiré : hors de l'index, texte effacé", !indexer.indexed.contains(pdf.fingerprint) && gone.isEmpty
              && !FileManager.default.fileExists(atPath: BookText.url(of: pdf.fingerprint, in: directories).path))
        indexer.refresh(books: books, identities: library.identities)
        await indexer.waitUntilIdle()
        let back = await indexer.search("bateliers", in: books)
        check("livre remis : de nouveau trouvé", back.contains { $0.book.id == pdf.id })
        // Relu au lancement suivant : l'index et la liste des livres indexés sont sur le disque.
        let saved = (try? Data(contentsOf: directories.contentIndexState)).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        check("index relu au lancement suivant", FileManager.default.fileExists(atPath: directories.contentIndex.path)
              && Set(saved ?? []) == indexer.indexed, "\(saved?.count ?? 0) livre(s) enregistrés")
    }

    /// Surlignages de la fenêtre de lecture (S-070) : une vraie sélection dans un EPUB et dans un PDF,
    /// enregistrée avec sa position parmi les notes, redessinée, et le fichier du livre intact.
    private mutating func testHighlights(library: LibraryStore, folder: URL) async {
        let directories = library.directories
        guard let epub = library.visibleBooks.first(where: { $0.format == .epub && $0.folderPath(in: folder) }),
              let pdf = library.visibleBooks.first(where: { $0.format == .pdf && $0.title == "Manuel du fleuve" }),
              let prepared = await Task.detached(operation: { try? ReaderBook.prepare(epub, directories: directories) }).value
        else {
            check("livres à surligner présents", false)
            return
        }
        let originals = [epub.url, pdf.url].map { try? Data(contentsOf: $0) }
        let kindle = KindleMonitor()

        // EPUB : sélection des caractères 3 à 18 du premier paragraphe, dans la vraie page.
        let reader = EPUBPageController(book: prepared)
        // Taille d'une fenêtre de lecture : la page est mise en colonnes, la note posée sur le passage visible.
        reader.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        reader.open(chapter: 0)
        var ready = false
        let deadline = Date().addingTimeInterval(20)
        while !ready && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            ready = await reader.js("typeof alx === 'object' && document.readyState === 'complete'") as? Bool == true
        }
        _ = await reader.js("""
            (() => { const t = document.querySelector('p').firstChild, r = document.createRange();
              r.setStart(t, 3); r.setEnd(t, 18); const s = getSelection(); s.removeAllRanges(); s.addRange(r); })()
            """)
        let expected = await reader.js("document.querySelector('p').firstChild.data.substring(3, 18).trim()") as? String
        await Self.wait(timeout: 5) { reader.hasSelection }
        let epubPassage = await reader.selectedPassage(fingerprint: epub.fingerprint)
        check("EPUB : la sélection active « Surligner »", reader.hasSelection)
        check("EPUB : passage repéré dans son chapitre", epubPassage.map { $0.text == expected && $0.anchor.chapter == 0
            && $0.anchor.end > $0.anchor.start && $0.anchor.order >= 1 } ?? false,
              "\(String(describing: epubPassage)) attendu « \(expected ?? "?") »")
        if let epubPassage {
            kindle.addHighlight(.readerHighlight(title: epub.title, author: epub.authorLine, text: epubPassage.text,
                                                 anchor: epubPassage.anchor, isPDF: false))
            reader.highlights = kindle.readerHighlights(of: epub)
            try? await Task.sleep(for: .milliseconds(300))
            let marked = await reader.js("[...document.querySelectorAll('mark.alx-hl')].map(m => m.textContent).join('')") as? String
            check("EPUB : le passage surligné est dessiné dans la page", marked?.trimmingCharacters(in: .whitespaces) == expected,
                  marked ?? "rien")
        }

        // PDF : une ligne de la première page.
        let pdfReader = PDFPageController(url: pdf.url)
        var pdfPassage: (anchor: ReaderAnchor, text: String)?
        if let page = pdfReader.document?.page(at: 0), let string = page.string {
            let range = (string as NSString).range(of: "Chaque saison change sa couleur")
            pdfReader.view.setCurrentSelection(page.selection(for: range), animate: false)
            pdfPassage = pdfReader.selectedPassage(fingerprint: pdf.fingerprint)
            check("PDF : passage repéré sur sa page", pdfPassage.map { $0.text == "Chaque saison change sa couleur"
                && $0.anchor.chapter == 0 && $0.anchor.start == range.location && $0.anchor.order == 1 } ?? false,
                  "\(String(describing: pdfPassage))")
        }
        if let pdfPassage {
            kindle.addHighlight(.readerHighlight(title: pdf.title, author: pdf.authorLine, text: pdfPassage.text,
                                                 anchor: pdfPassage.anchor, isPDF: true))
            pdfReader.highlights = kindle.readerHighlights(of: pdf)
            let drawn = pdfReader.document?.page(at: 0)?.annotations.filter { $0.type == "Highlight" }.count ?? 0
            check("PDF : le passage surligné est dessiné sur la page", drawn > 0, "\(drawn) annotation(s)")
            // Ouvert depuis les notes (S-072) : sa page, le passage sélectionné.
            pdfReader.go(to: 3)
            pdfReader.show(page: pdfPassage.anchor.chapter,
                           range: NSRange(location: pdfPassage.anchor.start, length: pdfPassage.anchor.end - pdfPassage.anchor.start))
            check("PDF : surlignage ouvert à son passage", pdfReader.page == pdfPassage.anchor.chapter
                  && pdfReader.view.currentSelection?.string == pdfPassage.text, pdfReader.view.currentSelection?.string ?? "rien")
        }
        if let epubPassage {
            // Ouvert depuis les notes (S-072) : le chapitre, le passage sélectionné à sa page.
            _ = await reader.js("window.getSelection().removeAllRanges()")
            reader.open(chapter: epubPassage.anchor.chapter, start: epubPassage.anchor.start, end: epubPassage.anchor.end)
            var selected: String?
            let end = Date().addingTimeInterval(10)
            while selected?.trimmingCharacters(in: .whitespaces) != epubPassage.text && Date() < end {
                try? await Task.sleep(for: .milliseconds(150))
                selected = await reader.js("window.getSelection().toString()") as? String
            }
            check("EPUB : surlignage ouvert à son passage", selected?.trimmingCharacters(in: .whitespaces) == epubPassage.text,
                  selected ?? "rien")
        }

        // Notes (S-071) : écrites d'un côté, relues et modifiables de l'autre ; repère dessiné dans la page.
        if let h = kindle.readerHighlights(of: epub).first {
            kindle.setNote(h.id, "Note depuis la lecture")
            reader.highlights = kindle.readerHighlights(of: epub)
            try? await Task.sleep(for: .milliseconds(300))
            let shown = await reader.js("[...document.querySelectorAll('mark.alx-note')].map(m => m.title)[0] || ''") as? String
            let marker = await reader.js("document.querySelectorAll('mark.alx-note-end').length") as? Int
            check("EPUB : repère de note dessiné sur le passage", shown == "Note depuis la lecture" && marker == 1,
                  "\(shown ?? "rien"), \(marker ?? 0) repère(s)")
            let rect = await reader.noteRect(for: h.id)
            check("EPUB : la note s'ouvre sur le passage", rect.map { $0.width > 0 && $0.height > 0 } ?? false,
                  "\(String(describing: rect))")
            // Modifiée depuis « Notes et surlignages » : même enregistrement, page redessinée.
            KindleMonitor().setNote(h.id, "Note modifiée dans les notes")
            let edited = KindleMonitor()
            reader.highlights = edited.readerHighlights(of: epub)
            try? await Task.sleep(for: .milliseconds(300))
            let updated = await reader.js("(document.querySelector('mark.alx-note') || {}).title || ''") as? String
            check("note modifiée des deux endroits", updated == "Note modifiée dans les notes"
                  && edited.clipping(id: h.id)?.note == "Note modifiée dans les notes", updated ?? "rien")
            kindle.setNote(h.id, "Note modifiée dans les notes")
        }
        if let h = kindle.readerHighlights(of: pdf).first {
            kindle.setNote(h.id, "Note du PDF")
            pdfReader.highlights = kindle.readerHighlights(of: pdf)
            let notes = pdfReader.document?.page(at: 0)?.annotations.filter { $0.type == "Highlight" && $0.contents == "Note du PDF" }.count ?? 0
            check("PDF : repère de note dessiné sur la page", notes == 1, "\(notes) repère(s)")
            kindle.setNote(h.id, "  ")
            pdfReader.highlights = kindle.readerHighlights(of: pdf)
            let left = pdfReader.document?.page(at: 0)?.annotations.filter { !($0.contents ?? "").isEmpty }.count ?? 0
            check("note vide retirée, surlignage gardé", left == 0 && kindle.readerHighlights(of: pdf).first?.note == nil
                  && kindle.readerHighlights(of: pdf).count == 1)
        }

        // Couleurs (S-073) : enregistrées, redessinées dans les deux pages ; menus sans les commandes de PDFKit.
        if let h = kindle.readerHighlights(of: epub).first {
            kindle.setColor(h.id, .blue)
            reader.highlights = kindle.readerHighlights(of: epub)
            try? await Task.sleep(for: .milliseconds(300))
            let blue = await reader.js("document.querySelectorAll('mark[data-mark=\"#0A84FF\"]').length") as? Int ?? 0
            let shade = await reader.js("getComputedStyle(document.querySelector('mark[data-mark=\"#0A84FF\"]')).backgroundColor") as? String
            check("EPUB : surlignage redessiné en bleu", blue > 0 && (shade ?? "").contains("10, 132, 255"), shade ?? "rien")
        }
        if let h = kindle.readerHighlights(of: pdf).first {
            kindle.setColor(h.id, .purple)
            pdfReader.highlights = kindle.readerHighlights(of: pdf)
            let colored = pdfReader.document?.page(at: 0)?.annotations.contains {
                $0.type == "Highlight" && $0.color.usingColorSpace(.sRGB).map { abs($0.redComponent - 175.0 / 255) < 0.01 } == true
            } ?? false
            check("PDF : surlignage redessiné en violet", colored)
            let actions = ReaderHighlightActions(lookup: { kindle.clipping(id: $0) })
            let titles = HighlightMenu.items(selection: true, highlight: h.id, actions: actions).map(\.title)
            check("menu d'un passage surligné : note, couleur, suppression",
                  titles.contains("Surligner") && titles.contains("Couleur") && titles.contains("Supprimer le surlignage"),
                  titles.joined(separator: ", "))
            let page = pdfReader.view
            page.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            let menu = event.flatMap { page.menu(for: $0) }
            let leftovers = menu?.items.compactMap { $0.action.map(NSStringFromSelector) }
                .filter { ["zoomIn:", "zoomOut:", "_setSinglePage:", "_removeMarkup:"].contains($0) } ?? ["pas de menu"]
            check("PDF : menu sans zoom, modes d'affichage ni surlignage de PDFKit", leftovers.isEmpty, leftovers.joined(separator: ", "))
        }
        // Thématiques (S-075, S-079) : légende nommée, passage rangé dans deux thématiques, couleur à part.
        let store = ResearchStore(directories: library.directories, kindle: kindle)
        var roads = store.addResearch(name: "Rénovation des voiries")
        roads.themes[0].name = "Construction"
        let added = roads.addTheme(name: "Mesures de trafic")
        store.update(roads)
        var memoir = store.addResearch(name: "Mémoire de master")
        memoir.themes[0].name = "Anthropologie"
        store.update(memoir)
        if let h = kindle.readerHighlights(of: epub).first {
            store.setActive(roads.id, for: epub)
            let next = store.nextMark(for: epub)
            check("thématique choisie retenue pour le livre, première couleur proposée",
                  ResearchStore(directories: library.directories, kindle: kindle).activeResearch(for: epub)?.id == roads.id
                  && next.mark.label == "Construction" && next.research == roads.id, next.mark.label)
            store.setThematic(roads.id, on: true, for: h.id)
            store.setThematic(memoir.id, on: true, for: h.id)
            store.apply(HighlightMark(added), to: h.id)
            reader.markOf = { store.mark(of: $0) }
            reader.highlights = kindle.readerHighlights(of: epub)
            try? await Task.sleep(for: .milliseconds(300))
            let shade = await reader.js("getComputedStyle(document.querySelector('mark[data-mark=\"\(added.color)\"]')).backgroundColor") as? String
            let (r, g, b) = HighlightMark(added).rgb
            let saved = KindleMonitor().clipping(id: h.id)
            check("passage dans deux thématiques, couleur ajoutée dessinée",
                  saved?.thematicIDs == [roads.id, memoir.id] && saved?.colorHex == added.color
                  && (shade ?? "").contains("\(r), \(g), \(b)"), shade ?? "rien")
            check("nom de la couleur lu dans chaque légende", saved.map {
                store.mark(of: $0).label == "Mesures de trafic" && store.mark(of: $0, in: memoir.id).label == "Couleur personnalisée"
            } ?? false)
            let reopened = ResearchStore(directories: library.directories, kindle: kindle)
            check("thématiques relues au redémarrage", reopened.research(id: roads.id)?.themes.map(\.displayName).last == "Mesures de trafic")
            let export = store.exportMarkdown(research: roads.id) ?? ""
            check("export de la thématique : couleur nommée, livre et passage (S-078)",
                  export.contains("## Mesures de trafic") && export.contains("### \(epub.title)") && export.contains("> \(h.text)"),
                  String(export.prefix(120)))
            store.delete(roads.id)
            check("thématique supprimée : retirée du passage, couleur gardée", kindle.clipping(id: h.id).map {
                $0.thematicIDs == [memoir.id] && $0.colorHex == added.color } ?? false)
            store.delete(memoir.id)
            kindle.setColor(h.id, .blue)
        }
        // Audit, § 2 : thématiques sauvegardées chaque jour, échec d'enregistrement signalé.
        _ = ResearchStore(directories: directories, kindle: kindle)
        check("thématiques sauvegardées chaque jour", IndexBackups.list(directories.backups, name: "researches").count == 1)
        let broken = AppDirectories(base: directories.base.appendingPathComponent("verrouille", isDirectory: true))
        try? FileManager.default.createDirectory(at: broken.researches, withIntermediateDirectories: true)
        let warned = KindleMonitor()
        warned.lastError = nil
        ResearchStore(directories: broken, kindle: warned).addResearch(name: "Perdue ?")
        check("échec d'enregistrement des thématiques signalé", warned.lastError?.contains("thématiques") == true,
              warned.lastError ?? "rien")

        // Audit, § 4 : un rapport de plantage est gardé, proposé, puis effacé si l'utilisateur refuse.
        let reports = CrashReports.shared
        reports.discardAll()
        reports.store(Data(#"{"crashDiagnostics":[]}"#.utf8))
        let kept = reports.pending.count
        reports.discardAll()
        check("rapport de plantage gardé puis effacé au refus", kept == 1 && reports.pending.isEmpty && !reports.isEnabled)

        // Surlignage d'avant S-079 (recherche et thème) : repris au chargement.
        if let h = kindle.readerHighlights(of: pdf).first {
            let old = store.addResearch(name: "Ancienne recherche")
            kindle.modifyClippings { c in
                guard c.id == h.id else { return false }
                c.research = old.id
                c.theme = old.themes[2].id
                c.thematics = nil
                return true
            }
            _ = ResearchStore(directories: library.directories, kindle: kindle)
            let migrated = kindle.clipping(id: h.id)
            check("surlignage d'avant les thématiques repris", migrated.map {
                $0.research == nil && $0.thematicIDs == [old.id] && $0.highlightColor == .blue } ?? false)
            store.delete(old.id)
            kindle.setColor(h.id, .purple)
        }

        check("couleur relue au redémarrage",
              Set(KindleMonitor().readerHighlights(of: epub).map(\.highlightColor) + KindleMonitor().readerHighlights(of: pdf).map(\.highlightColor))
                == [.blue, .purple])

        // Le JavaScript d'un livre ne s'exécute pas ; celui d'Alexandrie, si (audit, § 2).
        reader.webView.loadHTMLString("<html><body><p>Texte</p><script>document.body.setAttribute('data-livre', 'oui')</script></body></html>",
                                      baseURL: nil)
        var ours: Bool?
        let jsEnd = Date().addingTimeInterval(10)
        while ours != true && Date() < jsEnd {
            try? await Task.sleep(for: .milliseconds(150))
            ours = await reader.js("typeof alx === 'object' && document.body.textContent.includes('Texte')") as? Bool
        }
        let bookScript = await reader.js("document.body.getAttribute('data-livre')") as? String
        check("JavaScript du livre coupé, scripts d'Alexandrie actifs", ours == true && bookScript == nil,
              "Alexandrie : \(String(describing: ours)), livre : \(bookScript ?? "rien")")

        // Relus au redémarrage, rangés avec les notes, livres intacts.
        let reopened = KindleMonitor()
        let saved = reopened.readerHighlights(of: epub) + reopened.readerHighlights(of: pdf)
        check("surlignages relus au redémarrage avec leur position",
              saved.count == 2 && saved.allSatisfy { $0.isFromApp && $0.anchor != nil }
                && saved.first?.note == "Note modifiée dans les notes",
              "\(saved.count) surlignage(s)")
        check("surlignages dans « Notes et surlignages »",
              reopened.clippingBooks.contains { $0.id == ShelfSync.normalize(epub.title) && $0.clippings.contains(where: \.isFromApp) })
        check("fichiers des livres inchangés après surlignage", [epub.url, pdf.url].map { try? Data(contentsOf: $0) } == originals)
        for h in saved { reopened.deleteClipping(h.id) }
        check("surlignage de l'app supprimé pour de bon",
              KindleMonitor().clippings.allSatisfy { !$0.isFromApp })
    }

    /// Fenêtre de lecture (S-066, S-068, S-069) : préparation de chaque format, position, réglages.
    private mutating func testReading(library: LibraryStore, folder: URL) async {
        let fm = FileManager.default
        let directories = library.directories
        guard let epub = library.visibleBooks.first(where: { $0.format == .epub && $0.folderPath(in: folder) }),
              let pdf = library.visibleBooks.first(where: { $0.format == .pdf && $0.title == "Manuel du fleuve" }) else {
            check("livres à lire présents", false)
            return
        }
        // Un AZW3 dans le dossier de livres, comme ceux de la Kindle.
        let azw3URL = folder.appendingPathComponent("Livre Kindle.azw3")
        try? EPUBToAZW3.convert(input: epub.url, output: azw3URL)
        await library.rescan()
        await Self.wait { !library.isScanning && library.books.contains { $0.path == azw3URL.standardizedFileURL.path } }
        let before = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])

        for book in [epub, library.books.first { $0.path == azw3URL.standardizedFileURL.path }].compactMap({ $0 }) {
            let prepared = await Task.detached { try? ReaderBook.prepare(book, directories: directories) }.value
            check("Lire un \(book.format.label) : chapitres prêts dans les données de l'app",
                  prepared.map { !$0.chapters.isEmpty && $0.chapters.allSatisfy { fm.fileExists(atPath: $0.path) }
                      && $0.root.path.hasPrefix(directories.reading.path) } ?? false)
        }
        check("Lire un PDF : document ouvert", PDFPageController(url: pdf.url).pageCount > 0)
        check("Lire : dossier de livres inchangé", Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []) == before)

        var locked = epub
        locked.isDRMProtected = true
        let kindle = KindleMonitor()
        check("Livre > Lire actif pour un livre, grisé sous DRM ou sans sélection",
              BookCommands(books: [epub], list: .all, library: library, kindle: kindle).canRead
              && !BookCommands(books: [locked], list: .all, library: library, kindle: kindle).canRead
              && !BookCommands(books: [], list: .all, library: library, kindle: kindle).canRead)

        // S-068 : la position revient après un redémarrage (nouveau magasin, même fichier).
        let store = ReadingStore(directories: directories)
        store.record(ReadingPosition(chapter: 2, fraction: 0.25, percent: 0.6), for: epub)
        store.saveNow()
        let reopened = ReadingStore(directories: directories).savedPosition(of: epub)
        check("position de lecture relue après redémarrage", reopened?.chapter == 2 && reopened?.fraction == 0.25
              && reopened?.label == "60 % lu", "\(String(describing: reopened))")

        // S-069 : taille et fond gardés (réglages partagés : remis comme avant).
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: ReadingStore.scaleKey), defaults.object(forKey: ReadingStore.themeKey))
        store.textScale = 1
        store.enlarge(); store.enlarge()
        store.theme = .sepia
        let relaunched = ReadingStore(directories: directories)
        check("taille du texte et fond gardés", relaunched.textScale == 1.25 && relaunched.theme == .sepia,
              "\(relaunched.textScale) \(relaunched.theme)")
        for _ in 0..<20 { store.enlarge() }
        check("taille du texte bornée", !store.canEnlarge && store.textScale == ReadingStore.scales.last)
        defaults.set(saved.0, forKey: ReadingStore.scaleKey)
        defaults.set(saved.1, forKey: ReadingStore.themeKey)
    }

    /// PDF pour la Kindle (S-064, S-065) : copie rognée, texte redimensionnable, scan sans texte.
    private mutating func testPDF(library: LibraryStore, folder: URL) async {
        let text: URL, scan: URL
        do {
            text = try SeedData.makePDF(title: "Manuel du fleuve", author: "Claire Morel", pages: 4, in: folder)
            scan = try SeedData.makePDF(title: "Plans anciens", author: "Inès Garnier", pages: 2, scanned: true, in: folder)
        } catch {
            check("PDF de test générés", false, error.localizedDescription)
            return
        }
        let original = try? Data(contentsOf: text)
        await library.rescan()
        await Self.wait { !library.isScanning && library.books.contains { $0.path == text.standardizedFileURL.path } }
        guard var book = library.books.first(where: { $0.path == text.standardizedFileURL.path }) else {
            check("PDF indexé", false)
            return
        }
        let directories = library.directories

        // Fiche > Sur la Kindle : Marges rognées.
        book.pdfMode = .cropped
        library.update(book)
        let croppedBook = library.book(id: book.id) ?? book
        let cropped = await Task.detached { try? KindleTransfer.prepare(croppedBook, directories: directories) }.value
        let size = cropped.flatMap { PDFDocument(url: $0)?.page(at: 0)?.bounds(for: .mediaBox).size }
        check("PDF rogné : pages plus petites, original intact",
              cropped != nil && cropped != text && (size.map { $0.width < 420 && $0.height < 595 } ?? false)
              && (try? Data(contentsOf: text)) == original, "\(size.map { "\($0)" } ?? "rien")")

        // Fiche > Sur la Kindle : Texte redimensionnable.
        book.pdfMode = .reflowable
        library.update(book)
        let reflowBook = library.book(id: book.id) ?? book
        let reflowed = await Task.detached { () -> String? in
            guard let url = try? KindleTransfer.prepare(reflowBook, directories: directories) else { return nil }
            return (try? MobiBook(url: url).metadata())?.title
        }.value
        check("PDF en texte redimensionnable : AZW3 pour la Kindle", reflowed == "Manuel du fleuve"
              && reflowBook.kindleFilename.hasSuffix(".azw3"), reflowed ?? "échec")
        check("PDF scanné : texte redimensionnable grisé", !PDFReflow.hasText(scan)
              && !PDFKindleMode.available(hasText: PDFReflow.hasText(scan)).contains(.reflowable)
              && PDFKindleMode.available(hasText: PDFReflow.hasText(text)).contains(.reflowable))
    }

    /// Plusieurs dossiers de livres (S-060 à S-063), sur la bibliothèque déjà indexée.
    private mutating func testFolders(library: LibraryStore, first folder: URL, sources: [URL], store: URL) async {
        let fm = FileManager.default
        let second = store.appendingPathComponent("Disque", isDirectory: true)
        let spare = store.appendingPathComponent("Disque (copie)", isDirectory: true)
        let before = library.books.count
        do {
            try fm.createDirectory(at: second, withIntermediateDirectories: true)
            _ = try Self.makeEPUB(title: "Livre du disque", author: "Nina Weber", in: second)
            // Même fichier que dans le premier dossier : un doublon, pas un livre de plus.
            try fm.copyItem(at: sources[1], to: second.appendingPathComponent(sources[1].lastPathComponent))
            try fm.copyItem(at: second, to: spare)
        } catch {
            check("second dossier de livres généré", false, error.localizedDescription)
            return
        }

        // S-060 : ajout d'un dossier, ses livres rejoignent « Tous les livres ».
        let refusal = library.addFolder(second)
        await Self.wait { !library.isScanning && library.books.count == before + 2 }
        check("second dossier de livres ajouté", refusal == nil && library.books.contains { $0.title == "Livre du disque" },
              refusal ?? "\(library.books.count) fichiers")
        let copies = library.books.filter { $0.title == "Second Livre" }
        check("même fichier dans deux dossiers rassemblé en doublon",
              copies.count == 2 && library.visibleBooks.filter { $0.title == "Second Livre" }.count == 1, "\(copies.count) fichiers")
        check("dossier déjà lu refusé", library.addFolder(second) != nil
              && library.addFolder(folder.appendingPathComponent("Sous-dossier")) != nil && library.folders.count == 2)
        let saved = LibraryFolders.load(library.directories.folders, legacy: nil).map(\.path)
        check("liste des dossiers relue au lancement",
              saved == [folder, second].map { $0.standardizedFileURL.path }, "\(saved)")

        // S-061 : la page d'un dossier ne montre que ses livres.
        let inSecond = Set(library.books(inFolder: second.path).map(\.title))
        let inFirst = Set(library.books(inFolder: folder.path).map(\.title))
        check("page d'un dossier : ses livres seulement", inSecond.contains("Livre du disque") && !inFirst.contains("Livre du disque")
              && !inFirst.contains("Livre importé"), "\(inSecond) / \(inFirst)")
        check("page d'un dossier gardée au lancement",
              SidebarItem(storageKey: SidebarItem.folder(second.path).storageKey) == .folder(second.path))

        // S-062 : disque débranché (dossier absent) puis rebranché.
        try? fm.removeItem(at: second)
        await library.rescan()
        let absent = library.books.first { $0.title == "Livre du disque" }
        check("dossier débranché : livres gardés, indisponibles",
              library.unavailableFolders.contains(second.standardizedFileURL.path) && library.books.count == before + 2
              && absent.map(library.isUnavailable) == true, "\(library.unavailableFolders)")
        try? fm.copyItem(at: spare, to: second)
        await library.rescan()
        check("dossier rebranché : livres disponibles", library.unavailableFolders.isEmpty
              && library.book(id: absent?.id).map(library.isUnavailable) == false && library.books.count == before + 2)

        // S-063 : retrait d'un dossier, fichiers intacts, attente d'envoi nettoyée.
        if let book = library.book(id: absent?.id) { library.queueForKindle([book], reader: nil) }
        library.removeFolder(second.path)
        check("dossier retiré : ses livres quittent la bibliothèque",
              library.folders.count == 1 && !library.books.contains { $0.title == "Livre du disque" }
              && !library.pendingSends.contains { $0.id == absent?.id } && library.books.count == before)
        check("dossier retiré : fichiers intacts", ((try? fm.contentsOfDirectory(atPath: second.path))?.count ?? 0) == 2)
        library.removeFolder(folder.path)
        check("dernier dossier jamais retiré", library.folders.count == 1 && library.books.count == before)

        await checkOPDS(library: library)
    }

    /// S-086 à S-089 : catalogue OPDS d'exemple (sans réseau) parcouru, cherché, livre téléchargé dans la bibliothèque.
    private mutating func checkOPDS(library: LibraryStore) async {
        let fm = FileManager.default
        let opds = OPDSStore(directories: library.directories, library: library, client: SeedData.opdsClient)
        check("catalogues proposés", opds.catalogs.map(\.id) == OPDSCatalog.suggested.map(\.id))
        await opds.open("gutenberg")
        let feed = opds.current("gutenberg")?.feed
        check("catalogue ouvert", feed?.entries.filter(\.isBook).count == SeedData.opdsBooks.count,
              opds.current("gutenberg")?.error ?? "\(feed?.entries.count ?? 0) entrées")
        if let section = feed?.entries.first(where: { !$0.isBook }), let url = section.navigationURL {
            await opds.push("gutenberg", url: url, title: section.title)
            check("sous-catalogue ouvert", opds.path("gutenberg").map(\.title) == ["Project Gutenberg", section.title])
            opds.back("gutenberg", to: 0)
            check("retour à l'accueil du catalogue", opds.path("gutenberg").count == 1)
        }
        await opds.search("gutenberg", terms: "Verne")
        check("recherche dans le catalogue", opds.current("gutenberg")?.terms == "Verne"
              && opds.current("gutenberg")?.feed != nil && opds.canSearch("gutenberg"),
              opds.current("gutenberg")?.error ?? "")

        // S-090 : langue choisie, envoyée à la recherche de Gutenberg (`l.en`), livres d'une autre langue masqués.
        await opds.setLanguage("gutenberg", "en")
        let english = opds.visibleEntries("gutenberg")
        check("langue : recherche restreinte", opds.current("gutenberg")?.url.absoluteString.contains("l.en") == true,
              opds.current("gutenberg")?.url.absoluteString ?? "")
        check("langue : livres d'une autre langue masqués", english.entries.filter(\.isBook).count == 1
              && english.hidden == SeedData.opdsBooks.count - 1, "\(english.entries.count) affichées, \(english.hidden) masquées")
        check("langue retenue", OPDSCatalogList.load(library.directories.opds).languages["gutenberg"] == "en"
              && !opds.offersLanguages("ebooksgratuits") && opds.language("ebooksgratuits") == nil)
        await opds.setLanguage("gutenberg", nil)
        check("toutes les langues", opds.visibleEntries("gutenberg").hidden == 0)

        guard let entry = feed?.entries.first(where: \.isBook), let epub = entry.acquisitions.first else {
            check("livre du catalogue", false)
            return
        }
        let before = library.books.count
        let book = await opds.download(epub, of: entry)
        check("livre téléchargé dans la bibliothèque", book?.title == entry.title && book?.isImported == true
              && library.books.count == before + 1, opds.downloadError?.message ?? book?.path ?? "absent")
        check("téléchargement reconnu", opds.libraryBook(for: entry)?.id == book?.id
              && OPDSCatalogList.load(library.directories.opds).downloads[entry.id] == book?.id)
        check("dossier temporaire nettoyé", !((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? [])
              .contains { $0.hasPrefix("Alexandrie-") && $0.count > 40 && !$0.hasPrefix("Alexandrie-seed") })
        if let mobi = entry.acquisitions.first(where: { $0.format == .mobi }) {
            let refused = await opds.download(mobi, of: entry)
            check("fichier illisible refusé", refused == nil && opds.downloadError != nil && library.books.count == before + 1)
        }

        let added = await opds.add(name: "", address: "exemple.org/opds")
        if case .success(let catalog) = added {
            check("catalogue ajouté", catalog.name == "Catalogue d'exemple" && opds.catalogs.last?.id == catalog.id)
            opds.remove(catalog.id)
        } else {
            check("catalogue ajouté", false)
        }
        opds.remove("bnr")
        check("catalogue retiré, puis rétabli", !opds.catalogs.contains { $0.id == "bnr" }
              && { opds.restoreSuggestions(); return opds.catalogs.count == OPDSCatalog.suggested.count }())
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

private extension Book {
    /// Fichier rangé directement dans ce dossier (pas un import).
    func folderPath(in folder: URL) -> Bool {
        !isImported && path.hasPrefix(folder.standardizedFileURL.path + "/")
    }
}
