# Audit avant mise en vente

Audit du 7 novembre 2026, sur le commit `242eb6d`. Il couvre quatre points : sécurité et robustesse, premier lancement, rapports de plantage, vie privée.

**En bref.** Le code est sain : fichiers des livres jamais modifiés, mises à jour vérifiées par signature, données gardées sur le Mac, aucune mesure d'audience.

Ce qui empêche de vendre aujourd'hui tient surtout à la **distribution** :
- l'app n'est pas signée pour tourner sur un autre Mac ;
- le code source est public ;
- il n'y a ni licence, ni paiement.

Le code a aussi quelques points à corriger : JavaScript des livres, autorisations mal expliquées, envoi des titres de livres en ligne sans accord préalable, aucun rapport de plantage.

Légende : 🔴 bloquant pour vendre · 🟠 à faire avant la sortie · 🟢 souhaitable.

## 1. Distribution et vente

| | Constat | Ce qu'il faut |
| --- | --- | --- |
| 🔴 | L'app est signée avec un certificat **Apple Development** (`scripts/bundle.sh`). Sur le Mac d'un client, Gatekeeper la bloque : « impossible de vérifier le développeur ». | Programme développeur Apple (99 €/an), certificat **Developer ID Application**, signature avec le *hardened runtime* (`codesign --options runtime`), **notarisation** (`xcrun notarytool submit … --wait`) puis `xcrun stapler staple`. À ajouter à `scripts/release.sh`. |
| 🔴 | Le dépôt `adnmac/Foluna` est **public, sans licence** : n'importe qui peut télécharger et compiler l'app. | Rendre le dépôt privé, ou choisir une licence en connaissance de cause (open source payant, comme certaines apps « payez pour le binaire »). |
| 🔴 | La recherche de mises à jour compare le commit compilé à la branche `main` de ce dépôt, par l'API GitHub sans compte (`UpdateChecker.swift`). Un dépôt privé la casse, et un client verrait chaque commit de développement comme une mise à jour. | Un canal de versions publiques seulement : un dépôt public qui ne contient que les versions, ou un flux à la Sparkle (appcast signé). Garder la vérification de signature déjà en place (`SignatureCheck`). |
| 🔴 | Aucune licence d'utilisation ni aucun paiement. | Choisir le canal : vente directe (Paddle, Lemon Squeezy, Gumroad : paiement, TVA européenne, clés de licence) ou Mac App Store (voir plus bas). Ajouter la vérification de licence dans l'app. |
| 🟠 | Pas de conditions de vente, de mentions légales ni de politique de confidentialité. | Obligatoires pour vendre en Belgique et dans l'UE, et pour l'App Store : CGV, droit de rétractation pour un contenu numérique, politique de confidentialité (voir § 5). |
| 🟢 | Le User-Agent varie : « Foluna (macOS) » et « Foluna/0.1 (macOS) ». | Un seul, avec la vraie version : `Foluna/<version> (macOS)`. |

**Mac App Store ou vente directe ?** L'App Store exige le bac à sable (*sandbox*). Ici, cela demanderait :
- de rouvrir les dossiers de livres par des signets à portée de sécurité ;
- de faire choisir le volume de la Kindle par l'utilisateur, ou de vérifier qu'un accès aux volumes amovibles est accepté ;
- de retirer la mise à jour intégrée, que l'App Store interdit ;
- de faire passer la revue à un nom et à un usage qui citent « Kindle ».

C'est faisable, mais c'est un chantier. La vente directe, signée et notarisée, est plus rapide et garde toutes les fonctions.

## 2. Sécurité et robustesse

