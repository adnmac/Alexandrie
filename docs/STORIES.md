# Histoires d'Alexandrie

Ce que fait une personne avec l'app, une action par histoire. Alexandrie existait avant ce fichier :
les jalons M1 à M4 décrivent ce qui marche déjà (`done`) et la preuve qui le couvre ; M5 et M6 sont
la suite (`todo`). Pas de brief ni d'app de référence : `Screens:` nomme les pages de `scripts/snap.sh`.

Marques des critères : `[unit]` test de `scripts/test.sh`, `[self]` étape de `scripts/selftest.sh`,
`[snap]` capture de `scripts/snap.sh`, `[manual]` à essayer à la main (Kindle réelle, Finder…).
Noms de l'interface : `docs/GLOSSARY.md`.

## M1 Bibliothèque

On ouvre son dossier de livres et on retrouve chaque livre avec ses bonnes informations.

### S-001 Choisir son dossier de livres
Au premier lancement, je choisis le dossier où sont mes livres ; Alexandrie l'indexe sans le modifier.
Screens: tous
Acceptance:
- [self] « indexation du dossier » : les livres du dossier apparaissent avec leur titre.
- [self] « fichiers source intacts » : aucun fichier du dossier n'est modifié.
- [unit] `ScannerTests` : EPUB, MOBI, AZW3, AZW et PDF sont reconnus.
- [manual] Le dossier est retrouvé au lancement suivant (signet).
Status: done

### S-002 Voir la couverture et les informations d'un livre
Je sélectionne un livre et sa fiche montre couverture, titre, auteurs, éditeur, série, résumé.
Screens: tous, serie, auteur
Depends: S-001
Acceptance:
- [self] « couvertures extraites ».
- [snap] La fiche montre la couverture et la section Informations, en clair et en sombre.
- [unit] `EPUBTests`, `RealBookTests` : métadonnées lues dans l'OPF et l'EXTH.
Status: done

### S-003 Corriger les informations d'un livre
Je corrige titre, auteurs, série, genre, date, ISBN, langue ou résumé dans la fiche.
Screens: tous
Depends: S-002
Acceptance:
- [self] « retouche enregistrée dans l'index ».
- [self] « fichiers source intacts » : la retouche ne touche pas le fichier.
- [unit] `MetadataEditTests`.
Status: done

### S-004 Chercher un livre
Je tape un titre, un auteur, une série, un genre ou un mot de mes notes dans le champ de recherche.
Screens: tous
Acceptance:
- [manual] La liste se réduit à chaque frappe ; un livre dont une note contient le mot apparaît.
Status: done

### S-005 Trier et passer de la grille à la liste
Je trie par titre, auteur ou date d'ajout, et je choisis grille ou liste dans la barre d'outils.
Screens: tous
Acceptance:
- [snap] La grille montre couverture, format, titre et auteur ; `scripts/snap.sh -gridMode NO` montre la liste.
Status: done

### S-006 Importer des livres
Je glisse des fichiers sur la fenêtre, ou j'utilise Fichier > Importer des livres… (⌘O).
Screens: tous
Acceptance:
- [self] « import copié dans Imports ».
- [manual] Un contour pointillé entoure la fenêtre pendant le glisser.
Status: done

### S-007 Retrouver la bibliothèque après un redémarrage
Je quitte et relance l'app : livres, corrections, étagères et corbeille sont là.
Acceptance:
- [self] « index relu après fermeture ».
- [unit] `LibraryIndexTests` : un index illisible est mis de côté, jamais écrasé.
- [unit] `IndexBackupsTests` : une copie datée par jour, les 10 dernières gardées.
Status: done

## M2 Kindle

On branche sa Kindle et on y met ses livres, quel que soit leur format.

### S-010 Envoyer un livre sur la Kindle branchée
Je sélectionne un livre et clique « Envoyer à la Kindle » ; un EPUB est converti en AZW3.
Screens: tous, kindle
Depends: S-002
Acceptance:
- [self] « conversion EPUB → AZW3 avec la retouche » : le titre corrigé arrive dans l'AZW3.
- [unit] `RealBookTests` (avec `ALEXANDRIE_FIXTURES`) : conversions sur de vrais livres.
- [manual] Le livre apparaît sur une Kindle USB et sur une Kindle MTP.
Status: done

### S-011 Mettre un livre en attente quand la Kindle n'est pas branchée
Sans Kindle, le bouton devient « Envoyer à la connexion » ; le livre part dès qu'elle est branchée.
Screens: tous, en-attente
Depends: S-010
Acceptance:
- [snap] « En attente d'envoi » liste le livre, avec la pastille d'attente sur sa couverture.
- [unit] `KindleQueueTests`, `ReaderQueueTests`.
- [manual] Brancher la Kindle envoie la file.
Status: done

