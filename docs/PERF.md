# Performances sur une grande bibliothèque

Premier test de résistance : 14 novembre 2026, Foluna 0.8.0, compilé en release, sur ce Mac.
Livres inventés (`StressData`, `StressCatalog`) :
- environ 90 % d'EPUB, dont un tiers avec couverture ;
- 2 % de PDF ;
- 5 % de copies en double ;
- 1 % de fichiers tronqués ;
- un livre sur 1 000 titré « Mémoires ».

## Référence finale

Série du 14 novembre 2026 après tous les correctifs : machine sans autre application, visite protégée d'App Nap. C'est elle qu'il faut comparer aux passes suivantes.

**Store réel, sans fenêtre** (`scripts/stress.sh`), durée en ms et plus long blocage entre parenthèses :

| Étape | 1 000 | 10 000 | 50 000 | 100 000 |
| --- | ---: | ---: | ---: | ---: |
| Première indexation | 588 (0) | 5 100 (1) | 24 166 (4) | 46 178 (19) |
| Relance : création du store | 17 (29) | 2 | 2 | 2 |
| Parcours sans changement | 105 (0) | 1 074 (3) | 4 349 (193) | 8 423 (357) |
| Parcours après ajout de 1 % | 258 (0) | 1 059 (36) | 4 004 (201) | 7 741 (376) |
| Identités après une étiquette | 4 | 15 | 78 (54) | 144 (135) |
| Identités après un titre corrigé | 6 | 33 (38) | 148 (282) | 303 (571) |
| 50 livres à la corbeille | 3 | 20 (35) | 104 (180) | 239 (401) |
| Tri par titre, par rangs | 18 | 20 | 110 | 198 (179) |
| Enregistrement (`saveNow`) | 19 | 29 | 60 | 138 (142) |

Aucun livre perdu à aucun palier. Mémoire maximale : 126 Mo à 10 000 livres, 1 135 Mo à 100 000. La première indexation de 10 000 livres varie selon les passes (de 3,2 à 5,1 s). Certaines étapes du test sont faites sur le thread principal par le test lui-même, et l'app ne les fait pas ainsi : la relecture de l'index après « relance », le calcul direct du tri et des listes de la barre latérale.

**Interface** (`scripts/stress-ui.sh`), plus long blocage du thread principal :

| Action | 10 000 | 100 000 | 10 000, index vide |
| --- | ---: | ---: | ---: |
| Ouverture et parcours | 47 ms | 521 ms | 117 ms (indexation : 3,7 s) |
| Tous les livres (grille) | 0 ms | 112 ms | 0 ms |
| Autres pages (grille) | 0 à 30 ms | 0 à 80 ms | 0 à 49 ms |
| Pages en liste | 13 à 139 ms | 60 à 155 ms | 37 à 131 ms |
| Fiche d'un livre | 115 ms | 57 ms | 87 ms |
| Sélection de 1 000 livres | 60 ms | 40 ms | 216 ms |
| Recherche tapée lettre par lettre | 66 ms | 1 ms | 27 ms |

À 10 000 livres, aucune action ne dépasse 250 ms. À 100 000 livres, seule l'ouverture dépasse encore ce seuil (0,5 s, lecture de l'index et premiers calculs). Mémoire de l'app pendant la visite : 120 à 360 Mo à 10 000 livres, 0,65 à 1,5 Go à 100 000.

## Première référence (avant les derniers correctifs)

Série complète du 14 novembre 2026, après tous les correctifs, machine sans autre application (charge moyenne autour de 4, app de test comprise). C'est elle qu'il faut comparer aux passes suivantes.

**Store réel, sans fenêtre** (`scripts/stress.sh`), durée en ms et plus long blocage entre parenthèses :

