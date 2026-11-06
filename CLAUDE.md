# Alexandrie

App macOS SwiftUI (paquet SwiftPM, Swift 6, macOS 14+) qui gère une bibliothèque de livres
et les charge sur une Kindle par USB. Voir `README.md` pour les fonctions et l'architecture.

Répondre, commenter et écrire les commits en français (Conventional Commits).

Règles de design : `design/DESIGN-SYSTEM.md`. Utiliser ses jetons (`Palette`, `Radius`, `Motion`, `Surface`, `Layout`, `Space`) ; jamais de couleur, de rayon ou de durée brute.

## Skills BAMA

Les skills de [BAMA](https://github.com/daveebbelaar/bama) sont dans `.claude/skills/`
(copie du commit noté dans `.claude/skills/BAMA-COMMIT`, licence MIT). `/bama` choisit le skill
selon la tâche. Alexandrie n'a pas été créée avec le modèle `new-mac-app` : utiliser la
correspondance ci-dessous à la place des commandes du modèle.

| Pièce du modèle BAMA | Équivalent dans Alexandrie |
| --- | --- |
| `./build.sh` | `scripts/bundle.sh` (release, construit `build/Alexandrie.app`, signé « Alexandrie Dev » ou ad hoc) |
| `./build.sh --debug` | `scripts/build.sh` (debug, sans bundle) |
| `./build.sh --open` | `scripts/bundle.sh && open build/Alexandrie.app` (quitter l'app avant) |
| `UI/Grid.swift`, `tools/grid-lint.sh`, `tools/check-layout.swift`, `APP_GRID=1` | `Sources/Alexandrie/UI/Grid.swift` (jetons `Space`, sondes `.gridArea`/`.gridProbe`), `scripts/grid-lint.sh` (vues seulement), `swift scripts/check-layout.swift /tmp/alexandrie-shots/*-layout.json` (fichiers écrits par `scripts/snap.sh`), `ALEXANDRIE_GRID=1` dessine la grille. Sondes posées sur la fiche du livre (zone `fiche`) |
| `swift test` | `scripts/test.sh` (charge les plugins de macros si seules les Command Line Tools sont actives) ; `ALEXANDRIE_FIXTURES=/dossier scripts/test.sh` pour les vrais livres |
| Cible `<App>Kit` testable | `Sources/AlexandrieCore` (logique sans interface), tests dans `Tests/AlexandrieCoreTests` |
| Swift 6, isolation par défaut | Swift 6 (`swiftLanguageModes: [.v6]`), **sans** isolation `MainActor` par défaut : annoter `@MainActor` |
| `APP_STORE=/tmp/...` | `ALEXANDRIE_STORE=/tmp/...` : dossier de données de test (index, couvertures, conversions, imports). Le dossier de livres vient alors de `ALEXANDRIE_BOOKS` (jamais du signet de l'utilisateur), sans vérification en ligne ni recherche de mises à jour. Les autres réglages (`UserDefaults`) restent partagés |
| `APP_SNAPSHOT` / `tools/snap.sh` / `APP_SEED=1` | `scripts/snap.sh` : 14 livres d'exemple (`SeedData.swift`) dans `/tmp/alexandrie-snap`, puis une capture par page de la barre latérale, par onglet des réglages (`reglages-<onglet>`) et par feuille (`feuille-<nom>`), en clair et en sombre, dans `/tmp/alexandrie-shots` (`Snapshot.swift`). Bundle de test `be.adnmac.alexandrie.snapshot` (langue fr, réglages séparés). `ALEXANDRIE_SNAPSHOT_PAGES=tous,reglages,feuilles` limite les pages |
| `--selftest` / `tools/selftest.sh` | `scripts/selftest.sh` : compile en debug, vide `/tmp/alexandrie-selftest`, lance `Alexandrie --selftest` sans fenêtre (`Sources/Alexandrie/SelfTest.swift`). PASS/FAIL par étape, code 0 si tout passe. Refuse de tourner sans `ALEXANDRIE_STORE` ou sur un dossier non vide |
| `Icon/AppIcon.icon`, `tools/make_icon.sh`, `tools/icon_review.sh` | `Icon/AppIcon.icon` (calques SVG dessinés à la main, aucun symbole SF), `scripts/make-icon.sh` (actool, Xcode avec licence acceptée) écrit `Resources/Assets.car` et `Resources/AppIcon.icns`, versionnés ; `scripts/icon-review.sh` écrit la planche `/tmp/alexandrie-icon.png` |
| `release` | `scripts/release.sh X.Y.Z` (publie sur GitHub, l'app propose la mise à jour) |

Ne jamais faire de captures ni de tests contre les vraies données de
`~/Library/Application Support/Alexandrie/` : toujours `ALEXANDRIE_STORE` dans `/tmp`.

Après un changement d'interface : `scripts/grid-lint.sh`, `scripts/snap.sh`, `swift scripts/check-layout.swift /tmp/alexandrie-shots/*-layout.json`, puis regarder les PNG des pages touchées (clair et sombre).
Sans l'autorisation Enregistrement de l'écran, les captures passent par un rendu de secours (matériaux et verre non fidèles).

Après un changement dans `LibraryStore` ou ses services : `scripts/test.sh` puis `scripts/selftest.sh`.
Une nouvelle fonction de `LibraryStore` reçoit une étape dans `SelfTest.swift`.

## Pièges

- La CI GitHub (`macos-15`) a un Swift plus ancien que le Swift local : éviter les
  fonctions de langage trop récentes.
