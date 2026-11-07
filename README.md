# Alexandrie

Bibliothèque de livres pour macOS qui charge vos livres sur une Kindle **par câble USB**, sans Calibre.

- Indexe un ou plusieurs dossiers de livres existants (EPUB, MOBI, AZW3, AZW, PDF) **sans jamais les modifier** ; un dossier sur un disque débranché garde ses livres, indisponibles jusqu'au rebranchement.
- Extrait titre, auteurs, langue, éditeur, résumé et couverture ; recherche, tri, filtres par format et auteur.
- Titre, auteurs, éditeur, date de publication, ISBN, langue, résumé et étiquettes corrigeables dans l'app ;
  les corrections sont appliquées aux copies envoyées sur la Kindle (le fichier source reste intact).
- Correction directe d'un livre déjà sur la Kindle (MOBI/AZW3 sans DRM) : seules les métadonnées du fichier sont réécrites.
- Vérification en ligne des nouveaux livres auprès de la **BnF** puis d'**Open Library** (par ISBN, ou par titre et auteur) :
  les différences sont proposées dans la fiche, rien n'est modifié sans validation. Filtre « À vérifier » dans la barre latérale.
- Envoi sur la Kindle : copie directe des MOBI/AZW3/PDF, **conversion automatique EPUB → AZW3** (la Kindle ne lit pas l'EPUB par USB), avec miniature de couverture.
- **Fenêtre de lecture** (⌘L ou double-clic) pour EPUB, MOBI, AZW3 et PDF : pages au clavier, table des matières, reprise là où la lecture s'est arrêtée (« % lu » dans la fiche), taille du texte et fond clair, sépia ou sombre, surlignages (⇧⌘H) rangés avec ceux de la Kindle dans « Notes et surlignages », et leurs notes (clic sur le passage surligné) et couleurs, modifiables des deux côtés. Des thématiques (« Rénovation des voiries », un mémoire) classent les surlignages, un passage pouvant en avoir plusieurs, et nomment leurs couleurs (jaune = construction) ; la fenêtre de lecture choisit la thématique du livre, les notes se filtrent par couleurs et par thématiques, et chaque thématique a sa page dans la barre latérale : toutes ses notes, de tous les livres, triées par couleur nommée, par livre ou par date, et exportées en Markdown dans cet ordre.
- PDF : tel quel, **marges rognées** (le texte paraît plus grand) ou **texte redimensionnable** (texte extrait en AZW3, chapitres d'après la table du PDF) ; l'original n'est jamais modifié.
- **Conversion MOBI/AZW3 → EPUB** (KF7, KF8 et fichiers hybrides).
- Kindle en **disque USB** (modèles jusqu'à 2023) et en **MTP** (modèles depuis fin 2024, via libmtp).

## Compiler et lancer

```bash
scripts/bundle.sh               # construit build/Alexandrie.app (release) et la copie dans ~/Applications
open build/Alexandrie.app
```

Autres scripts : `scripts/build.sh [release]`, `scripts/test.sh`, `scripts/selftest.sh` (self-test de l'app sur des données de test dans `/tmp`), `scripts/snap.sh` (captures de chaque page en clair et en sombre, avec des livres d'exemple).

### Signature et versions

`scripts/bundle.sh` signe l'app avec un certificat **Apple Development** s'il existe (gratuit : Xcode › Réglages ›
Comptes › ton identifiant Apple › Gérer les certificats › + › Apple Development ; le trousseau doit aussi contenir
l'intermédiaire [Apple WWDR G3](https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer)).
L'action Raccourcis ne s'exécute qu'avec ce certificat, qui porte un team ID.
À défaut, il prend le certificat « Alexandrie Dev » (Trousseaux d'accès › Assistant de certification ›
Créer un certificat : racine auto-signée, signature de code).
Avec une signature stable, macOS garde les autorisations de l'app (disque de la Kindle…) d'une version à l'autre ;
sans certificat, la signature est ad hoc.

`scripts/release.sh X.Y.Z` publie une version sur GitHub (app signée, zippée). L'app installée la signale et propose
« Installer et relancer » : elle télécharge la version, vérifie qu'elle porte la même signature, puis la remplace.
Avec les seules Command Line Tools, ces scripts chargent les plugins de macros SwiftUI et Swift Testing
depuis `/Applications/Xcode.app` (Xcode doit être installé, mais sa licence n'a pas besoin d'être acceptée).

### Kindle récentes (MTP)

```bash
brew install libmtp
```

libmtp est chargée à l'exécution : sans elle, l'app fonctionne avec les Kindle « disque USB » uniquement.
Fermez Android File Transfer (ou tout outil MTP) avant de brancher la Kindle.

## Données

Tout ce que l'app produit est dans `~/Library/Application Support/Alexandrie/` :

| Élément | Rôle |
|---|---|
| `library.json` | index de la bibliothèque |
| `Covers/` | couvertures réduites |
| `Conversions/` | AZW3 et EPUB convertis (cache) |
| `Imports/` | livres ajoutés par glisser-déposer ou « Importer » |

Les couvertures et conversions qui ne servent plus sont supprimées après chaque rescan ; les réglages affichent
la taille de ces caches et permettent de vider les conversions. Un `library.json` illisible n'est jamais écrasé :
il est renommé en `library.corrupt-<date>.json` et la bibliothèque est réindexée (les retouches restent dans ce fichier).

## Architecture

- `Sources/AlexandrieCore` : logique sans interface (testable)
  - `EPUB/` lecture (OPF, nav, NCX) et écriture EPUB 3
  - `Mobi/` PalmDB, en-têtes MOBI/EXTH, PalmDoc, HUFF/CDIC, index INDX/TAGX/CNCX
  - `Conversion/` `MobiToEPUB` (inspiré de KindleUnpack) et `EPUBToAZW3` (inspiré du writer KF8 de calibre)
  - `Library/` scanner, empreintes, couvertures, index JSON
  - `Kindle/` détection et transfert (disque monté, MTP)
- `Sources/CMTPShim` : pont C vers libmtp (dlopen)
- `Sources/Alexandrie` : app SwiftUI
  - `Views/` une vue par fichier (`ContentView` : la fenêtre principale ; `Navigation` : pages de la barre latérale)
  - `Services/` état de l'app (`LibraryStore`, `KindleMonitor`, `UpdateMonitor`) et `BookCommands`, les commandes
    sur la sélection partagées par la barre des menus et le self-test
  - `UI/` jetons du système de design (voir `design/DESIGN-SYSTEM.md`)

## Tests

```bash
scripts/test.sh
ALEXANDRIE_FIXTURES=/dossier/de/livres scripts/test.sh   # + conversions sur de vrais fichiers
```

## Limites

- Les livres protégés par DRM ne sont ni convertis ni déverrouillés (un AZW3 acheté peut toutefois être recopié tel quel).
- Le format KFX n'est pas pris en charge.
- La conversion EPUB → AZW3 vise les livres courants (texte, images, CSS, table des matières) ; les mises en page complexes peuvent être moins fidèles qu'avec Calibre.