| Étape | 1 000 | 10 000 | 50 000 | 100 000 |
| --- | ---: | ---: | ---: | ---: |
| Première indexation | 588 (0) | 3 230 (0) | 24 243 (1) | 47 828 (0) |
| Relance : création du store | 16 (21) | 2 | 2 | 2 |
| Parcours sans changement | 102 (0) | 1 028 (5) | 4 248 (173) | 8 403 (391) |
| Parcours après ajout de 1 % | 252 (0) | 1 121 (0) | 4 004 (156) | 7 711 (400) |
| Identités après une étiquette | 3 | 15 | 78 | 144 (103) |
| Identités après un titre corrigé | 4 | 27 (56) | 146 (438) | 296 (889) |
| 50 livres à la corbeille | 3 | 18 (32) | 103 (282) | 219 (646) |
| Tri par titre, par rangs | 19 | 19 | 100 | 213 (197) |
| Enregistrement (`saveNow`) | 21 | 85 (66) | 362 (332) | 722 (706) |

Aucun livre perdu à aucun palier. Index : 6,8 Mo à 10 000 livres, 68 Mo à 100 000. Mémoire maximale : 124 Mo à 10 000 livres, 1 075 Mo à 100 000. Les lignes « tri par titre » et « listes de la barre latérale » de `synthese.md` mesurent l'ancien calcul direct (1,5 s et 1,1 s à 100 000 livres) : l'app n'y passe plus sur le thread principal.

**Interface** (`scripts/stress-ui.sh`), plus long blocage du thread principal :

| Action | 10 000 | 100 000 | 10 000, index vide |
| --- | ---: | ---: | ---: |
| Ouverture et parcours | 93 ms | 1 031 ms | 93 ms (indexation : 4,9 s) |
| Tous les livres (grille) | 107 ms | 844 ms | 149 ms |
| Autres pages (grille) | 0 à 35 ms | 0 à 32 ms | 0 à 20 ms |
| Pages en liste | 50 à 147 ms | 57 à 171 ms | 24 à 127 ms |
| Fiche d'un livre | 152 ms | 359 ms | 208 ms |
| Sélection de 1 000 livres | 52 ms | 27 ms | 176 ms |
| Recherche tapée lettre par lettre | 72 ms | 5 ms | 58 ms |

À 10 000 livres, aucune action ne dépasse 250 ms.

**Après cette série : identités et doublons d'affichage en arrière-plan.** Au-delà de 5 000 livres, après une modification (un parcours par exemple), les identités et les doublons masqués destinés à l'affichage sont recalculés hors du thread principal (`refreshForDisplay`). En attendant, les vues gardent les précédents ; les actions passent toujours par `identities`, exactes. Le premier calcul des identités garde aussi son résultat comme « identités précédentes ».

`StressUI` attend maintenant que les identités et le résumé soient prêts avant de mesurer l'ouverture, et prend ses listes dans le résumé : il les recalculait sur le thread principal (0,4 s), ce qui gonflait la mesure.

| 100 000 livres, plus long blocage | Série de référence | Après |
| --- | ---: | ---: |
| Ouverture (identités et liste comprises) | 1 031 ms | 535 ms |
| Tous les livres (grille), juste après | 844 ms | 88 ms |
| Pages en liste | 57 à 171 ms | 32 à 178 ms |
| Fiche d'un livre | 359 ms | 359 ms |

À 100 000 livres, seuls dépassent encore 250 ms :
- l'ouverture (0,5 s) ;
- la fiche (0,36 s) ;
- ~~l'enregistrement de l'index à la fermeture (0,7 s)~~ : 0,14 s depuis l'encodage en parallèle (voir plus bas).

**Index encodé en parallèle.** `LibraryIndex.encode` encode l'index en morceaux de 2 000 livres sur plusieurs fils, puis les recolle : sans leurs crochets et joints par des virgules, les morceaux donnent les mêmes octets qu'un encodage d'un seul tenant (`LibraryIndexEncodingTests`, y compris aux bornes des morceaux). Cela sert à chaque enregistrement, en arrière-plan comme à la fermeture.