| | Constat | Ce qu'il faut |
| --- | --- | --- |
| 🟠 | **Le JavaScript des livres s'exécute** dans la fenêtre de lecture (`WKWebView`, aucun réglage contraire). Un EPUB piégé pourrait lancer son propre code : envoyer des requêtes sur Internet, ou parler au relais `alx` de l'app (sélection, ouverture de note). Il ne peut pas lire d'autres fichiers que ceux du livre (`allowingReadAccessTo` limité au dossier extrait). | Couper le JavaScript des pages (`defaultWebpagePreferences.allowsContentJavaScript = false`). Faire tourner les scripts de Foluna dans un monde à part (`WKContentWorld.defaultClient`) : ils continuent de marcher, ceux du livre non. |
| 🟠 | Plusieurs enregistrements échouent **en silence** (`try?`) : thématiques (`ResearchStore.save`), positions de lecture, état de l'index de recherche. Disque plein ou dossier verrouillé : l'utilisateur perd ses changements sans le savoir. | Signaler l'échec, comme le font déjà la bibliothèque et les notes (`lastError`). Les thématiques d'abord : c'est le travail d'un étudiant. |
| 🟠 | Les sauvegardes quotidiennes (`IndexBackups`) couvrent la bibliothèque et les notes, **pas les thématiques** (`researches.json`) ni les positions de lecture. | Ajouter `researches.json` aux sauvegardes datées. |
| ✅ | Fichiers abîmés ou fabriqués : 80 variantes tronquées ou corrompues de MOBI, AZW3 et EPUB échouent proprement, sans plantage. | Tests gardés dans `Tests/FolunaCoreTests/RobustnessTests.swift`. |
| ✅ | Extraction des EPUB : un chemin qui sortirait du dossier (`../`) est ignoré (`ReaderBook.extract`). | — |
| ✅ | Mise à jour intégrée : téléchargée en HTTPS, refusée si elle n'est pas signée par le même certificat (`SignatureCheck.verifySameSigner`). | À garder avec le nouveau canal. |
| ✅ | Aucun chemin codé en dur dans le code de l'app : tout passe par `AppDirectories` et les dossiers choisis. Les chemins `/tmp` ne sont que dans les modes test et capture. | — |
| ✅ | Aucun secret, jeton ni clé dans le code. Les seuls `try!` portent sur des expressions régulières fixes, couvertes par les tests. | — |
| ✅ | Le dossier de livres n'est jamais modifié, comme l'annonce l'accueil : la bibliothèque, les notes, les conversions et le texte indexé vivent dans `~/Library/Application Support/Alexandrie/`. Seule la Kindle est écrite, quand on lui envoie un livre. | — |

## 3. Premier lancement

| | Constat | Ce qu'il faut |
| --- | --- | --- |
| 🟠 | **Vérification en ligne activée par défaut.** Au premier choix de dossier, chaque nouveau livre est envoyé à la BnF puis à Open Library (ISBN, ou titre et auteur). L'utilisateur ne l'a pas accepté avant : l'explication n'est que dans les Réglages. | Le demander dans l'accueil (« Compléter les informations des livres en ligne ? », avec ce qui est envoyé et à qui), désactivé tant qu'il n'a pas répondu. Voir aussi le § 5. |
| 🟠 | Les messages d'autorisation de macOS n'ont **pas d'explication** : volume amovible (la Kindle), dossiers Documents, Bureau ou Téléchargements quand la bibliothèque s'y trouve. L'`Info.plist` n'a aucune clé `NS…UsageDescription`. | Ajouter dans `scripts/bundle.sh` : `NSRemovableVolumesUsageDescription` (« pour envoyer des livres à votre Kindle et lire ses notes »), `NSDocumentsFolderUsageDescription`, `NSDesktopFolderUsageDescription`, `NSDownloadsFolderUsageDescription`. |
| 🟢 | L'accueil ne présente qu'une étape : choisir le dossier. Les gestes clés passent inaperçus : brancher la Kindle, ⌘L pour lire, recherche dans le contenu, thématiques. | Deux ou trois écrans courts après le choix du dossier, ou une page « Bien commencer » dans l'aide. |
| ✅ | Notifications demandées au bon moment : à la première mise en attente d'un livre, jamais au lancement (`SendNotifier`). | — |
| ✅ | États vides présents : 16 `ContentUnavailableView` (aucune note, aucun résultat, thématique vide, Kindle débranchée…) et indexation du texte visible. | — |

## 4. Rapports de plantage

