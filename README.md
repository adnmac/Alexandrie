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
- **Fenêtre de lecture** (⌘L ou double-clic) pour EPUB, MOBI, AZW3 et PDF : pages au clavier, table des matières, reprise là où la lecture s'est arrêtée (« % lu » dans la fiche), taille du texte, menu « Aa » avec la police (celle du livre, ou une police de macOS avec ou sans empattements : New York, Charter, Iowan Old Style, Georgia, Avenir Next…) et fond clair, sépia ou sombre, surlignages (⇧⌘H) rangés avec ceux de la Kindle dans « Notes et surlignages », d'où ils rouvrent la lecture à leur passage, et leurs notes (clic sur le passage surligné) et couleurs, modifiables des deux côtés. Des thématiques (« Rénovation des voiries », un mémoire) classent les surlignages, un passage pouvant en avoir plusieurs, et nomment leurs couleurs (jaune = construction) ; la fenêtre de lecture choisit la thématique du livre, les notes se filtrent par couleurs et par thématiques, et chaque thématique a sa page dans la barre latérale : toutes ses notes, de tous les livres, triées par couleur nommée, par livre ou par date, et exportées en Markdown dans cet ordre.
- **Recherche dans le contenu** : le champ de recherche cherche dans les titres, auteurs… ou dans le texte des livres (EPUB, MOBI, AZW3, PDF), indexé en arrière-plan, un fichier par livre, avec une option « Écriture exacte » (majuscules et accents) ; chaque livre trouvé montre ses extraits, et un extrait ouvre la fenêtre de lecture au passage, avec la liste des renvois du mot dans la colonne de gauche et ⌘G / ⇧⌘G pour passer de l'un à l'autre.
- PDF : tel quel, **marges rognées** (le texte paraît plus grand) ou **texte redimensionnable** (texte extrait en AZW3, chapitres d'après la table du PDF) ; l'original n'est jamais modifié.
- **Conversion MOBI/AZW3 → EPUB** (KF7, KF8 et fichiers hybrides).
- **Zotero** : « Envoyer à Zotero » (menu Exporter des notes d'un livre ou d'une thématique) copie les passages, notes, couleurs et positions dans une note rattachée à la référence du livre, retrouvée par ISBN ou titre et auteur, ou créée d'après la fiche. Un nouvel envoi met la note à jour, sans doublon ; une thématique donne une note par livre. Les notes restent dans Alexandrie : ce qui change dans Zotero ne revient pas. Il faut Zotero 10 ou plus récent, ouvert, avec Réglages › Avancés › « Autoriser d'autres applications de cet ordinateur à communiquer avec Zotero », et « Toujours autoriser » au premier envoi.
- **Catalogues en ligne (OPDS)** : Project Gutenberg, Ebooks libres et gratuits et la Bibliothèque numérique romande sont proposés dans la barre latérale ; on peut ajouter l'adresse de tout catalogue OPDS 1.2 public (https, sans compte). On parcourt ses rubriques, on y cherche depuis le champ de recherche (touche Retour), un menu « Langue » ne garde que les livres de cette langue (chez Gutenberg, recherches et listes sont restreintes par le serveur), et « Télécharger » ajoute le livre à la bibliothèque comme un import ; l'envoi sur la Kindle se fait ensuite depuis sa fiche. Les livres payants ou sous DRM sont ignorés.
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
| `Imports/` | livres ajoutés par glisser-déposer, « Importer » ou téléchargés d'un catalogue en ligne |
| `opds.json` | catalogues en ligne ajoutés, et livres qui en ont été téléchargés |
| `zotero.json` | références et notes Zotero reliées à chaque livre et thématique |

**Copie hors du Mac** (Réglages › Sauvegarde) : chaque jour, Alexandrie copie ses fichiers de données, les livres
importés ou téléchargés (`Imports/`) et les couvertures dans `Sauvegarde Alexandrie`, à l'intérieur du dossier choisi :
iCloud Drive (proposé s'il est activé) ou un disque externe. Les 30 derniers jours sont gardés ; un disque débranché est
signalé et la copie reprend à son retour. « Restaurer… » relance l'app sur une copie datée : l'état d'avant est mis de
côté dans `Sauvegardes/`, les livres absents reviennent, aucun n'est effacé. Les caches (conversions, texte indexé) et
vos propres dossiers de livres ne sont pas copiés.

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

## Confidentialité

Alexandrie est gratuite, sans compte, sans mesure d'audience ni publicité. Tout reste sur le Mac, dans `~/Library/Application Support/Alexandrie/`, sauf deux connexions, que l'on peut couper dans Réglages > Général, et les catalogues en ligne :

- **Vérification en ligne des livres**, seulement après accord (accueil ou Réglages) : l'ISBN, ou à défaut le titre et l'auteur, est envoyé au catalogue de la BnF puis à Open Library.
- **Recherche de mises à jour** : l'app demande à GitHub la dernière version publiée de ce dépôt.
- **Catalogues en ligne (OPDS)** : rien ne part tant qu'un catalogue n'est pas ouvert dans la barre latérale ; ensuite, le catalogue reçoit les pages parcourues, les mots cherchés et les livres téléchargés. Un catalogue retiré (« Gérer les catalogues… ») n'est plus jamais contacté.

L'envoi à Zotero reste sur le Mac : Alexandrie écrit dans Zotero par son API locale (`127.0.0.1`), seulement quand on clique sur « Envoyer à Zotero » ; Zotero synchronise ensuite les notes si on utilise son compte en ligne. L'autorisation donnée par Zotero est gardée dans le Trousseau.

La copie hors du Mac ne passe par aucun serveur d'Alexandrie : elle écrit dans le dossier choisi ; dans iCloud Drive, c'est le compte iCloud de l'utilisateur qui la synchronise.

Les rapports de plantage restent sur le Mac ; ils ne partent que si l'utilisateur choisit de les envoyer. Le détail est dans `docs/AUDIT-PRODUCTION.md`, § 5.

## Licence

Alexandrie est un logiciel libre, distribué sous [licence MIT](LICENSE). Les skills BAMA de `.claude/skills/` sont aussi sous licence MIT (voir `.claude/skills/BAMA-COMMIT`).