| Écriture de l'index | 10 000 livres | 100 000 livres |
| --- | ---: | ---: |
| Encodage seul (banc d'essai) | 80 → 25 ms | 679 → 111 ms |
| `saveNow` (store réel, bloque la fermeture) | 85 → 28 ms | 722 → 140 ms |

**Fiche et ouverture.** L'index des positions (`position(of:)`) n'est plus vidé à chaque modification : une position est vérifiée avant d'être rendue, et l'index n'est reconstruit que si elle ne correspond plus. La première fiche ouverte après une retouche ne paie plus 0,3 s à 100 000 livres. Le premier calcul des identités et le recalcul d'affichage calculent aussi, en arrière-plan, les doublons masqués et les copies regroupées par livre.

| 100 000 livres, plus long blocage | Avant | Après (passe 1) |
| --- | ---: | ---: |
| Ouverture | 535 ms | 421 ms |
| Fiche d'un livre | 359 ms | 46 ms |

Variabilité expliquée : App Nap. Sur certaines passes, à partir d'environ 30 s de visite, chaque action en liste coûtait 0,3 à 3,5 s, et la fiche jusqu'à 1,9 s. La cause était macOS, qui met en veille une app dont la fenêtre est cachée par d'autres (priorité baissée, minuteries regroupées), et la fenêtre de test était souvent derrière d'autres fenêtres. Preuve, à 100 000 livres :
- app masquée exprès, App Nap actif : blocages jusqu'à 8,7 s ;
- `NSAppSleepDisabled` : trois passes sur trois rapides ;
- activité déclarée : app masquée et rapide (liste de 44 à 159 ms, fiche 254 ms).

C'est un artefact de mesure : quelqu'un qui regarde la fenêtre de Foluna n'est pas concerné. `StressUI` déclare maintenant une activité au système (`ProcessInfo.beginActivity`) pendant la visite. Plusieurs lenteurs attribuées plus haut à une « machine chargée » venaient sans doute aussi d'App Nap.

## Comment relancer

```bash
scripts/stress.sh                    # 1000 10000 50000 100000 : store réel, sans fenêtre
scripts/stress-ui.sh 10000           # interface sur le store indexé par stress.sh
FOLUNA_STRESS=1 scripts/test.sh -c release -Xswiftc -enable-testing --filter StressTests
```

Rapports dans `/tmp/foluna-stress` : `synthese.md`, `rapport-<n>.md` et `interface-<n>.md`. Les livres générés sont gardés dans `/tmp/foluna-stress-data/<n>`, soit environ 4,5 Go pour 100 000 livres.

## Résultat : justesse

Aucun échec à aucun palier :
- tous les fichiers sont indexés, y compris les fichiers tronqués ;
- l'index relu est identique à l'index écrit ;
- les ajouts et les retraits de fichiers sont repris ;
- les étiquettes sont renommées et supprimées sur toute la bibliothèque ;
- la corbeille est remplie, puis vidée par la restauration.

## Résultat : temps (ms), avec le plus long blocage du thread principal entre parenthèses

| Étape | 1 000 | 10 000 | 50 000 | 100 000 |
| --- | ---: | ---: | ---: | ---: |
| Première indexation | 1 398 (5) | 13 193 (484) | 66 157 (2 621) | 129 234 (5 460) |
| Relance : chargement de l'index | 16 (34) | 91 (190) | 444 (920) | 857 (1 923) |
| Parcours sans changement | 156 (41) | 1 250 (394) | 5 866 (2 304) | 11 486 (4 732) |
| Parcours après ajout de 1 % | 302 (32) | 1 534 (395) | 6 517 (2 110) | 12 674 (4 361) |
| Tri par titre | 25 | 121 | 742 | 1 528 |
| Listes de la barre latérale | 18 | 139 | 537 | 1 020 |
| Recherche « jardin » | 8 | 38 | 167 | 327 |
| **50 livres à la corbeille** (avant la correction) | **2 007** | **19 131** | **101 572** | **205 695** |
| 50 livres à la corbeille (après) | 2 | 18 | 97 | 248 |
| 50 livres restaurés (après) | 49 | 382 | 1 970 | 4 203 |
| Enregistrement (saveNow) | 11 | 83 | 382 | 726 |

| Palier | Index | Couvertures | Mémoire max |
| ---: | ---: | ---: | ---: |
| 10 000 | 6,8 Mo | 33 Mo | 112 Mo |
| 100 000 | 68 Mo | 339 Mo | 858 Mo |

Bancs d'essai du cœur, en mémoire, à 100 000 livres :

| Opération | Durée |
| --- | ---: |
| `BookGroups.identities` | 3,5 s |
| Tri par titre | 1,6 s |
| Index : lecture | 0,72 s |
| Index : écriture | 0,68 s |
| `LibraryMerge.plan` après un dossier renommé | 6,9 s (hors du thread principal) |

Titres identiques, auteurs différents (`identities`) :

| Livres au même titre | Durée |
| ---: | ---: |
| 100 | 0,37 s |
| 200 | 2,1 s |
| 400 | 17,5 s |

Interface, 10 000 livres (`interface-10500.md`) :
- **chaque** changement de page bloque entre 0,3 et 0,8 s, même la page PDF qui ne compte que 200 livres ;
- ouvrir la fiche d'un livre bloque 1,3 s ;
- sélectionner 1 000 livres bloque 1,2 s ;
- chaque lettre tapée dans la recherche bloque environ 0,4 s.

## Points lents, du plus grave au moins grave

1. **Corbeille sur une sélection : corrigé.**
   - Avant : `BookCommands.swift:59` appelait `moveToTrash` pour chaque livre. Chaque appel vidait le cache des identités, et l'appel suivant les recalculait toutes. Résultat : 50 livres figeaient l'app 19 s à 10 000 livres et 3 min 25 s à 100 000.
   - Maintenant : `moveToTrash(_:)` et `restoreFromTrash(_:)` reçoivent toute la sélection, lisent les identités une fois et réaffectent `books` une seule fois.

   | 50 livres | 10 000 | 100 000 |
   | --- | ---: | ---: |
   | À la corbeille | 19 ms | 0,20 s |
   | Restaurés | 18 ms | 0,17 s |

   Avant la correction du point 2, il fallait encore 4,2 s pour restaurer à 100 000 livres : les identités étaient recalculées après la mise à la corbeille.
2. **Identités recalculées après chaque modification : corrigé.**
   - Avant : `books.didSet` vidait `identityMap`, et la barre latérale relit les identités (`bookCount`). Le rendu qui suivait n'importe quelle retouche refaisait donc tout le calcul.
   - Maintenant : `IdentityCache` (dans le cœur) tient les identités à jour titre par titre. Les identités d'un fichier ne dépendent que des fichiers de même titre (`BookGroups.titleKey`), et pour chacun de son chemin, de son titre et de ses auteurs.
     - Une étiquette, un favori, la corbeille ou un envoi ne touchent aucun titre : il ne reste qu'une recherche par fichier.
     - Un titre ou un auteur corrigé ne recalcule que l'ancien et le nouveau titre.
     - Un fichier ajouté ou disparu ne recalcule que son titre.
     - Au-delà de la moitié des fichiers touchés, le calcul complet est refait.

     `IdentityCacheTests` vérifie que le résultat reste identique au calcul complet, sur des retouches choisies et sur 40 retouches au hasard.

   | 100 000 livres | Avant | Après |
   | --- | ---: | ---: |
   | Identités après une étiquette | 3,5 à 4,3 s | 0,14 s |
   | Identités après un titre corrigé | 4,3 s | 0,30 s |
   | 50 livres restaurés | 4,2 s | 0,17 s |

   Ce qui reste à surveiller :
   - La mémoire maximale à 100 000 livres passe d'environ 880 à 1 090 Mo : le cache garde une entrée par fichier.
   - La première indexation à 100 000 livres a mis 151 s, contre 129 s au premier passage. L'écart était le même avec la version intermédiaire, qui ne touchait pas au parcours : il vient probablement de l'état de la machine. À vérifier au prochain passage.
3. **Même titre, auteurs différents : corrigé.**
   - Avant : `BookGroups.identities` fusionnait les groupes deux à deux et recommençait depuis le début après chaque fusion, soit O(k³). Quelques centaines de « Sans titre », « Mémoires » ou « Poèmes » suffisaient à figer l'app.
   - Maintenant : `BookGroups.components` calcule les mêmes groupes (composantes connexes) avec un union-find, et compare chaque ensemble de mots d'auteur distinct une seule fois. `BookComponentsTests` compare le résultat à l'ancien algorithme sur des cas choisis et sur 30 bibliothèques tirées au hasard.

   | Livres au même titre | Avant | Après |
   | ---: | ---: | ---: |
   | 100 | 0,37 s | 5 ms |
   | 200 | 2,1 s | 10 ms |
   | 400 | 17,5 s | 22 ms |

   Le calcul complet sur 100 000 livres variés ne change pas (3,4 s), car il est dominé par le calcul des clés de chaque fichier. Grâce à `IdentityCache`, il n'est refait que rarement.
4. **Coût fixe de chaque rendu : corrigé pour l'essentiel.**
   - Avant : `ContentView` et `SidebarView` refaisaient à chaque passage `visibleBooks`, les groupes, le tri, les listes auteurs, séries, étiquettes et genres, et les compteurs. Changer de page, sélectionner ou ouvrir une fiche coûtait donc entre 0,3 et 1,3 s à 10 000 livres.
   - Maintenant :
     - `LibraryStore` garde `visibleBooks` et un `LibrarySummary` (tous les compteurs et toutes les listes de la barre latérale, en un passage) jusqu'à la modification suivante de la bibliothèque ;
     - `ContentView` garde la liste filtrée, triée et groupée (`ListingMemo`) tant que la bibliothèque, la page, la recherche et le tri ne changent pas ;
     - la fiche, la sélection et le survol ne refont plus rien.

   Interface, 10 000 livres, plus long blocage du thread principal (`scripts/stress-ui.sh 10000`) :

   | Action | Avant | Après |
   | --- | ---: | ---: |
   | Tous les livres (grille) | 839 ms | 233 ms |
   | Page PDF (200 livres) | 367 ms | 11 ms |
   | Auteur | 473 ms | 24 ms |
   | Fiche d'un livre | 1 285 ms | 193 ms |
   | Sélection de 1 000 livres | 1 199 ms | 101 ms |
   | Recherche tapée lettre par lettre | 925 ms | 185 ms |
   | Blocages de plus de 250 ms, sur toute la visite | 29 | 0 |

   - **Tri hors du thread principal.** `SortRanks` calcule en arrière-plan, après chaque modification, le rang de chaque fichier par titre et par auteur. La liste ne fait plus que ranger ses livres par rang.
     - Les livres arrivés depuis le dernier calcul sont insérés à leur place par recherche dichotomique.
     - Les listes de moins de 2 000 livres sont triées directement, comme avant.
     - `SortRanksTests` vérifie que l'ordre obtenu est le même qu'avec le tri direct.
     - Tri par titre de toute la liste : 1,5 s → 0,25 s à 100 000 livres, 126 → 21 ms à 10 000.
     - Un livre retouché garde son ancien rang jusqu'au calcul suivant, une fraction de seconde plus tard.

   - **Liste calculée hors du thread principal.** Un profil (`sample`) de la visite à 100 000 livres a montré où partait le temps, et la liste a été corrigée en conséquence :
     - `Book.url` interrogeait le disque pour chaque livre (`URL(fileURLWithPath:)` sans `isDirectory`). Les adresses de Coup d'œil sont maintenant calculées à la demande.
     - Les tris déplaçaient de gros `Book` : ils trient maintenant des indices.
     - Le filtre de la recherche coûtait près d'une seconde par lettre tapée. Au-delà de 5 000 livres, la liste (filtre, recherche, tri, regroupement, voir `LibraryListing`) est calculée en arrière-plan, et la précédente reste affichée avec un indicateur. En deçà, elle est calculée directement, comme avant.
   - **Indexation du contenu.** `ContentIndexer` occupait le thread principal plus que tout le reste : `removeFirst` sur une grande file, et l'index SearchKit écrit tous les dix livres. La file se vide maintenant par la fin. L'index et la liste des livres indexés sont écrits hors du thread principal, tous les 50 livres ou toutes les 5 secondes.

   Plus long blocage du thread principal, après ces corrections :

   | Action | 10 000 livres | 100 000 livres |
   | --- | ---: | ---: |
   | Tous les livres | 90 ms | 0,3 s (2,1 s au premier affichage) |
   | Récents | 3 ms | 0,34 s |
   | Petites pages (format, étiquette, auteur, série) | moins de 25 ms | moins de 25 ms |
   | Fiche d'un livre | 149 ms | 0,93 s |
   | Sélection de 1 000 livres | 118 ms | 0,59 s |
   | Recherche tapée lettre par lettre | 66 ms | 0,59 s |

   - **Sélection lue par les cartes.** `SelectionBox` (objet observé) porte la sélection de la grille, et chaque carte (`SelectableBookCard`) lit seulement si elle est sélectionnée. `LibraryView` est comparable par l'identité de sa liste (`.equatable()`) : un clic ne reconstruit plus la grille ni la liste.

   | Action | 10 000 livres | 100 000 livres |
   | --- | ---: | ---: |
   | Sélection de 1 000 livres | 70 ms | 77 ms (0,59 s avant) |
   | Fiche d'un livre | 108 ms | 0,40 s (0,93 s avant) |
   | Recherche tapée lettre par lettre | 81 ms | 0,27 s (0,59 s avant) |
   | Tous les livres | 123 ms | 0,27 à 0,86 s |

   - **Liste (`Table`) reconstruite plutôt que comparée.** Les mesures « liste » ci-dessus étaient faussées. `scripts/stress-ui.sh` lançait l'app avec `-gridMode YES` : un argument de lancement l'emporte sur le réglage, donc la page restait en grille. Il ne le fait plus.
     - Une fois mesurée pour de vrai à 100 000 livres, la liste bloquait 5,2 s sur Tous les livres et 44,6 s sur Récents : SwiftUI comparait les 100 000 lignes une à une quand l'ordre changeait.
     - La liste prend maintenant une nouvelle identité (`.id`) quand la page, la recherche ou le tri changent, au moment où les nouveaux livres s'affichent. Elle est alors reconstruite.
     - Une retouche (étiquette, favori) garde l'identité : le défilement n'est pas perdu.

   | Liste, plus long blocage | 10 000 livres | 100 000 livres |
   | --- | ---: | ---: |
   | Tous les livres | 41 ms | 0,21 s (5,2 s avant) |
   | Récents | 110 ms | 0,18 s (44,6 s avant) |
   | Petites pages | moins de 115 ms | moins de 210 ms |

   - **Vérifié dans l'app avec de vrais clics** (contrôle de l'ordinateur, 10 000 livres) :
     - grille : clic sur une carte (cadre et fiche), clic dans le vide (tout désélectionné) ;
     - liste : clic, ⌘-clic et ⇧-clic ;
     - même sélection après un passage de la liste à la grille.

     ⌘-clic et ⇧-clic dans la grille : corrigés et vérifiés ensuite. La grille lisait les touches (`NSEvent.modifierFlags`) quand le clic simple était confirmé, après le délai du double-clic, et perdait ⌘ ou ⇧ déjà relâchée. `ClickModifiers` retient maintenant les touches au moment où le bouton s'abaisse. Vérifié avec de vrais clics : ⌘-clic ajoute puis retire un livre, ⇧-clic étend la sélection.

   Ce qui reste à 100 000 livres :
   - afficher une nouvelle liste de toute la bibliothèque coûte encore 0,3 à 0,9 s, le temps que SwiftUI prépare 100 000 éléments ;
   - ouvrir une fiche coûte 0,4 s.

   - **Affichage par fenêtre.** La grille et la liste ne reçoivent que les 2 000 premiers livres de la page, puis 2 000 de plus quand la fin devient visible en défilant (vérifié avec de vrais défilements). La sélection, Coup d'œil et le tri portent toujours sur toute la page.
   - **Copies masquées regroupées une fois.** `hiddenCopies(of:)` filtrait toute la bibliothèque à chaque fiche ouverte (0,45 s à 100 000 livres). Les copies sont maintenant regroupées par livre une seule fois par modification.

   | 100 000 livres, plus long blocage | Avant | Après |
   | --- | ---: | ---: |
   | Récents (grille) | 0,32 à 0,45 s | 0,06 à 0,11 s |
   | À vérifier (grille) | 0,32 à 0,40 s | 0,08 à 0,10 s |
   | Tous les livres (liste) | 0,21 à 0,64 s | 0,11 à 0,15 s |

   Les pages en liste mesurées à 0,4 à 1,2 s et la fiche à 1,9 s pendant ce travail l'avaient été sur une machine chargée. La série de référence (machine au calme, en tête de ce document) les place à 57 à 171 ms et à 0,36 s.
