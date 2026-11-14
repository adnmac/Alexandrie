import AppKit
import FolunaCore
import SwiftUI

/// Visite de l'interface sur une grosse bibliothèque (voir `scripts/stress-ui.sh`) :
///
///     FOLUNA_STORE=/tmp/… FOLUNA_STRESS_UI=/tmp/foluna-stress Foluna
///
/// ouvre chaque page de la barre latérale, une fiche, la liste, puis tape une recherche, et note pour chacune
/// le plus long blocage du thread principal pendant les 2 s qui suivent. Écrit `interface-<n>.md` et quitte.
/// Jamais sur les vraies données.
@MainActor
enum StressUI {
    static var directory: String? {
        ProcessInfo.processInfo.environment["FOLUNA_STRESS_UI"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func run(library: LibraryStore, sidebar: Binding<SidebarItem?>, selection: Binding<Set<String>>,
                    search: Binding<String>) async {
        guard let dir = directory else { return }
        guard AppDirectories.testStore != nil else {
            print("STRESS-UI refusé : FOLUNA_STORE doit désigner un dossier de test dans /tmp")
            NSApp.terminate(nil)
            return
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        let watchdog = MainThreadWatchdog()
        watchdog.start()
        // Index déjà construit par `scripts/stress.sh` : on attend le parcours de vérification.
        let start = ContinuousClock.now
        try? await Task.sleep(for: .milliseconds(300))
        while library.isScanning { try? await Task.sleep(for: .milliseconds(100)) }
        // Identités et résumé prêts (calculés en arrière-plan sur une grande bibliothèque).
        while !library.identitiesReady || library.summary.authors.isEmpty {
            if ContinuousClock.now - start > .seconds(120) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        var rows: [(String, Duration, MainThreadWatchdog.Window)] = []
        rows.append(("ouverture et parcours", ContinuousClock.now - start, watchdog.take()))

        func measure(_ name: String, _ action: () -> Void) async {
            _ = watchdog.take()
            action()
            try? await Task.sleep(for: .seconds(2))
            let w = watchdog.take()
            rows.append((name, .zero, w))
            print(String(format: "UI %@ : blocage max %@ ms (%d > 250 ms)", name, MainThreadWatchdog.ms(w.maxStall), w.stallsOver250ms))
        }

        let books = library.visibleBooks
        // Listes déjà calculées par la barre latérale : les recalculer ici bloquait la mesure de l'ouverture.
        let summary = library.summary
        let tag = summary.tags.first
        let author = summary.authors.first
        let series = summary.series.first
        var pages: [(String, SidebarItem)] = [("Tous", .all), ("Récents", .recent), ("À vérifier", .toReview),
                                              ("Format EPUB", .format(.epub)), ("Format PDF", .format(.pdf)), ("Corbeille", .trash)]
        if let tag { pages.append(("Étiquette", .tag(tag.key))) }
        if let author { pages.append(("Auteur", .author(author.key))) }
        if let series { pages.append(("Série", .series(series.key))) }

        for gridMode in [true, false] {
            UserDefaults.standard.set(gridMode, forKey: "gridMode")
            let mode = gridMode ? "grille" : "liste"
            for (name, item) in pages {
                await measure("\(name) (\(mode))") { sidebar.wrappedValue = item }
            }
        }
        UserDefaults.standard.set(true, forKey: "gridMode")
        await measure("retour à Tous") { sidebar.wrappedValue = .all }
        await measure("fiche d'un livre") { selection.wrappedValue = books.dropFirst(books.count / 2).first.map { [$0.id] } ?? [] }
        await measure("sélection de 1 000 livres") { selection.wrappedValue = Set(books.prefix(1000).map(\.id)) }
        selection.wrappedValue = []
        // Recherche tapée lettre par lettre : chaque lettre refiltre toute la bibliothèque.
        _ = watchdog.take()
        for prefix in ["j", "ja", "jar", "jard", "jardi", "jardin"] {
            search.wrappedValue = prefix
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .seconds(2))
        rows.append(("recherche tapée « jardin »", .zero, watchdog.take()))
        search.wrappedValue = ""
        await measure("recherche effacée") {}

        var md = """
            # Interface sur \(books.count) livres visibles

            Plus long blocage du thread principal pendant les 2 s qui suivent chaque action.

            | Action | Blocage max (ms) | Blocages > 250 ms | Mémoire max (Mo) |
            | --- | ---: | ---: | ---: |

            """
        for (name, duration, w) in rows {
            let label = duration == .zero ? name : "\(name) (\(MainThreadWatchdog.ms(duration)) ms)"
            md += "| \(label) | \(MainThreadWatchdog.ms(w.maxStall)) | \(w.stallsOver250ms) | \(w.peakFootprint / 1_048_576) |\n"
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("interface-\(library.books.count).md")
        try? md.write(to: url, atomically: true, encoding: .utf8)
        print("Rapport : \(url.path)")
        NSApp.terminate(nil)
    }
}
