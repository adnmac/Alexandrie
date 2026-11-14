# Foluna

App macOS SwiftUI (paquet SwiftPM, Swift 6, macOS 14+) qui gère une bibliothèque de livres
et les charge sur une liseuse par USB. Voir `README.md` pour les fonctions et l'architecture.

Nom affiché : **Foluna** (contact info@foluna.app, dépôt `adnmac/Foluna`). Le code s'appelle aussi Foluna :
cibles `Foluna`/`FolunaCore`, exécutable, variables `FOLUNA_*`. Seuls gardent le nom d'origine, et ne doivent
jamais être renommés : l'identifiant `be.adnmac.alexandrie` (autorisations, réglages, Trousseau et vérification
des mises à jour en dépendent), le dossier de données `~/Library/Application Support/Alexandrie/` (l'index y
référence les imports par chemin complet), le certificat « Alexandrie Dev », le marqueur des PDF annotés
(`PDFPageView.marker`) et la reprise des anciennes copies `Alexandrie.app` (mise à jour, `bundle.sh`, `release.sh`).
Tout texte affiché dit « Foluna ».

Répondre, commenter et écrire les commits en français (Conventional Commits).

Interface en cinq langues (fr, en, nl, de, es) : catalogue `Resources/Localizable.xcstrings`, français en langue source.
Tout texte affiché passe par une API qui traduit (`Text("…")`, `Button("…")`…) ou par `String(localized: "…")` ;
après un changement de texte : `scripts/l10n.sh sync`, traduire les nouvelles clés (glossaire `docs/l10n-glossaire.md`),
puis `scripts/l10n.sh check` (appelé par `scripts/test.sh` et donc par la CI). Singulier et pluriel : clés distinctes
dans le cœur (`count == 1 ? … : …`), variantes de pluriel du catalogue dans l'app. Captures dans une autre langue :
`FOLUNA_SNAPSHOT_LANG=en scripts/snap.sh`.

Règles de design : `design/DESIGN-SYSTEM.md`. Utiliser ses jetons (`Palette`, `Radius`, `Motion`, `Surface`, `Layout`, `Space`) ; jamais de couleur, de rayon ou de durée brute.

## Skills BAMA