5. **Parcours sans changement et ouverture : corrigés pour l'essentiel.** Le profil a montré que le parcours lui-même coûtait peu sur le thread principal. Le blocage venait du premier calcul des identités après le lancement (3,4 s à 100 000 livres), puis du résumé de la barre latérale et de `ContentIndexer.refresh`, refaits à chaque étape du parcours.
   - Au-delà de 5 000 livres, `LibraryStore` lance le premier calcul des identités en arrière-plan dès le chargement de l'index (`warmUpIdentities`). Pendant ce temps, les vues lisent `readyIdentities`, qui vaut nil : les doublons ne sont pas encore masqués, et la barre latérale montre le nombre de fichiers. Les actions (corbeille, étiquettes) passent par `identities`, toujours exactes.
   - Au-delà de 5 000 livres, le résumé de la barre latérale est calculé en arrière-plan, et le précédent reste affiché pendant le calcul.
   - `ContentIndexer.refresh` choisit et trie les livres à indexer hors du thread principal. Seul le dernier appel s'applique.
   - Le premier calcul d'`IdentityCache` ne calcule plus deux fois les clés de titre (8 % de gagné).

   | Plus long blocage | 10 000 livres | 100 000 livres |
   | --- | ---: | ---: |
   | Parcours sans changement (sans fenêtre) | 40 ms | 0,83 s (5,4 s avant) |
   | Ouverture de la fenêtre et parcours | 90 ms (360 ms avant) | 1,0 s (1,8 s avant) |

