# Performances sur une grande bibliothèque

Premier test de résistance : 14 novembre 2026, Foluna 0.8.0, compilé en release, sur ce Mac.
Livres inventés (`StressData`, `StressCatalog`) :
- environ 90 % d'EPUB, dont un tiers avec couverture ;
- 2 % de PDF ;
- 5 % de copies en double ;
- 1 % de fichiers tronqués ;
- un livre sur 1 000 titré « Mémoires ».

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

   Ce qui reste, mesuré dans l'interface à 100 000 livres (`scripts/stress-ui.sh 100000`) :

   | Action | Blocage max |
   | --- | ---: |
   | Tous les livres | 0,9 à 1,1 s |
   | Récents | 1,6 s |
   | Fiche d'un livre | 0,8 s |
   | Chaque lettre tapée | 0,4 à 0,9 s |
   | Petites pages (PDF, étiquette, corbeille) | moins de 70 ms |

   La page Récents est triée par date, ce qui ne coûte presque rien, et bloque quand même 1,6 s. Le coût ne vient donc plus du tri. Il vient de SwiftUI, qui compare 100 000 éléments dans la grille (`LazyVGrid`) ou la liste (`Table`, avec `LibraryRow.rows` reconstruit à chaque passage), et de `BookGroups.make`. Pistes :
   - ne donner à la vue que la partie visible ;
   - passer la grille et la liste à AppKit (`NSCollectionView`, `NSTableView`) au-delà d'une certaine taille ;
   - garder `LibraryRow.rows` d'un rendu à l'autre.
5. **Parcours sans changement.** 11,5 s à 100 000 livres, dont un blocage de 4,7 s. Ce parcours est relancé par FSEvents à chaque changement dans les dossiers. La partie faite sur le thread principal (reconstruction de `books`, `isOffline`, `hiddenDuplicates`) est à déplacer.
6. **Lancement et fermeture à 100 000 livres.**
   - Au lancement, l'index de 68 Mo est lu sur le thread principal (0,9 s, blocage de 1,9 s).
   - À la fermeture, `saveNow` l'écrit en 0,7 s.
7. **Première indexation.** Débit d'environ 800 livres/s, en série, soit un peu plus de 2 min pour 100 000 livres. C'est acceptable, et l'extraction pourrait se faire en parallèle. Pas encore mesuré : le coût des vues pendant cette indexation, fenêtre ouverte (un `append` par livre, chacun réévaluant les vues).

## Pas encore mesuré

- La recherche dans le contenu (`ContentIndexer` : `removeFirst` et `saveState` sur le thread principal).
- La mémoire des couvertures pendant le défilement de la grille (`NSCache` sans limite).
- La fluidité du défilement. Pour la voir : `FOLUNA_STRESS_UI_MANUAL=1 scripts/stress-ui.sh 10000`, puis `xctrace record --template 'Time Profiler'` pendant le défilement.
