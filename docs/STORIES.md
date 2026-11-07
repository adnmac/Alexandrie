# Histoires d'Alexandrie

Ce que fait une personne avec l'app, une action par histoire. Alexandrie existait avant ce fichier :
les jalons M1 à M4 décrivent ce qui marche déjà (`done`) et la preuve qui le couvre ; M5 et M6 ont
suivi, M7 est la suite (`todo`). Pas de brief ni d'app de référence : `Screens:` nomme les pages de `scripts/snap.sh`.

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
- [self] Le glisser exporte l'adresse d'une copie identique du fichier (la source reste en place) et la liste des livres, lue seulement par l'app.
- Fix: `FileRepresentation` refusée par le Finder, voir `docs/FIXLOG.md`.
UX:
- Flow: glisser une carte de la grille vers le Finder ou le bureau -> une copie du fichier principal y apparaît ; glisser vers une liseuse de la barre latérale -> le livre (ou la sélection) rejoint son étagère, ⌘Z l'en retire
- Surface: glisser-déposer, sans dialogue (le Finder montre le résultat)
- States: plusieurs livres sélectionnés : le Finder reçoit le fichier de la carte saisie (une copie par glisser), la liseuse reçoit toute la sélection ; livre dans la Corbeille : glisser vers le Finder reste possible
- Words: aucun nouveau texte
- Access: même résultat au clavier par Livre > Afficher dans le Finder (⇧⌘R) ; le fichier source n'est jamais déplacé, seulement copié
Status: done

