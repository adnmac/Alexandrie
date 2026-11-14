import AppKit
import FolunaCore
import Foundation

/// Test de résistance : le vrai `LibraryStore` sur une grosse bibliothèque inventée (`StressData`),
/// sans fenêtre. Mesure chaque étape (durée, plus long blocage du thread principal, mémoire, processeur)
/// et écrit un rapport Markdown et JSON. PASS / FAIL pour la justesse (aucun livre perdu, index relu identique).
///
///     FOLUNA_STORE=/tmp/foluna-stress/store-10000 Foluna --stress 10000
///
/// Le coût des vues SwiftUI n'est pas mesuré ici (pas de fenêtre) : voir `scripts/stress-ui.sh`.
@MainActor
struct StressTest {
    struct Step: Codable {
        let name: String
        let milliseconds: Double
        let maxStallMilliseconds: Double
        let stallsOver250ms: Int
        let peakFootprintMB: Double
        let cpuMilliseconds: Double
        var note: String = ""
    }

    private var steps: [Step] = []
    private var failures = 0
    private let watchdog = MainThreadWatchdog()
    private let n: Int

    private init(n: Int) { self.n = n }

    static func launch() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--stress"), i + 1 < args.count, let n = Int(args[i + 1]), n > 0 else {
            print("FAIL usage : Foluna --stress <nombre de livres>")
            exit(2)
        }
        guard let store = AppDirectories.testStore,
              store.standardizedFileURL.path.hasPrefix("/tmp/") || store.standardizedFileURL.path.hasPrefix("/private/tmp/") else {
            print("FAIL FOLUNA_STORE doit désigner un dossier de /tmp : le test de résistance n'utilise jamais les vraies données")
            exit(2)
        }
        // Le dossier de test est vidé ; le jeu de livres, lui, est gardé (long à créer).
        try? FileManager.default.removeItem(at: store)
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        let data = URL(fileURLWithPath: env["FOLUNA_STRESS_DATA"] ?? "/tmp/foluna-stress-data/\(n)", isDirectory: true)
        let report = URL(fileURLWithPath: env["FOLUNA_STRESS_REPORT"] ?? "/tmp/foluna-stress", isDirectory: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task {
            var test = StressTest(n: n)
            await test.run(data: data, report: report)
            print(test.failures == 0 ? "STRESS ok" : "STRESS \(test.failures) échec(s)")
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

    /// Mesure une étape ; le blocage et la mémoire sont relevés pendant toute sa durée.
    @discardableResult
    private mutating func step<T>(_ name: String, note: String = "", _ body: () async throws -> T) async rethrows -> T {
        _ = watchdog.take()
        let cpu = MainThreadWatchdog.cpuTime()
        let start = ContinuousClock.now
        let value = try await body()
        let elapsed = ContinuousClock.now - start
        // Laisse au détecteur le temps de voir un blocage qui finit avec l'étape.
        try? await Task.sleep(for: .milliseconds(60))
        let w = watchdog.take()
        let s = Step(name: name, milliseconds: Self.ms(elapsed), maxStallMilliseconds: Self.ms(w.maxStall),
                     stallsOver250ms: w.stallsOver250ms, peakFootprintMB: Double(w.peakFootprint) / 1_048_576,
                     cpuMilliseconds: Self.ms(MainThreadWatchdog.cpuTime() - cpu), note: note)
        steps.append(s)
        print(String(format: "STEP %@ %.0f ms, blocage max %.0f ms (%d > 250 ms), %.0f Mo", name,
                     s.milliseconds, s.maxStallMilliseconds, s.stallsOver250ms, s.peakFootprintMB))
        return value
    }

    private mutating func run(data: URL, report: URL) async {
        let n = self.n
        watchdog.start()
        print("Bibliothèque de \(n) livres dans \(data.path)")
        let set: (books: URL, files: Int)
        do {
            set = try await step("jeu de livres (création ou reprise)") { try StressData.ensure(count: n, at: data) }
        } catch {
            check("jeu de livres créé", false, error.localizedDescription)
            return
        }
        setenv("FOLUNA_BOOKS", set.books.path, 1)
        let expected = set.files

        // 1. Première indexation : lecture de chaque fichier, couvertures, index.
        var library: LibraryStore? = nil
        await step("première indexation", note: "\(expected) fichiers") {
            library = LibraryStore()
            await Self.waitIdle(library!, count: expected, label: "indexation")
        }
        guard let first = library else { return }
        check("tous les fichiers indexés", first.books.count == expected, "\(first.books.count) sur \(expected)")
        if let last = steps.last, last.milliseconds > 0 {
            print(String(format: "  débit : %.0f livres/s", Double(expected) / (last.milliseconds / 1000)))
        }
        await step("enregistrement final (saveNow)") { first.saveNow() }
        let indexSize = (try? FileManager.default.attributesOfItem(atPath: first.directories.index.path)[.size] as? Int) ?? 0
        let reloaded = (try? LibraryIndex.load(first.directories.index)) ?? []
        check("index relu identique", reloaded == first.books, "\(reloaded.count) livres relus")
        let directories = first.directories
        library = nil

        // 2. Relance : lecture de l'index au démarrage (sur le thread principal), puis parcours sans changement.
        let store = await step("relance : chargement de l'index", note: "\(indexSize / 1024) Ko") { LibraryStore() }
        await step("parcours sans changement") {
            await Self.waitIdle(store, count: expected, label: "parcours")
        }
        check("relance sans perte", store.books.count == expected, "\(store.books.count) sur \(expected)")

        // 3. Ajout puis retrait de 1 % de fichiers.
        let added = max(10, n / 100)
        let folder = await step("création de \(added) livres de plus") {
            (try? StressData.addBooks(start: 10_000_000, count: added, in: set.books)) ?? set.books
        }
        await step("parcours après ajout de 1 %") {
            await store.rescan()
            await Self.waitIdle(store, count: expected + added, label: "ajout")
        }
        check("livres ajoutés indexés", store.books.count == expected + added, "\(store.books.count) sur \(expected + added)")
        try? FileManager.default.removeItem(at: folder)
        await step("parcours après retrait de 1 %") {
            await store.rescan()
            await Self.waitIdle(store, count: expected, label: "retrait")
        }
        check("livres retirés", store.books.count == expected, "\(store.books.count) sur \(expected)")

        // 4. Calculs que les vues refont à chaque rendu (caches vidés par la moindre modification).
        await step("identités (doublons, groupes)") { _ = store.identities }
        await step("livres visibles (visibleBooks)") { _ = store.visibleBooks.count }
        let visible = store.visibleBooks
        await step("groupes de la liste (BookGroups.make)") { _ = BookGroups.make(visible, identities: store.identities).count }
        await step("tri par titre") {
            _ = visible.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.count
        }
        await step("recherche « jardin »") {
            _ = visible.filter { b in
                [b.title, b.authorLine, b.series ?? "", b.labels.joined(separator: " ")].contains { $0.localizedStandardContains("jardin") }
            }.count
        }
        await step("listes de la barre latérale") {
            let ids = store.identities
            _ = (TagNames.groups(visible, identities: ids).count, AuthorNames.groups(visible).count,
                 SeriesNames.groups(visible).count, GenreNames.groups(visible, identities: ids).count, store.bookCount(visible))
        }

        // 5. Actions de masse, comme dans l'interface.
        let tagKey = TagNames.key("À lire")
        let tagged = store.books.filter { TagNames.has($0, key: tagKey) }.count
        await step("renommer une étiquette", note: "\(tagged) fichiers") { store.renameTag(key: tagKey, to: "Pile") }
        check("étiquette renommée", !store.books.contains { TagNames.has($0, key: tagKey) }
              && store.books.filter { TagNames.has($0, key: TagNames.key("Pile")) }.count == tagged)
        await step("supprimer une étiquette") { store.deleteTag(key: TagNames.key("Pile")) }
        let selection = Array(store.visibleBooks.prefix(1000))
        await step("étiqueter 1 000 livres (annulable)") {
            store.undoable("Stress") { store.addTag("Stress", to: selection) }
        }
        // Ce que paie le rendu qui suit une retouche : identités reprises (étiquette) ou recalculées (titre).
        await step("identités après une étiquette") { _ = store.identities }
        if var retitled = store.visibleBooks.first {
            retitled.title += " (corrigé)"
            store.update(retitled)
            await step("identités après un titre corrigé") { _ = store.identities }
        }
        // Comme « Mettre à la corbeille » sur une sélection (BookCommands) : un seul appel pour la sélection.
        let victims = Array(store.visibleBooks.prefix(50))
        await step("50 livres à la corbeille", note: "sélection en un appel, comme BookCommands") {
            store.undoable("Stress") { store.moveToTrash(victims) }
        }
        check("corbeille remplie", store.trashedBooks.count >= 50, "\(store.trashedBooks.count) fichiers")
        await step("50 livres restaurés") { store.restoreFromTrash(victims) }
        check("corbeille vide", store.trashedBooks.isEmpty, "\(store.trashedBooks.count) fichiers")
        await step("enregistrement (saveNow)") { store.saveNow() }

        // 6. Ce que la bibliothèque occupe.
        let covers = Self.folderSize(directories.covers)
        let final = (try? FileManager.default.attributesOfItem(atPath: directories.index.path)[.size] as? Int) ?? 0

        writeReport(to: report, files: expected, indexBytes: final, covers: covers)
    }

    /// Attend la fin du parcours (et que le nombre de livres soit atteint), en affichant l'avancement.
    private static func waitIdle(_ store: LibraryStore, count: Int, label: String) async {
        let end = Date().addingTimeInterval(4 * 3600)
        var lastPrint = Date()
        // Le parcours lancé par `init` démarre dans une tâche : attendre qu'il ait commencé ou fini.
        try? await Task.sleep(for: .milliseconds(100))
        while (store.isScanning || store.books.count < count) && Date() < end {
            if Date().timeIntervalSince(lastPrint) > 15, let p = store.progress {
                print("  \(label) : \(p.done) / \(p.total)")
                lastPrint = Date()
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func folderSize(_ url: URL) -> (files: Int, bytes: Int64) {
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = items.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return (items.count, bytes)
    }

    private func writeReport(to folder: URL, files: Int, indexBytes: Int, covers: (files: Int, bytes: Int64)) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var md = """
            # Test de résistance : \(n) livres

            \(Date().formatted(date: .abbreviated, time: .shortened)) · \(files) fichiers · index \(indexBytes / 1024) Ko · \
            \(covers.files) couvertures (\(covers.bytes / 1_048_576) Mo) · \(failures == 0 ? "aucun échec" : "\(failures) échec(s)")

            | Étape | Durée (ms) | Blocage max (ms) | Blocages > 250 ms | Mémoire max (Mo) | Processeur (ms) | Note |
            | --- | ---: | ---: | ---: | ---: | ---: | --- |

            """
        for s in steps {
            md += String(format: "| %@ | %.0f | %.0f | %d | %.0f | %.0f | %@ |\n", s.name, s.milliseconds,
                         s.maxStallMilliseconds, s.stallsOver250ms, s.peakFootprintMB, s.cpuMilliseconds, s.note)
        }
        try? md.write(to: folder.appendingPathComponent("rapport-\(n).md"), atomically: true, encoding: .utf8)
        struct Report: Codable { let books: Int; let files: Int; let indexBytes: Int; let coverFiles: Int; let coverBytes: Int64; let failures: Int; let steps: [Step] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let json = try? encoder.encode(Report(books: n, files: files, indexBytes: indexBytes, coverFiles: covers.files,
                                                coverBytes: covers.bytes, failures: failures, steps: steps)) {
            try? json.write(to: folder.appendingPathComponent("rapport-\(n).json"))
        }
        print("Rapport : \(folder.appendingPathComponent("rapport-\(n).md").path)")
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}