| | Constat | Ce qu'il faut |
| --- | --- | --- |
| 🟠 | **Aucun rapport de plantage.** Hors App Store, Xcode Organizer ne reçoit rien : un plantage chez un client reste invisible. | Deux voies, au choix. |

- **MetricKit (recommandé pour commencer).** Apple livre à l'app, au lancement suivant, les diagnostics de plantage et de blocage (`MXMetricManager`, `MXDiagnosticPayload`, macOS 12+). Rien ne quitte le Mac sans l'accord de l'utilisateur. L'app peut lui proposer : « Foluna s'est arrêtée la dernière fois : envoyer le rapport ? », par e-mail ou vers un formulaire. Aucun tiers, donc rien à ajouter à la politique de confidentialité au-delà de cet envoi volontaire.
- **Sentry ou équivalent.** Rapports automatiques, regroupés, avec la pile d'appels symbolisée. Mais c'est un sous-traitant qui reçoit des données (adresse IP, modèle de Mac, version de macOS). Il faut le déclarer dans la politique de confidentialité et le registre RGPD, et idéalement le désactiver par défaut ou le demander à l'accueil.

Dans les deux cas, garder les fichiers `.dSYM` de chaque version publiée : `scripts/release.sh` ne les conserve pas aujourd'hui, et sans eux une pile d'appels est illisible.

## 5. Vie privée : inventaire des données

**Collecte par le développeur : aucune.** Pas de compte, pas de mesure d'audience, pas de publicité, pas de suivi.

**Données envoyées sur Internet**, toutes sans compte :

| Destinataire | Quoi | Quand | Réglage |
| --- | --- | --- | --- |
| BnF (`catalogue.bnf.fr`, API SRU) | ISBN, ou titre et auteur d'un livre | Nouveaux livres (automatique par défaut), ou bouton « Vérifier » d'une fiche | Réglages > Général > Vérification en ligne |
| Open Library (`openlibrary.org`) | Les mêmes, si la BnF ne trouve pas | Idem | Idem |
| Open Library Covers (`covers.openlibrary.org`) | ISBN ou identifiant Open Library | Recherche de couverture | À la demande |
| GitHub (`api.github.com`) | Commit installé, à cause du canal actuel ; adresse IP | Au démarrage, si la vérification des mises à jour est cochée | Réglages > Mises à jour |
| GitHub (téléchargement) | Adresse IP | « Installer et relancer » | À la demande |
| Catalogues OPDS (Project Gutenberg, Ebooks libres et gratuits, Bibliothèque numérique romande, ou une adresse ajoutée) | Pages parcourues, mots cherchés, livres téléchargés ; adresse IP | Seulement quand l'utilisateur ouvre un catalogue dans la barre latérale | Retirer le catalogue (« Gérer les catalogues… ») |

Chaque requête porte l'adresse IP du Mac et le User-Agent « Foluna (macOS) ». **La liste des livres lus peut révéler des opinions, des croyances ou une santé** : c'est une donnée sensible au sens du RGPD (art. 9). D'où la demande d'accord à l'accueil (§ 3).

