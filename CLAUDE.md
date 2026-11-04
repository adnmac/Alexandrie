# Alexandrie

App macOS SwiftUI (paquet SwiftPM, Swift 6, macOS 14+) qui gère une bibliothèque de livres
et les charge sur une Kindle par USB. Voir `README.md` pour les fonctions et l'architecture.

Répondre, commenter et écrire les commits en français (Conventional Commits).

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
| `swift test` | `scripts/test.sh` (charge les plugins de macros si seules les Command Line Tools sont actives) ; `ALEXANDRIE_FIXTURES=/dossier scripts/test.sh` pour les vrais livres |
| Cible `<App>Kit` testable | `Sources/AlexandrieCore` (logique sans interface), tests dans `Tests/AlexandrieCoreTests` |
| Swift 6, isolation par défaut | Swift 6 (`swiftLanguageModes: [.v6]`), **sans** isolation `MainActor` par défaut : annoter `@MainActor` |
| `APP_STORE=/tmp/...` | `ALEXANDRIE_STORE=/tmp/...` : dossier de données de test (index, couvertures, conversions, imports). Le dossier de livres vient alors de `ALEXANDRIE_BOOKS` (jamais du signet de l'utilisateur), sans vérification en ligne ni recherche de mises à jour. Les autres réglages (`UserDefaults`) restent partagés |
| `APP_SNAPSHOT` / `tools/snap.sh` | **Absent.** Captures manuelles avec `screencapture -l <fenêtre>` ou via un pont de debug (voir `build-and-verify/existing-app.md`) |
| `--selftest` / `tools/selftest.sh` | `scripts/selftest.sh` : compile en debug, vide `/tmp/alexandrie-selftest`, lance `Alexandrie --selftest` sans fenêtre (`Sources/Alexandrie/SelfTest.swift`). PASS/FAIL par étape, code 0 si tout passe. Refuse de tourner sans `ALEXANDRIE_STORE` ou sur un dossier non vide |
| `release` | `scripts/release.sh X.Y.Z` (publie sur GitHub, l'app propose la mise à jour) |

Ne jamais faire de captures ni de tests contre les vraies données de
`~/Library/Application Support/Alexandrie/` : toujours `ALEXANDRIE_STORE` dans `/tmp`.

Après un changement dans `LibraryStore` ou ses services : `scripts/test.sh` puis `scripts/selftest.sh`.
Une nouvelle fonction de `LibraryStore` reçoit une étape dans `SelfTest.swift`.

## Pièges

- La CI GitHub (`macos-15`) a un Swift plus ancien que le Swift local : éviter les
  fonctions de langage trop récentes.