6. **Lancement : index lu en arrière-plan.** Au-delà de 5 Mo d'index (environ 7 000 livres), `LibraryStore` lit l'index, fait la copie du jour et sépare les numéros des noms de série hors du thread principal (`readIndex`).
   - Pendant la lecture, la page montre l'indexation et les parcours demandés attendent.
   - `write` et `saveNow` n'écrivent rien pendant la lecture : la liste encore vide ne peut pas écraser l'index.
   - En dessous de 5 Mo, rien ne change.
   - Résultat : la création du store passe de 0,9 s à 2 ms à 100 000 livres. La lecture complète est vérifiée par le test de résistance (« relance sans perte »), pas par le self-test, qui utilise un petit index.

   Ce qui reste à l'ouverture, à 100 000 livres : quelques blocages de 0,4 à 1 s, répartis entre le calcul des doublons masqués (`hiddenDuplicates`, environ 0,2 s), la fusion du parcours sur le thread principal (environ 0,4 s) et l'affichage de la grille. À la fermeture, `saveNow` écrit l'index en 0,7 s.
7. **Première indexation, fenêtre ouverte : corrigé.** Mesurée avec `FOLUNA_STRESS_UI_FRESH=1 scripts/stress-ui.sh 10000`, qui part d'un index vide.
   - Avant : chaque livre extrait était ajouté seul à `books`, et chaque ajout faisait recalculer aux vues toute la bibliothèque (visibles, doublons, identités, liste, barre latérale). Avec 10 000 livres, l'indexation n'était pas finie au bout de 20 minutes, avec des blocages de plus en plus longs (jusqu'à 20 s en liste). Plus le thread principal saturait, plus l'extraction ralentissait.
   - Maintenant : le parcours publie les livres par lots. L'intervalle vaut 0,5 s plus 0,4 ms par livre déjà indexé, 5 s au plus, et l'avancement est mis à jour toutes les 100 ms.
   - La liste (`Table`) est reconstruite quand un lot change le nombre de lignes de plus de 200, au lieu d'être comparée ligne à ligne.

   | 10 000 livres, index vide | Avant | Après |
   | --- | ---: | ---: |
   | Grille : durée de l'indexation | plus de 20 min | 17 s |
   | Grille : plus long blocage pendant l'indexation | 2,5 s et plus | 0,26 s |
   | Liste : durée de l'indexation | non finie en 15 min | 24 s |
   | Liste : plus long blocage pendant l'indexation | jusqu'à 20 s | 0,53 s |

   - **Extraction en parallèle.** `rescan` lit les fichiers sur un fil par cœur moins un (`withTaskGroup`). Les PDF passent un à la fois derrière un verrou, parce que PDFKit et AppKit dessinent leur vignette et ne se partagent pas entre fils.
   - **Identités pendant un gros parcours.** Au-delà de 5 000 fichiers à lire, les vues font sans les identités pendant le parcours, et le calcul est lancé en arrière-plan à la fin (`warmUpIdentities`). Seul le dernier calcul lancé conclut. Avant, chaque lot provoquait un recalcul complet sur le thread principal (4,4 s à 100 000 livres).

   | Première indexation | Avant | Après |
   | --- | ---: | ---: |
   | 10 000 livres, sans fenêtre | 13,1 s (800 livres/s) | 3,6 s (2 900 livres/s) |
   | 100 000 livres, sans fenêtre | 129 à 161 s, blocage 5,5 s | 46,6 s, aucun blocage |
   | 10 000 livres, fenêtre ouverte (grille) | 17 s | 4,9 s, blocage 44 ms |

   Après une première indexation, les pages restent rapides : sur trois passes de suite, en liste de 8 à 159 ms, la fiche de 235 à 271 ms, la sélection de 1 000 livres de 181 à 190 ms. Deux passes précédentes avaient mesuré 0,6 à 1,7 s, alors que la machine était chargée par d'autres mesures lancées en même temps (charge moyenne autour de 22). Une instrumentation temporaire a confirmé que la bibliothèque ne change plus pendant la visite : ni parcours, ni recalcul en boucle. Avant de comparer deux passes de `stress-ui.sh`, vérifier que rien d'autre ne tourne (`uptime`).

`scripts/stress-ui.sh` fixe la présentation au lancement par le réglage du bundle de test (`FOLUNA_STRESS_UI_GRID=NO` pour la liste), plus par un argument `-gridMode`, qui empêchait de changer de présentation dans l'app.

## Pas encore mesuré

- La mémoire des couvertures pendant le défilement, mesurée en partie. En faisant défiler toute la grille à 10 000 livres, la mémoire passe de 170 à 242 Mo, soit environ 0,2 Mo par couverture chargée. Le cache (`NSCache`) n'avait aucune limite : parcourir une très grande bibliothèque aurait gardé chaque couverture vue jusqu'à ce que macOS manque de mémoire. Il est maintenant limité à 400 couvertures (environ 80 Mo). Le défilement en arrière-plan de l'outil de contrôle ne charge que quelques centaines de couvertures, ce qui ne suffit pas à voir la limite en action.
- La fluidité du défilement. Pour la voir : `FOLUNA_STRESS_UI_MANUAL=1 scripts/stress-ui.sh 10000`, puis `xctrace record --template 'Time Profiler'` pendant le défilement.