**Données gardées sur le Mac** (`~/Library/Application Support/Alexandrie/`, jamais envoyées) :
- la bibliothèque (titres, auteurs, chemins des fichiers, ISBN) ;
- les couvertures ;
- les noms des liseuses et leurs étagères ;
- les notes et surlignages (ceux de la Kindle et ceux de l'app) ;
- les thématiques ;
- les positions de lecture ;
- le texte des livres et son index de recherche ;
- les catalogues OPDS ajoutés et la liste des livres qui en ont été téléchargés (`opds.json`) ;
- des sauvegardes datées.

Les réglages sont dans `UserDefaults`.

**Zotero**, seulement à la demande (« Envoyer à Zotero ») : les passages, notes, couleurs, thématiques et positions d'un livre, et sa fiche (titre, auteurs, ISBN, éditeur, date, langue, résumé) si sa référence est créée, vont au Zotero du Mac par son API locale (`127.0.0.1:23119`). Zotero les synchronise si l'utilisateur a un compte Zotero. L'autorisation d'écrire est gardée dans le Trousseau ; `zotero.json` garde les correspondances.

**Copie hors du Mac**, si l'utilisateur l'active (Réglages › Sauvegarde) : les fichiers ci-dessus (sauf le texte indexé et les caches), les livres importés et les couvertures sont copiés chaque jour dans le dossier qu'il choisit. Dans iCloud Drive, ils partent chez Apple avec son compte iCloud, pas chez le développeur.

**Pour l'App Store**, si ce canal est choisi :
- l'étiquette de confidentialité serait « Données non collectées », car les requêtes aux catalogues ne vont pas au développeur ;
- il faudrait un manifeste `PrivacyInfo.xcprivacy`, qui déclare l'usage de `UserDefaults` (raison `CA92.1`) et des dates de fichiers (`C617.1`).

**Pour le RGPD**, il faut :
- une politique de confidentialité courte qui reprend ce tableau ;
- les bases légales des envois : le consentement pour les catalogues, l'intérêt légitime pour la vérification des mises à jour ;
- les destinataires et leur pays : la BnF en France, Open Library (Internet Archive) aux États-Unis, GitHub aux États-Unis, les catalogues OPDS ouverts par l'utilisateur (Project Gutenberg aux États-Unis, Ebooks libres et gratuits au Canada, Bibliothèque numérique romande en Suisse) ;
- un moyen de tout effacer : supprimer le dossier de données, ce que l'app pourrait proposer.

## 6. Étape 1 faite (code)

Corrigé le 7 novembre 2026, chaque point vérifié par le selftest ou une capture :
- **JavaScript des livres coupé.** Les scripts de Foluna tournent dans `WKContentWorld.defaultClient`. Le selftest le vérifie : le script d'une page ne s'exécute pas, ceux de Foluna si ; surlignages, notes et renvois marchent toujours.
- **Autorisations expliquées.** Clés `NSRemovableVolumes…`, `NSDocumentsFolder…`, `NSDesktopFolder…`, `NSDownloadsFolder…` et `NSNetworkVolumes…UsageDescription` dans l'`Info.plist` (`scripts/bundle.sh`).
- **Vérification en ligne sur accord.** Désactivée tant que l'utilisateur n'a pas répondu : case dans l'accueil (décochée), ou feuille au lancement pour une bibliothèque déjà en place.
- **Enregistrements ratés signalés.** Thématiques et positions de lecture affichent une erreur au lieu d'échouer en silence.
- **Sauvegardes datées.** Elles couvrent aussi les thématiques et les positions de lecture.
- **Rapports de plantage (MetricKit).** Gardés dans `Rapports/`, proposés au lancement suivant (« Afficher dans le Finder », « Ne pas envoyer », « Envoyer par e-mail… »). Le bouton d'e-mail n'apparaît que si `FOLUNA_SUPPORT_EMAIL` est défini au moment de `scripts/bundle.sh`.
- **User-Agent unique.** `Foluna/<version> (macOS)` pour toutes les requêtes, téléchargement compris.

## 7. Décision : gratuit et libre (7 novembre 2026)

Foluna ne sera pas vendue. Elle reste **gratuite**, sous **licence MIT**, dans le dépôt public `adnmac/Foluna`.

Conséquences sur cet audit :
- **§ 1 sans objet** : pas de Developer ID ni de notarisation, pas de licence ni de paiement, pas de CGV. Le dépôt public n'est plus un problème : la licence MIT dit ce que chacun peut en faire.
- **Mises à jour** : l'app consulte les versions publiées de ce dépôt (et les commits de `main` pour une app construite depuis git).
- **Installation** : l'app n'étant pas notarisée, chaque personne l'autorise une fois dans Réglages Système > Confidentialité et sécurité (« Ouvrir quand même »).
- **Vie privée (§ 5)** : le RGPD s'applique aussi à une app gratuite. L'inventaire est repris dans la section « Confidentialité » du README.
- **Toujours valables** : les corrections de l'étape 1 (§ 6) et les points 🟢 restants.