Les skills de [BAMA](https://github.com/daveebbelaar/bama) sont dans `.claude/skills/`
(copie du commit noté dans `.claude/skills/BAMA-COMMIT`, licence MIT). `/bama` choisit le skill
selon la tâche. Foluna n'a pas été créée avec le modèle `new-mac-app` : utiliser la
correspondance ci-dessous à la place des commandes du modèle.

| Pièce du modèle BAMA | Équivalent dans Foluna |
| --- | --- |
| `./build.sh` | `scripts/bundle.sh` (release, construit `build/Foluna.app`, signé Apple Development, sinon « Alexandrie Dev », sinon ad hoc, puis copié dans `~/Applications` ; `FOLUNA_INSTALL=0` pour s'en passer) |
| `./build.sh --debug` | `scripts/build.sh` (debug, sans bundle) |
| `./build.sh --open` | `scripts/bundle.sh && open ~/Applications/Foluna.app` (quitter l'app avant, sinon la copie n'est pas mise à jour) |
| `UI/Grid.swift`, `tools/grid-lint.sh`, `tools/check-layout.swift`, `APP_GRID=1` | `Sources/Foluna/UI/Grid.swift` (jetons `Space`, sondes `.gridArea`/`.gridProbe`), `scripts/grid-lint.sh` (vues seulement), `swift scripts/check-layout.swift /tmp/foluna-shots/*-layout.json` (fichiers écrits par `scripts/snap.sh`), `FOLUNA_GRID=1` dessine la grille. Sondes posées sur la fiche du livre (zone `fiche`) |
| `swift test` | `scripts/test.sh` (charge les plugins de macros si seules les Command Line Tools sont actives) ; `FOLUNA_FIXTURES=/dossier scripts/test.sh` pour les vrais livres |
| Cible `<App>Kit` testable | `Sources/FolunaCore` (logique sans interface), tests dans `Tests/FolunaCoreTests` |
| Swift 6, isolation par défaut | Swift 6 (`swiftLanguageModes: [.v6]`), **sans** isolation `MainActor` par défaut : annoter `@MainActor` |
| `APP_STORE=/tmp/...` | `FOLUNA_STORE=/tmp/...` : dossier de données de test (index, couvertures, conversions, imports). Le dossier de livres vient alors de `FOLUNA_BOOKS` (jamais du signet de l'utilisateur), sans vérification en ligne ni recherche de mises à jour. Les autres réglages (`UserDefaults`) restent partagés |
| `APP_SNAPSHOT` / `tools/snap.sh` / `APP_SEED=1` | `scripts/snap.sh` : 14 livres d'exemple (`SeedData.swift`) dans `/tmp/foluna-snap`, puis une capture par page de la barre latérale, par onglet des réglages (`reglages-<onglet>`) et par feuille (`feuille-<nom>`), en clair et en sombre, dans `/tmp/foluna-shots` (`Snapshot.swift`). Bundle de test `be.adnmac.alexandrie.snapshot` (langue fr, réglages séparés). `FOLUNA_SNAPSHOT_PAGES=tous,reglages,feuilles` limite les pages, `FOLUNA_SNAPSHOT_FULLSCREEN=1` met la fenêtre en plein écran, `FOLUNA_SNAPSHOT_STORE=/tmp/…` change le dossier de test (captures du site : `/tmp/Foluna`) |
| `--selftest` / `tools/selftest.sh` | `scripts/selftest.sh` : compile en debug, vide `/tmp/foluna-selftest`, lance `Foluna --selftest` sans fenêtre (`Sources/Foluna/SelfTest.swift`). PASS/FAIL par étape, code 0 si tout passe. Refuse de tourner sans `FOLUNA_STORE` ou sur un dossier non vide |
| `Icon/AppIcon.icon`, `tools/make_icon.sh`, `tools/icon_review.sh` | `Icon/AppIcon.icon` (calques SVG dessinés à la main, aucun symbole SF), `scripts/make-icon.sh` (actool, Xcode avec licence acceptée) écrit `Resources/Assets.car` et `Resources/AppIcon.icns`, versionnés ; `scripts/icon-review.sh` écrit la planche `/tmp/foluna-icon.png` |
| Test de résistance (hors modèle) | `scripts/stress.sh [1000 10000 50000 100000]` : vrai `LibraryStore` sans fenêtre (`Foluna --stress <n>`, `StressTest.swift`) sur des livres inventés (`StressData.swift`, gardés dans `/tmp/foluna-stress-data/<n>`), rapports et `synthese.md` dans `/tmp/foluna-stress`. `scripts/stress-ui.sh <n>` visite l'interface sur le store indexé (`StressUI.swift`). `FOLUNA_STRESS=1 scripts/test.sh -c release -Xswiftc -enable-testing --filter StressTests` : bancs d'essai du cœur. `FOLUNA_HANGLOG=1` écrit les blocages du thread principal (> 250 ms) sur stderr. Résultats : `docs/PERF.md` |
| `release` | `scripts/release.sh X.Y.Z` (publie sur GitHub, l'app propose la mise à jour) |

Site foluna.app : dossier voisin `../Foluna-Website` (pages dans `src/en` et `src/fr`, `python3 build.py`, `./deploy.sh` puis `./deploy.sh --go`).
Ses captures ne montrent que des livres inventés ou du domaine public.

Ne jamais faire de captures ni de tests contre les vraies données de
`~/Library/Application Support/Alexandrie/` : toujours `FOLUNA_STORE` dans `/tmp`.

Après un changement d'interface : `scripts/grid-lint.sh`, `scripts/snap.sh`, `swift scripts/check-layout.swift /tmp/foluna-shots/*-layout.json`, puis regarder les PNG des pages touchées (clair et sombre).
Sans l'autorisation Enregistrement de l'écran, les captures passent par un rendu de secours (matériaux et verre non fidèles).

Après un changement dans `LibraryStore` ou ses services : `scripts/test.sh` puis `scripts/selftest.sh`.
Une nouvelle fonction de `LibraryStore` reçoit une étape dans `SelfTest.swift`.

## Pièges

- La CI GitHub (`macos-15`) a un Swift plus ancien que le Swift local : éviter les
  fonctions de langage trop récentes.
- L'action Raccourcis (`SendToKindleIntent`) n'apparaît que si le bundle contient `Metadata.appintents`.
  `scripts/bundle.sh` le produit avec `appintentsmetadataprocessor` de Xcode, à partir des
  `.swiftconstvalues` de la build release ; sans Xcode, il prévient et l'app n'a pas l'action.
- Les menus (`Commands`) ne lisent ni l'état observé ni `@FocusedValue` : ils reçoivent les valeurs
  de `MenuState` par l'`App` (voir `docs/FIXLOG.md`).