### S-051 Partager un livre
Le menu du livre propose Partager (AirDrop, Mail…) avec le fichier du livre.
Acceptance:
- [manual] Partager > AirDrop envoie le fichier source, intact.
- [self] Livre > Partager reçoit les fichiers de la sélection, grisé sans sélection.
UX:
- Flow: menu du livre > Partager > AirDrop, Mail, Messages… -> feuille système du service choisi -> Échap l'annule
- Surface: sous-menu Partager du menu du livre (`ShareLink`, liste du système), aussi dans le menu Livre
- States: plusieurs livres sélectionnés : tous leurs fichiers principaux sont partagés ; rien de sélectionné : Livre > Partager grisé
- Words: « Partager » (nom d'Apple) ; services nommés par le système
- Access: VoiceOver lit « Partager, sous-menu »
Status: done

### S-052 Être prévenu quand la file d'attente est partie
Quand la Kindle est branchée et que la file part, une notification dit combien de livres sont arrivés.
Depends: S-011
Acceptance:
- [unit] Le texte de la notification suit le nombre (1 livre, n livres, échecs) : `SendSummaryTests`.
- [manual] La permission est demandée au premier envoi en attente, pas au lancement.
UX:
- Flow: Kindle branchée -> la file d'attente part -> notification « 3 livres envoyés sur « Kindle de Léa » » ; un clic sur la notification ramène Alexandrie au premier plan
- Surface: notification du système (information sans action requise, l'app peut être en arrière-plan)
- States: permission demandée au premier envoi en attente, jamais au lancement ; refusée : rien ne s'affiche, l'envoi marche quand même ; échecs : « 2 livres envoyés, 1 échec » ; un seul livre : son titre
- Words: titre « Livres envoyés sur la Kindle » ; corps « 3 livres envoyés sur « Kindle de Léa » » / « « Le Port des brumes » envoyé sur « Kindle de Léa » » / « 2 livres envoyés, 1 échec »
- Access: le texte se suffit sans icône ni couleur
Status: done

### S-053 Envoyer un livre depuis Raccourcis
Une action Raccourcis « Envoyer à la Kindle » prend un livre de la bibliothèque par son titre.
Depends: S-040
Acceptance:
- [manual] L'action apparaît dans Raccourcis et met le livre en attente sans Kindle.
- [self] `SendToKindle.run` met le livre en attente sans Kindle et répond « En attente de la Kindle ».
- Fix: action visible mais muette sans team ID, voir `docs/FIXLOG.md`.
UX:
- Flow: Raccourcis > action « Envoyer à la Kindle » d'Alexandrie -> paramètre Livre (choisi dans la liste ou par titre) -> le livre part, ou passe en attente sans Kindle -> l'action rend « Envoyé » ou « En attente »
- Surface: action App Intents, sans ouvrir de fenêtre
- States: titre introuvable : l'action échoue avec « Aucun livre « … » dans la bibliothèque » ; livre protégé ou format non pris en charge : « « … » ne peut pas être envoyé sur la Kindle »
- Words: action « Envoyer à la Kindle », paramètre « Livre » ; résumé « Envoyer ${Livre} à la Kindle »
- Access: utilisable par Siri et Spotlight avec les mêmes mots
Note: essai du 2026-11-06 sous macOS 27.2 : l'action apparaît, propose les livres et répond « En attente de la Kindle ». Sous macOS 27.0.1, les métadonnées produites par Xcode 27.2 étaient ignorées.
Status: done

## M7 Lire et étendre

Plusieurs dossiers de livres dans une seule bibliothèque, des PDF lisibles sur la Kindle, et une fenêtre
de lecture dans l'app avec ses propres surlignages. Les fichiers des dossiers de livres restent lus, jamais modifiés :
rognage, reflow et surlignages vivent dans les données de l'app.
Données d'exemple (`SeedData.swift`) : un second dossier de livres, un PDF textuel, un PDF scanné, et des
surlignages faits dans l'app, pour que les captures montrent chaque histoire.

### S-060 Ajouter un dossier de livres
Dans Réglages > Bibliothèque, j'ajoute un deuxième dossier (disque externe, kDrive…) ; ses livres rejoignent « Tous les livres ».
Screens: reglages-library, tous
Acceptance:
- [unit] L'ancien signet unique devient le premier élément de la liste des dossiers, sans réindexer.
- [self] Après ajout d'un second dossier, ses livres sont indexés, et la liste des dossiers survit au redémarrage du magasin.
- [self] Un même fichier présent dans deux dossiers est rassemblé comme doublon (S-021), pas compté deux fois.
- [snap] Réglages > Bibliothèque liste les deux dossiers avec leur nombre de livres.
Status: done

### S-061 Parcourir un seul dossier de livres
Avec deux dossiers ou plus, la barre latérale montre une section « Dossiers » ; un clic n'affiche que les livres de ce dossier.
Screens: dossier-exemple
Depends: S-060
Acceptance:
- [snap] La section « Dossiers » apparaît avec deux dossiers, absente avec un seul.
- [self] Le filtre d'un dossier ne rend que ses livres ; recherche et tri s'y appliquent.
Status: done

### S-062 Retrouver un dossier sur un disque débranché
Quand le disque d'un dossier est débranché, ses livres restent dans la bibliothèque, marqués indisponibles, puis reviennent seuls au rebranchement.
Screens: dossier-exemple
Depends: S-060
Acceptance:
- [self] Un dossier introuvable ne retire aucun livre de l'index ; ses livres sont marqués indisponibles et ne peuvent être ni envoyés ni lus.
- [snap] Le dossier indisponible est grisé dans la barre latérale, avec une bulle qui dit pourquoi.
- [manual] Rebrancher le disque rend les livres disponibles sans relancer l'app.
Status: done

### S-063 Retirer un dossier de livres
Dans Réglages > Bibliothèque, je retire un dossier : ses livres quittent la bibliothèque, ses fichiers restent sur le disque.
Depends: S-060
Acceptance:
- [self] Retirer un dossier enlève ses livres de l'index, des étagères et de l'attente d'envoi ; aucun fichier n'est touché.
- [self] Le dernier dossier ne peut pas être retiré (bouton grisé).
- [manual] Une confirmation dit combien de livres quittent la bibliothèque.
Status: done

### S-064 Envoyer un PDF aux marges rognées
Dans la fiche d'un PDF, je choisis « Sur la Kindle : marges rognées » ; la Kindle reçoit une copie sans marges blanches, le texte paraît plus grand.
Screens: tous
Acceptance:
- [unit] Le rognage trouve un même cadre pour toutes les pages à partir du contenu visible, sans couper de texte, sur un PDF de test.
- [self] La copie envoyée a des pages plus petites que l'original ; l'original n'est pas modifié.
- [snap] La fiche d'un PDF montre le choix « Tel quel / Marges rognées ».
- [manual] Sur la Kindle, le PDF rogné remplit l'écran.
Status: done

### S-065 Envoyer un PDF en texte redimensionnable
Pour un PDF surtout textuel, le choix « Texte redimensionnable » envoie un livre Kindle dont je règle la taille du texte.
Screens: tous
Depends: S-064
Acceptance:
- [unit] L'extraction recolle les lignes en paragraphes, retire les coupures de mots, les numéros de page et les en-têtes répétés, sur un PDF de test.
- [unit] Le texte extrait devient un EPUB valide puis un AZW3 par `EPUBToAZW3`.
- [self] Un PDF scanné (sans texte) grise ce choix avec « Ce PDF ne contient pas de texte ».
- [manual] Sur la Kindle, la taille du texte se règle et les chapitres suivent la table du PDF quand elle existe.
Status: done

### S-066 Lire un livre dans l'app
Je double-clique sur un livre, ou Livre > Lire : une fenêtre de lecture s'ouvre, pour EPUB, MOBI, AZW3 et PDF.
Screens: lecture-epub, lecture-pdf
Acceptance:
- [self] Chaque format d'exemple s'ouvre dans la fenêtre de lecture ; MOBI et AZW3 passent par `MobiToEPUB`, sans écrire dans le dossier de livres.
- [self] Un livre protégé par DRM grise Livre > Lire.
- [snap] La fenêtre de lecture d'un EPUB et celle d'un PDF, en clair et en sombre.
Status: done

### S-067 Naviguer dans un livre
Dans la fenêtre de lecture, je tourne les pages au clavier et je saute à un chapitre par la table des matières.
Screens: lecture-epub
Depends: S-066
Acceptance:
- [snap] La table des matières s'affiche dans une colonne repliable, chapitre courant marqué.
- [manual] Flèches et Espace tournent les pages ; un clic sur un chapitre y va.
Status: done

### S-068 Reprendre sa lecture où je l'ai laissée
En rouvrant un livre, la fenêtre de lecture revient à la page où je m'étais arrêté, même après avoir quitté l'app.
Depends: S-066
Acceptance:
- [self] La position de lecture est enregistrée par livre dans les données de l'app et relue à l'ouverture.
- [snap] La fiche montre la progression (« 42 % lu ») d'un livre commencé.
Status: done

### S-069 Régler le texte de la fenêtre de lecture
Je change la taille du texte (⌘+ / ⌘−) et le fond (clair, sépia, sombre) ; le réglage vaut pour tous les livres.
Depends: S-066
Acceptance:
- [snap] La fenêtre de lecture en sépia, avec un texte agrandi.
- [self] Taille et fond survivent au redémarrage.
- [manual] Un PDF garde sa mise en page : seul le zoom change.
Status: done

### S-070 Surligner un passage
Dans la fenêtre de lecture, je sélectionne un passage et je le surligne ; il apparaît dans « Notes et surlignages » à côté de ceux de la Kindle.
Screens: lecture-epub, notes
Depends: S-066, S-024
Acceptance:
- [self] Un surlignage d'EPUB et un de PDF sont enregistrés avec leur position, sans modifier le fichier du livre.
- [snap] Le passage surligné dans la fenêtre de lecture ; dans « Notes et surlignages », il porte la marque « Alexandrie ».
- [unit] Les surlignages de l'app et ceux de la Kindle se trient ensemble par position dans le livre.
Status: done

### S-071 Annoter un surlignage
J'ajoute une note à un surlignage, dans la fenêtre de lecture ou dans « Notes et surlignages ».
Depends: S-070
Acceptance:
- [self] La note est enregistrée avec le surlignage et modifiable des deux endroits.
- [snap] Le surlignage annoté montre son repère de note dans la fenêtre de lecture.
Status: done

### S-072 Ouvrir un surlignage dans la fenêtre de lecture
Dans « Notes et surlignages », un surlignage fait dans l'app ouvre la fenêtre de lecture à son passage.
Depends: S-070
Acceptance:
- [self] Ouvrir un surlignage de l'app positionne la fenêtre de lecture sur son passage.
- [manual] Les surlignages de la Kindle, sans position fiable, n'offrent pas cette action.
Status: doing

### S-073 Choisir la couleur d'un surlignage
Je surligne en jaune, vert, bleu, rose ou violet, et je change la couleur d'un surlignage existant ; le menu de PDFKit et de WebKit, qui n'enregistrait rien, disparaît de la fenêtre de lecture.
Depends: S-071
Acceptance:
- [self] La couleur est enregistrée avec le surlignage, redessinée dans l'EPUB et le PDF, et modifiable depuis la fenêtre de lecture ou « Notes et surlignages ».
- [snap] Des surlignages de couleurs différentes dans la fenêtre de lecture et dans « Notes et surlignages ».
- [manual] Le clic droit sur une page ne propose plus les couleurs, le zoom ni les modes d'affichage de macOS ; sur un passage surligné, il propose sa note, sa couleur et sa suppression.
Status: done

### S-074 Exporter les notes par couleur
Dans « Notes et surlignages », je choisis les couleurs à garder (toutes, une ou plusieurs) ; la liste, la copie et l'export Markdown ne contiennent que ces surlignages.
Depends: S-073
Acceptance:
- [unit] Le filtre garde les surlignages des couleurs choisies (jaune pour ceux de la Kindle) ; « Toutes » ne filtre rien ; l'export Markdown nomme la couleur.
- [snap] La page Notes montre le choix des couleurs et le compte filtré.
- [manual] Exporter avec deux couleurs choisies écrit un Markdown sans les autres.
Status: done

### S-075 Définir les thèmes d'une recherche
Pour un mémoire, je crée une recherche (« Mémoire de master ») et je nomme ses couleurs (jaune = anthropologie, rose = sociologie) ; j'ajoute des couleurs à moi. J'ai plusieurs recherches en cours, chacune avec sa légende.
Depends: S-073
Acceptance:
- [unit] Une recherche garde son nom et ses thèmes (nom et couleur) ; une nouvelle recherche part des cinq couleurs ; une couleur ajoutée reçoit sa teinte.
- [self] Les recherches sont relues au redémarrage ; supprimer une recherche ou un thème rend aux surlignages concernés la couleur de base la plus proche.
- [snap] La feuille « Recherches » : la liste des recherches, la légende de celle choisie, une couleur ajoutée.
Status: doing

### S-076 Surligner dans une recherche
Dans la fenêtre de lecture, je choisis la recherche en cours pour ce livre ; les couleurs proposées portent les noms de ses thèmes, et chaque surlignage garde sa recherche, même si le livre sert à une autre ensuite.
Depends: S-075
Acceptance:
- [self] Un surlignage fait dans une recherche est enregistré avec sa recherche et son thème, et dessiné de la couleur du thème ; la recherche choisie est retenue par livre.
- [snap] La fenêtre de lecture montre la recherche choisie dans sa barre d'outils.
- [manual] Le clic droit et la bulle de note proposent les thèmes par leur nom, à côté de leur couleur.
Status: doing

### S-077 Notes et export par thème
Dans « Notes et surlignages », chaque surlignage montre son thème ; je filtre et j'exporte par thème.
Depends: S-076
Acceptance:
- [unit] Le filtre garde les thèmes choisis ; l'export Markdown nomme le thème de chaque surlignage.
- [snap] La page Notes montre le nom du thème à côté de la couleur, et le menu de filtre porte les noms des thèmes.
Status: doing

### S-078 Exporter toute une recherche par thème
Pour rédiger, j'exporte une recherche entière : tous ses livres, classés par thème, chaque passage avec sa source et sa note.
Depends: S-077
Acceptance:
- [unit] Le Markdown suit l'ordre de la légende, saute les thèmes vides, range les passages par livre puis en ordre de lecture, et donne pour chacun le livre, l'auteur, l'emplacement et la note.
- [snap] La feuille « Recherches » propose « Exporter la recherche… » avec le nombre de passages.
- [manual] Le fichier enregistré s'ouvre dans un éditeur Markdown, un titre par thème.
Status: doing

### S-079 Séparer couleurs et thématiques
Une thématique (« Rénovation des voiries ») classe des surlignages ; ses couleurs nomment des catégories (jaune = construction, bleu = analyse des coûts). Un passage a une couleur et peut appartenir à plusieurs thématiques : deux sélecteurs, « Couleurs » et « Thématiques », dans la lecture comme dans « Notes et surlignages ».
Depends: S-078
Acceptance:
- [unit] Un surlignage garde sa couleur et ses thématiques séparément ; le nom de sa couleur se lit dans la légende de chaque thématique ; filtrer par couleurs et par thématiques se combinent ; l'export d'une thématique classe ses passages par couleur nommée.
- [self] Les surlignages des recherches d'avant sont repris : leur thématique et leur couleur sont gardées. Supprimer une thématique la retire des surlignages sans toucher à leur couleur.
- [snap] La page Notes montre les menus « Couleurs » et « Thématiques » ; la fenêtre de lecture, la thématique choisie ; la feuille « Thématiques », une légende nommée.
- [manual] Le clic droit et la bulle de note proposent « Couleur » (catégories nommées) et « Thématiques » (à cocher).
Status: doing

### S-080 Toutes les notes d'une thématique
Dans la barre latérale, chaque thématique ouvre toutes ses notes et surlignages, de tous les livres de la bibliothèque ; je les trie par couleur (catégorie), par livre ou par date, je filtre par couleur et j'exporte dans l'ordre choisi.
Depends: S-079
Acceptance:
- [unit] Les passages d'une thématique se rangent par couleur nommée (ordre de la légende), par livre (alphabétique, puis ordre de lecture) ou par date d'ajout (récents d'abord) ; l'export suit le même ordre.
- [snap] La section « Thématiques » de la barre latérale et la page d'une thématique, triée par couleur.
- [manual] Un clic sur le titre du livre d'un passage montre sa fiche.
Status: doing

### S-081 Indexer le texte des livres
Alexandrie lit une fois le texte de chaque livre (EPUB, MOBI, AZW3, PDF) et le garde dans un index, en arrière-plan, pour chercher dans le contenu sans attendre.
Depends: S-066
Acceptance:
- [unit] Le texte d'un EPUB est extrait chapitre par chapitre, sans balises ni styles, entités décodées ; l'index trouve un livre par un mot de son texte, sans tenir compte des accents ni des majuscules, et par le début d'un mot.
- [self] Les livres de la bibliothèque sont indexés en arrière-plan, puis un livre ajouté ; un livre retiré quitte l'index ; les livres protégés (DRM) sont ignorés.
Status: done

### S-082 Chercher dans le contenu des livres
Dans le champ de recherche, je choisis « Titres, auteurs… » ou « Contenu des livres » ; le contenu donne une liste des livres avec le nombre de passages et des extraits, le mot trouvé en gras.
Depends: S-081
Acceptance:
- [unit] Les extraits entourent le mot trouvé, sans tenir compte des accents ni des majuscules, et comptent ses passages.
- [snap] La liste des résultats dans le contenu, avec extraits, et la progression de l'indexation.
Status: done

### S-083 Ouvrir un passage trouvé
Un clic sur un extrait ouvre la fenêtre de lecture au passage, mot sélectionné.
Depends: S-082
Acceptance:
- [self] Ouvrir un extrait d'EPUB et de PDF montre la page du passage, le mot sélectionné.
- [manual] Une fenêtre de lecture déjà ouverte pour ce livre saute au passage.
Status: done

### S-084 Chercher l'écriture exacte
« Odyssée » (l'œuvre) et « odyssée » (un long voyage) ne disent pas la même chose : une option « Écriture exacte » ne garde que les passages écrits exactement comme la recherche, majuscules et accents compris.
Depends: S-082
Acceptance:
- [unit] En écriture exacte, « Odyssée » ne trouve ni « odyssée » ni « Odyssee » ; sans l'option, il les trouve tous.
- [self] Un livre dont le texte n'a le mot qu'avec une autre écriture n'est plus dans les résultats.
- [snap] La barre « Chercher dans » montre l'option, cochée, et les résultats exacts.
Status: done

### S-085 Parcourir les renvois d'une recherche en lisant
Ouverte depuis la recherche dans le contenu, la fenêtre de lecture montre dans sa colonne de gauche la liste des passages où le mot apparaît, et au-dessus de la page une barre pour aller au renvoi précédent ou suivant.
Depends: S-083
Acceptance:
- [self] Tous les passages du livre sont listés, dans l'ordre, avec leur chapitre ou leur page ; aller au suivant ouvre sa page, mot sélectionné.
- [snap] La fenêtre de lecture avec la liste des renvois à gauche et la barre « 2 sur 5 ».
- [manual] ⌘G et ⇧⌘G passent au renvoi suivant et précédent ; fermer la barre rend la table des matières.
Status: done

## Later

- Envoyer les surlignages faits dans l'app vers la Kindle.

## Dropped

- Comptes, synchronisation en ligne : la bibliothèque reste sur le Mac.
- Envoi par e-mail « Send to Kindle » : Alexandrie charge par câble, c'est sa raison d'être.
- Suppression des DRM et format KFX : hors du droit et de la portée de l'app.
- Boutique, recommandations, statistiques de lecture : servent un vendeur, pas la bibliothèque.
- Partage de bibliothèque entre personnes : une bibliothèque par Mac.
