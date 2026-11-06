# Bilan d'architecture — 2026-11-06 (fin du jalon M5)

Points chauds sur 30 jours : `ContentView.swift` (29 commits), `LibraryStore.swift` (19),
`LibraryView.swift` (16), `BookDetailView.swift` (15). Plus gros fichiers : `LibraryStore.swift` (752 lignes),
`EPUBToAZW3.swift` (647), `ContentView.swift` (586), `BookDetailView.swift` (527).
Aucune copie dérivée de `private struct`. Pas encore de `docs/FIXLOG.md`.

## Fenêtre principale réduite à la fenêtre  [Strong]

Files: Sources/Alexandrie/Views/ContentView.swift (586 lignes, 7 types)
Signal: fichier le plus modifié ; « unable to type-check this expression » pendant S-042.
Problem: le fichier mêle la fenêtre principale, la navigation (`SidebarItem`, `SortOrder`), la feuille
« Nouvelle liseuse », le bouton d'envoi, deux bandeaux de mise à jour et l'écran d'accueil. Changer un
bandeau oblige à ouvrir le fichier de la fenêtre, et chaque histoire de M5 y a touché.
Proposal: un fichier par sujet, sans changer une ligne de comportement :
- `Views/Navigation.swift` : `SidebarItem` (avec `allowsTrash`, `storageKey`), `SortOrder`, `libraryList`.
- `Views/KindleSend.swift` : `KindleSendButton`, `KindleSendLabel`.
- `Views/NameReaderSheet.swift` : la feuille « Nouvelle liseuse ».
- `Views/UpdateBanners.swift` : `ReleaseBanner`, `UpdateBanner`.
- `Views/OnboardingView.swift` : l'écran d'accueil.
Benefits: localité (un bandeau se change dans son fichier) ; `ContentView.swift` passe sous 300 lignes.
Proof of same behavior: compilation, `scripts/test.sh` (90 tests), `scripts/selftest.sh`, et un diff
dont chaque ligne retirée est rajoutée ailleurs (seuls ajouts : les `import` des nouveaux fichiers).
Les empreintes des captures ne servent pas de preuve : deux passages du même binaire donnent déjà des
PNG différents (rendu de secours, minuteries).
Plan: un commit (déplacements seuls). **Fait** : `ContentView.swift` passe de 586 à 372 lignes.

## Filtrage des pages dans le cœur  [Worth exploring]

Files: ContentView.swift (`filteredBooks`, 40 lignes), Navigation
Signal: logique pure dans une vue `@MainActor`, que les tests ne peuvent pas compiler seuls.
Problem: « Ajoutés récemment », tri par série, recherche dans les notes : aucune de ces règles n'a de test.
Proposal: `LibraryPage` (ex-`SidebarItem`) dans `AlexandrieCore`, et
`LibraryFilter.books(_ books: [Book], page: LibraryPage, query: String, sort: SortOrder, noteTitles: Set<String>, now: Date) -> [Book]`.
Benefits: tests de table sur chaque page ; la vue ne fait plus que lire.
Proof of same behavior: tests écrits contre l'ancien comportement avant le déplacement, captures identiques.
Plan: 1) tests sur le comportement actuel ; 2) déplacer le type ; 3) déplacer la fonction.

## Actions du livre en un seul endroit  [Worth exploring]

Files: Services/BookCommands.swift, Views/LibraryView.swift (`BookActions`), Views/BookDetailView.swift
Signal: même règle écrite deux fois (menu Livre et menu du livre : corbeille, export EPUB, Ouvrir).
Problem: S-041 a dû aligner à la main la règle de la corbeille entre les deux menus.
Proposal: `BookActions` (clic droit) construit un `BookCommands` pour son livre et appelle ses `can…`
et ses actions ; les intitulés restent dans la vue.
Benefits: une règle, un endroit ; le self-test couvre aussi le clic droit.
Proof of same behavior: self-test, essai du clic droit sur chaque page.
Plan: un commit par action déplacée.

## Magasin de la bibliothèque en extensions  [Worth exploring]

Files: Services/LibraryStore.swift (752 lignes, 13 sections MARK)
Signal: fichier de plus de 600 lignes.
Problem: chaque fonction (corbeille, file d'envoi, étagères, sauvegardes) rouvre ce fichier, mais les
règles elles-mêmes sont déjà dans le cœur et testées (`KindleQueueTests`, `ShelfTests`…).
Proposal: `LibraryStore+Queue.swift`, `+Shelves.swift`, `+Catalog.swift`, `+Backups.swift` ; même type.
Benefits: localité seulement. À faire avant d'atteindre 1 000 lignes.

## Recommandation principale

**Fenêtre principale réduite à la fenêtre** : forte, sans risque (déplacements), et elle touche le fichier
le plus modifié. Faite à la fin de M5. Les trois autres cartes attendent ton choix.

Considéré, non recommandé :
- `EPUBToAZW3.swift` (647 lignes) : stable, peu modifié, couvert par `RealBookTests` ; le découper n'apporte rien maintenant.
- Protocoles pour `KindleMonitor` : un seul usage réel, les tests passent par le cœur.