### S-012 Voir les livres de la Kindle
Je clique sur la Kindle dans la barre latérale et je vois ses livres, avec leur couverture.
Screens: kindle
Acceptance:
- [snap] Sans Kindle, la page explique comment la brancher.
- [unit] `KindleCatalogTests`.
- [manual] Avec une Kindle, ses livres et leur format s'affichent.
Status: done

### S-013 Nommer une nouvelle liseuse
La première fois qu'une Kindle est branchée, je lui donne un nom ; elle est reconnue ensuite.
Screens: feuille-liseuse
Acceptance:
- [snap] La feuille de 480 pt s'ouvre sans focus, champ prérempli avec le nom de l'appareil.
- [unit] `KindleIdentifierTests`, `ReaderListTests`.
Status: done

### S-014 Tenir une étagère par liseuse
J'ajoute des livres à l'étagère d'une liseuse (menu du livre ou glisser sur la liseuse).
Screens: tous
Depends: S-013
Acceptance:
- [unit] `ShelfTests`, `ShelfSyncTests`.
- [manual] Les livres de l'étagère absents de la Kindle branchée sont proposés à l'envoi.
Status: done

### S-015 Ranger la Kindle selon l'étagère
Les livres présents sur la Kindle mais retirés de l'étagère sont proposés : les remettre, ou les retirer de la Kindle.
Screens: kindle
Depends: S-014
Acceptance:
- [unit] `ShelfSyncTests`.
- [manual] « Retirer de la Kindle… » demande confirmation et n'efface rien dans la bibliothèque.
Status: done

### S-016 Corriger un livre directement sur la Kindle
Je réécris titre, auteurs, date… d'un MOBI/AZW3 sans DRM déjà sur la Kindle.
Screens: feuille-kindle
Acceptance:
- [snap] La feuille de 480 pt montre les champs et « Enregistrer sur la Kindle ».
- [unit] `MetadataEditTests` : seules les métadonnées du fichier changent.
Status: done

### S-017 Éjecter la Kindle
J'éjecte la Kindle depuis la barre latérale ou Kindle > Éjecter la Kindle (⌘E).
Acceptance:
- [manual] La Kindle se démonte et la barre latérale indique « Éjectée ».
Status: done

### S-018 Exporter un livre Kindle en EPUB
Dans le menu d'un MOBI ou AZW3, « Exporter en EPUB… » écrit un EPUB à l'endroit choisi.
Acceptance:
- [unit] `RealBookTests` : KF7, KF8 et fichiers hybrides.
Status: done

## M3 Organiser

On range une grande bibliothèque et on retrouve vite une partie.

### S-020 Parcourir par format, série, genre et auteur
Je déplie Formats, Séries, Genres ou Auteurs dans la barre latérale et je choisis une entrée.
Screens: format-azw3, serie, genre, auteur
Acceptance:
- [snap] La page montre les livres de l'entrée et la fenêtre porte son nom.
- [unit] `SeriesTests`, `GenreNamesTests`, `AuthorNamesTests` : graphies différentes réunies.
Status: done

### S-021 Rassembler les doublons
Un même livre en plusieurs exemplaires n'apparaît qu'une fois ; Présentation > Rassembler les doublons (⌥⌘D).
Screens: tous
Acceptance:
- [unit] `DuplicateFilesTests`, `BookGroupsTests`, `BookIdentityTests`.
Status: done

### S-022 Mettre un livre à la corbeille et le restaurer
« Mettre à la corbeille » le retire de la bibliothèque ; je le restaure depuis la Corbeille.
Screens: corbeille
Acceptance:
- [self] « mise à la corbeille », « restauration depuis la corbeille ».
- [unit] `LibraryTrashTests`.
Status: done

### S-023 Annuler une action
⌘Z annule une correction, une mise à la corbeille ou un changement d'étagère.
Acceptance:
- [manual] Édition > Annuler nomme l'action et la défait.
Status: done

### S-024 Lire et corriger ses notes et surlignages
Les notes de la Kindle sont importées ; dans « Notes et surlignages », je les lis par livre et je les corrige.
Screens: notes
Acceptance:
- [snap] La page montre la liste des livres annotés et les notes du livre choisi.
- [unit] `ClippingsTests`, `ClippingEditingTests`.
Status: done

## M4 Vérifier

Les informations des livres sont justes sans tout retaper.

