import AlexandrieCore
import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// Mode capture pour les agents (voir `scripts/snap.sh`) :
///
///     ALEXANDRIE_STORE=/tmp/… ALEXANDRIE_SEED=1 ALEXANDRIE_SNAPSHOT=/tmp/alexandrie-shots Alexandrie
///
/// écrit `<page>-light.png` et `<page>-dark.png` pour chaque page de la barre latérale, puis
/// `reglages-<onglet>-…` pour chaque onglet des réglages et `feuille-<nom>-…` pour chaque feuille, et quitte.
/// `ALEXANDRIE_SNAPSHOT_PAGES=tous,notes` limite les pages (ajouter `reglages`, `feuilles`, `lecture`).
/// Jamais sur les vraies données.
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
        /// Teintes gardées dans la page Notes (S-074, S-079), séparées par des virgules.
        var notesColors: String? = nil
        /// Catalogue en ligne (S-086) : premier livre du catalogue d'exemple choisi.
        var catalogBook = false
    }

    static func pages(_ library: LibraryStore) -> [Page] {
        [
            Page(name: "tous", item: .all, book: "Le Port des brumes"),
            Page(name: "recents", item: .recent),
            Page(name: "envoyes", item: .sent),
            Page(name: "a-verifier", item: .toReview),
            Page(name: "notes", item: .notes, notes: ShelfSync.normalize("Le Port des brumes")),
            Page(name: "notes-couleurs", item: .notes, notes: ShelfSync.normalize("Le Port des brumes"), notesColors: "#FF375F"),
            Page(name: "corbeille", item: .trash),
            Page(name: "en-attente", item: .pending),
            Page(name: "kindle", item: .kindle),
            Page(name: "format-azw3", item: .format(.azw3)),
            Page(name: "format-pdf", item: .format(.pdf), book: "Manuel du fleuve"),
            Page(name: "fiche-lecture", item: .all, book: "Les Heures lentes"),
            Page(name: "serie", item: .series(SeriesNames.key("Commissaire Vidal")), book: "Mort à marée basse"),
            Page(name: "genre", item: .genre(GenreNames.key("Policier"))),
            Page(name: "catalogue", item: .catalog("gutenberg"), catalogBook: true),
            Page(name: "auteur", item: .author(AuthorNames.key("Inès Garnier")),
                 book: "Une très longue histoire de la cartographie des mers du Nord, de l'Antiquité à nos jours"),
        ] + (AppServices.shared.researches.researches.first.map { [Page(name: "thematique", item: .thematic($0.id), notes: ShelfSync.normalize("Le Port des brumes"))] } ?? [])
          + (SeedData.externalFolder.map { [Page(name: "dossier-exemple", item: .folder($0.standardizedFileURL.path), book: "Orbite")] } ?? [])
    }

    static func run(library: LibraryStore, kindle: KindleMonitor, sidebar: Binding<SidebarItem?>, selection: Binding<Set<String>>,
                    notesBook: Binding<String?>, search: Binding<String>, searchScope: Binding<SearchScope>,
                    openSettings: OpenSettingsAction) async {
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
                UserDefaults.standard.set(page.notesColors ?? "", forKey: "notesHues")
                if page.catalogBook, case .catalog(let id) = page.item {
                    let opds = AppServices.shared.opds
                    await opds.open(id)
                    // Langue choisie (S-090) : le livre anglais du catalogue d'exemple est masqué.
                    await opds.setLanguage(id, "fr")
                    opds.selection[id] = opds.current(id)?.feed?.entries.first(where: \.isBook)?.id
                }
                try? await Task.sleep(for: .seconds(0.8))
                capture(to: "\(dir)/\(page.name)-\(mode).png")
            }
        }
        // Liseuse Kobo (S-096) : un dossier du dossier de test, avec deux livres d'exemple dans Books.
        if only == nil || only?.contains("liseuse-kobo") == true {
            let fm = FileManager.default
            let root = library.directories.base.appendingPathComponent("Kobo de Léa", isDirectory: true)
            try? fm.createDirectory(at: root.appendingPathComponent(".kobo"), withIntermediateDirectories: true)
            try? fm.createDirectory(at: root.appendingPathComponent("Books"), withIntermediateDirectories: true)
            fm.createFile(atPath: root.appendingPathComponent(".kobo/version").path, contents: Data("N306".utf8))
            for book in library.visibleBooks.filter({ $0.format == .epub }).prefix(2) {
                try? fm.copyItem(at: book.url, to: root.appendingPathComponent("Books/" + book.filename(for: .kobo)))
            }
            let kobo = VolumeKindle(root: root, brand: .kobo)
            await kindle.simulate(kobo)
            if kindle.currentReader == nil { kindle.nameCurrentReader("Kobo de Léa") }
            sidebar.wrappedValue = .kindle
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                try? await Task.sleep(for: .seconds(1.5))
                capture(to: "\(dir)/liseuse-kobo-\(mode).png")
            }
            await kindle.simulate(nil)
            if let reader = kindle.readers.first(where: { $0.id == kobo.identifier }) { kindle.forget(reader.id) }
        }
        // Recherche dans le contenu (S-082) : un mot du texte des livres d'exemple, une fois l'index fait.
        if only == nil || only?.contains("recherche-contenu") == true {
            await AppServices.shared.contentIndexer.waitUntilIdle()
            searchScope.wrappedValue = .content
            // Écriture exacte (S-084) cochée : « brume » en minuscules.
            UserDefaults.standard.set(true, forKey: "contentSearchExact")
            search.wrappedValue = "brume"
            sidebar.wrappedValue = .all
            selection.wrappedValue = []
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                try? await Task.sleep(for: .seconds(1.5))
                capture(to: "\(dir)/recherche-contenu-\(mode).png")
            }
            search.wrappedValue = ""
            searchScope.wrappedValue = .titles
            UserDefaults.standard.set(false, forKey: "contentSearchExact")
        }
        if only == nil || only?.contains("lecture") == true {
            await captureReader(library: library, dir: dir)
        }
        if only == nil || only?.contains("feuilles") == true {
            await captureSheets(library: library, kindle: kindle, dir: dir)
        }
        if only == nil || only?.contains("reglages") == true {
            // Sauvegarde hors du Mac : un dossier du dossier de test, et une copie déjà faite.
            let backups = AppServices.shared.backups
            let disk = library.directories.base.appendingPathComponent("iCloud Drive (exemple)", isDirectory: true)
            try? FileManager.default.createDirectory(at: disk, withIntermediateDirectories: true)
            backups.folder = disk
            backups.isEnabled = true
            await backups.backUpNow()
            let main = mainWindow
            openSettings()
            try? await Task.sleep(for: .seconds(1))
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                for tab in SettingsTab.allCases {
                    UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.storageKey)
                    try? await Task.sleep(for: .seconds(0.8))
                    let settings = NSApp.windows.first { $0.isVisible && $0 !== main && !$0.isSheet && $0.canBecomeKey }
                    capture(to: "\(dir)/reglages-\(tab.rawValue)-\(mode).png", window: settings)
                }
            }
        }
        print("SNAPSHOT done \(dir)")
        // Une feuille ouverte refuse la fermeture de l'app, et la commande attendrait sans fin.
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
    }

    /// Fenêtre de lecture (S-066 à S-069) : un EPUB avec sa table des matières, un PDF, puis l'EPUB en
    /// sépia avec un texte agrandi. Réglages remis à leur valeur ensuite (bundle de capture à part).
    private static func captureReader(library: LibraryStore, dir: String) async {
        let reading = AppServices.shared.reading
        let shots: [(name: String, title: String, theme: ReaderTheme, scale: Double, contents: Bool, query: String?, font: ReaderFont)] = [
            ("lecture-epub", "Le Port des brumes", .light, 1, true, nil, .book),
            ("lecture-pdf", "Manuel du fleuve", .light, 1, false, nil, .book),
            ("lecture-sepia", "Le Port des brumes", .sepia, 1.4, false, nil, .book),
            // Police choisie (S-095) : sans empattements, sur papier sombre.
            ("lecture-police", "Le Port des brumes", .dark, 1.1, false, nil, .avenir),
            // Ouverte depuis la recherche dans le contenu (S-085) : renvois à gauche, deuxième passage affiché.
            ("lecture-renvois", "Le Port des brumes", .light, 1, false, "phare", .book),
        ]
        for shot in shots {
            guard let book = library.visibleBooks.first(where: { $0.title == shot.title }) else { continue }
            reading.theme = shot.theme
            reading.textScale = shot.scale
            reading.font = shot.font
            // Lecture reprise (S-068) : au milieu du deuxième chapitre.
            if book.format == .epub {
                reading.record(ReadingPosition(chapter: 1, fraction: 0.5, percent: 0.375), for: book)
            }
            UserDefaults.standard.set(shot.contents, forKey: "readerContentsVisible")
            if let query = shot.query {
                await AppServices.shared.contentIndexer.waitUntilIdle()
                let hits = await AppServices.shared.contentIndexer.passages(of: book, query: query, exact: false)
                if hits.count > 1 {
                    ReaderLaunch.shared.open(book, at: ReaderTarget(section: hits[1].section, text: hits[1].match,
                                                                    occurrence: hits[1].occurrence, query: query))
                }
            }
            ReaderWindows.open(book.id)
            try? await Task.sleep(for: .seconds(2.5))
            let window = NSApp.windows.first { $0.title == book.title && $0.isVisible }
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                try? await Task.sleep(for: .seconds(0.8))
                capture(to: "\(dir)/\(shot.name)-\(mode).png", window: window)
                await drawWebPage(of: window, into: "\(dir)/\(shot.name)-\(mode).png")
            }
            window?.close()
            try? await Task.sleep(for: .seconds(0.5))
        }
        reading.theme = .light
        reading.textScale = 1
        reading.font = .book
    }

    /// WebKit dessine la page d'un EPUB dans un autre processus, que `screencapture` ne voit pas : l'image
    /// de la page, rendue par WebKit lui-même, est posée à sa place dans la capture.
    private static func drawWebPage(of window: NSWindow?, into path: String) async {
        func find(_ view: NSView) -> ReaderWebView? {
            (view as? ReaderWebView) ?? view.subviews.lazy.compactMap(find).first
        }
        guard let window, let root = window.contentView, let web = find(root),
              let page = try? await web.takeSnapshot(configuration: nil),
              let data = FileManager.default.contents(atPath: path), let shot = NSBitmapImageRep(data: data),
              // Image neuve : le PNG de screencapture (alpha non prémultiplié) refuse qu'on y dessine.
              let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: shot.pixelsWide, pixelsHigh: shot.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: canvas) else { return }
        let scale = CGFloat(shot.pixelsWide) / window.frame.width
        let frame = web.convert(web.bounds, to: nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        shot.draw(in: CGRect(x: 0, y: 0, width: shot.pixelsWide, height: shot.pixelsHigh))
        page.draw(in: CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale))
        NSGraphicsContext.restoreGraphicsState()
        try? canvas.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Feuilles qu'on ne peut pas ouvrir sans Kindle branchée : chacune dans une fenêtre de sa taille.
    private static func captureSheets(library: LibraryStore, kindle: KindleMonitor, dir: String) async {
        let document = KindleDocument(id: "exemple", path: "documents/Le Port des brumes.epub", size: 1_200_000)
        let edits = MetadataEdits(title: "Le Port des brumes", authors: ["Hugo Lambert"],
                                  publisher: "Éditions d'Exemple", series: "Commissaire Vidal", seriesIndex: 1)
        let sheets: [(String, AnyView)] = [
            ("liseuse", AnyView(NameReaderSheet())),
            ("kindle", AnyView(KindleEditSheet(document: document, edits: edits))),
            ("verification-en-ligne", AnyView(CatalogConsentSheet())),
            ("plantage", AnyView(CrashReportSheet())),
            ("accueil", AnyView(OnboardingView().frame(width: 900, height: 620))),
            ("recherches", AnyView(ResearchesSheet(selected: AppServices.shared.researches.researches.first?.id))),
            ("catalogues", AnyView(OPDSCatalogsSheet())),
        ]
        // Un rapport factice, pour la feuille « plantage » (dossier de test seulement).
        CrashReports.shared.store(Data("{}".utf8))
        defer { CrashReports.shared.discardAll() }
        for (name, view) in sheets {
            let host = NSHostingController(rootView: view.environment(library).environment(kindle)
                .environment(AppServices.shared.researches).environment(AppServices.shared.opds)
                .environment(AppServices.shared.backups))
            host.sizingOptions = [.preferredContentSize]
            // Sans barre de titre, comme une feuille : la capture montre tout le contenu, rien d'autre.
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.borderless]
            window.center()
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(0.8))
                capture(to: "\(dir)/feuille-\(name)-\(mode).png", window: window)
            }
            window.orderOut(nil)
        }
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