### S-030 Comparer un livre au catalogue
« Vérifier en ligne » interroge la BnF puis Open Library ; les différences sont proposées dans la fiche.
Screens: tous
Acceptance:
- [self] « vérification en ligne coupée » : rien ne part en ligne sur les données de test.
- [unit] `CatalogTests`, `CatalogFallbackTests`, `ISBNTests`.
Status: done

### S-031 Revoir les propositions en lot
« À vérifier » réunit les livres avec des propositions ; je les applique ou les ignore en lot.
Screens: a-verifier
Acceptance:
- [unit] `CatalogReviewTests`.
Status: done

### S-032 Trouver les couvertures manquantes
Réglages > Bibliothèque > « Chercher sur Open Library » complète les livres sans couverture.
Screens: reglages-library
Acceptance:
- [unit] `CoverFinderTests`, `CoverCheckTests`.
Status: done

### S-033 Mettre à jour l'app
L'app signale une version plus récente et propose « Installer et relancer ».
Screens: reglages-general
Acceptance:
- [unit] `ReleaseTests`, `UpdateCheckerTests`.
- [manual] La version téléchargée doit porter la même signature.
Status: done

## M5 Clavier et menus

Tout ce qui se fait souvent se fait au clavier, et chaque action est dans la barre des menus.

### S-040 Envoyer la sélection à la Kindle au clavier
Je sélectionne des livres et choisis Kindle > Envoyer à la Kindle (⌘K) ; sans Kindle, ils passent en attente.
Screens: tous, en-attente
Depends: S-010, S-011
Acceptance:
- [self] La commande reçoit la sélection de la fenêtre et met les livres en attente sans Kindle.
- [manual] Le menu nomme l'action selon l'état : « Envoyer à la Kindle » ou « Envoyer à la connexion ».
- [manual] Sans sélection, l'élément de menu est grisé mais visible.
UX:
- Flow: Kindle > Envoyer à la Kindle (⌘K), bouton de la fiche, menu du livre -> la sélection part (ou passe en attente) -> la fiche montre « Envoyé sur la Kindle » ou le livre apparaît dans « En attente d'envoi » ; ⌘Z retire de l'attente
- Surface: commande de menu sur la sélection, sans feuille (aucun choix à demander)
- States: sans sélection, grisé ; envoi en cours, barre dans la fiche ; échec, message sous le bouton avec la cause ; plusieurs livres, « 3 envoyé(s), 1 échec(s) »
- Words: « Envoyer à la Kindle » / « Envoyer à la connexion » (suit l'état, comme le bouton de la fiche) ; bulle « Copier les livres sélectionnés sur la Kindle (⌘K) »
- Access: VoiceOver lit le même intitulé que le menu ; l'état n'est jamais porté par la seule couleur
Status: done

### S-041 Mettre la sélection à la corbeille avec la touche Supprimer
⌘⌫ (ou Supprimer dans la grille) met les livres sélectionnés à la corbeille ; ⌘Z les rend.
Screens: tous, corbeille
Depends: S-022, S-023
Acceptance:
- [self] La commande met les livres sélectionnés à la corbeille puis l'annulation les restaure.
- [manual] Dans la Corbeille, la même touche ne supprime rien définitivement.
UX:
- Flow: ⌘⌫ dans la grille ou la liste, menu Livre, menu du livre -> les livres quittent la page, la sélection passe au suivant -> Édition > Annuler Mettre à la corbeille (⌘Z) les rend
- Surface: commande directe, sans confirmation (l'action se défait)
- States: dans la Corbeille, la commande devient grisée ; « Supprimer définitivement… » garde son menu et sa confirmation
- Words: « Mettre à la corbeille », « Annuler Mettre à la corbeille »
- Access: la sélection suivante est annoncée par VoiceOver ; le focus reste dans la grille
Status: done

### S-042 Prévisualiser un livre avec Espace
J'appuie sur Espace dans la grille ou la liste : Coup d'œil montre le fichier ; Espace le ferme.
Screens: tous
Acceptance:
- [manual] Coup d'œil s'ouvre sur le fichier sélectionné et suit les flèches.
UX:
- Flow: Espace sur un livre sélectionné, menu Livre > Coup d'œil (⌘Y, comme le Finder) -> fenêtre Coup d'œil du fichier principal -> flèches pour le livre voisin, Espace ou Échap pour fermer
- Surface: panneau système Coup d'œil (aperçu à côté du travail)
- States: format sans aperçu (AZW3, MOBI) : Coup d'œil montre l'icône et le nom, rien d'inventé ; plusieurs livres : Coup d'œil les parcourt
- Words: « Coup d'œil » (nom d'Apple), pas de texte propre
- Access: Espace ne déclenche rien quand le champ de recherche a le focus
- [self] Livre > Coup d'œil est active avec une sélection, grisée sans.
Status: done

### S-043 Retrouver la page et la sélection au lancement
Je relance l'app : la page de la barre latérale et le livre sélectionnés sont ceux d'avant.
Screens: tous
Acceptance:
- [manual] Quitter sur « Série » avec un livre sélectionné, relancer : même page, même fiche.
- [snap] La fenêtre principale s'ouvre sans anneau de focus.
UX:
- Flow: quitter (⌘Q) -> relancer -> même page de la barre latérale, même livre sélectionné, même fiche (le défilement repart du haut)
- Surface: aucune (état rendu en silence)
- States: livre disparu depuis (supprimé, dossier changé) : page gardée, sélection vide, fiche « Aucun livre sélectionné » ; page disparue (série vide) : « Tous les livres »
- Words: aucun nouveau texte
- Access: la barre latérale garde le focus à l'ouverture, sans anneau ; les flèches marchent aussitôt
- [self] Chaque page de la barre latérale s'écrit et se relit en texte (gardée dans les réglages de l'app).
- Fix: `@SceneStorage` perdu au ⌘Q, voir `docs/FIXLOG.md`.
Status: done

### S-044 Les menus suivent la sélection
Les commandes du livre (Coup d'œil, Ouvrir, Afficher dans le Finder, Exporter en EPUB, Corbeille) sont dans un menu Livre, actives selon la sélection.
Depends: S-040, S-041
Acceptance:
- [self] Les commandes reçoivent la sélection de la fenêtre au premier plan.
- [manual] Contrôle d'accessibilité : sans sélection, Livre > Afficher dans le Finder est grisé.
UX:
- Flow: menu Livre (entre Présentation et Kindle) -> Coup d'œil (⌘Y), Ouvrir, Afficher dans le Finder (⇧⌘R), Exporter en EPUB…, Mettre à la corbeille (⌘⌫) ; Envoyer à la Kindle (⌘K) reste dans le menu Kindle -> chaque commande agit sur la sélection de la fenêtre au premier plan
- Surface: menu de la barre des menus ; le menu du livre (clic droit) garde les mêmes intitulés
- States: sans sélection, tout est grisé mais visible ; commande qui ne s'applique pas (Exporter en EPUB sur un PDF) grisée
- Words: menu « Livre » ; intitulés identiques au menu du livre et aux boutons de la fiche
- Access: chaque commande a un équivalent clavier ou se trouve par la recherche du menu Aide
- [self] `MenuState` grise tous les éléments sans sélection.
- Fix: menus figés par `@FocusedValue`, voir `docs/FIXLOG.md`.
Status: done

## M6 Système

Alexandrie travaille avec le Finder et le reste du Mac.

### S-050 Glisser un livre vers le Finder
Je glisse un livre de la grille vers le Finder ou le bureau : une copie du fichier y apparaît.
Screens: tous
Depends: S-014
Acceptance:
- [manual] Le Finder reçoit un vrai fichier ; le glisser vers une liseuse marche toujours.
Status: todo

### S-051 Partager un livre
Le menu du livre propose Partager (AirDrop, Mail…) avec le fichier du livre.
Acceptance:
- [manual] Partager > AirDrop envoie le fichier source, intact.
Status: todo

### S-052 Être prévenu quand la file d'attente est partie
Quand la Kindle est branchée et que la file part, une notification dit combien de livres sont arrivés.
Depends: S-011
Acceptance:
- [unit] Le texte de la notification suit le nombre (1 livre, n livres, échecs).
- [manual] La permission est demandée au premier envoi en attente, pas au lancement.
Status: todo

### S-053 Envoyer un livre depuis Raccourcis
Une action Raccourcis « Envoyer à la Kindle » prend un livre de la bibliothèque par son titre.
Depends: S-040
Acceptance:
- [manual] L'action apparaît dans Raccourcis et met le livre en attente sans Kindle.
Status: todo

## Later

- Lire un livre dans l'app.
- Convertir un PDF pour la Kindle (recadrage, reflow).
- Plusieurs bibliothèques (plusieurs dossiers sources).

## Dropped

- Comptes, synchronisation en ligne : la bibliothèque reste sur le Mac.
- Envoi par e-mail « Send to Kindle » : Alexandrie charge par câble, c'est sa raison d'être.
- Suppression des DRM et format KFX : hors du droit et de la portée de l'app.
- Boutique, recommandations, statistiques de lecture : servent un vendeur, pas la bibliothèque.
- Partage de bibliothèque entre personnes : une bibliothèque par Mac.
