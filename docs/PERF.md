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
   | À la corbeille | 20 ms | 0,20 s |
   | Restaurés | 21 ms | 0,17 s |

   Avant la correction du point 2, il fallait encore 4,2 s pour restaurer à 100 000 livres : les identités étaient recalculées après la mise à la corbeille.
2. **Identités recalculées après chaque modification : corrigé en partie.**
   - Avant : `books.didSet` vidait `identityMap`, et la barre latérale relit les identités (`bookCount`). Le rendu qui suivait n'importe quelle retouche refaisait donc tout le calcul.
   - Maintenant : `LibraryStore.identities` garde le dernier résultat avec une empreinte des chemins, des titres et des auteurs (`BookGroups.identitySignature`). Les identités ne dépendent que de ces trois champs, donc une étiquette, un favori, la corbeille ou un envoi ne coûtent plus que le calcul de l'empreinte.

   | 100 000 livres | Durée |
   | --- | ---: |
   | Identités après une étiquette (avant la correction) | 3,5 à 4,3 s |
   | Identités après une étiquette (après) | 0,16 s |
   | Identités après un titre ou un auteur corrigé | 4,3 s, inchangé |

   Il reste deux pistes :
   - recalculer seulement le groupe de titres touché (`identities` traite chaque titre à part) ;
   - ou faire le calcul hors du thread principal.
3. **Même titre, auteurs différents.** `BookGroups.identities` est en O(k³) (`BookGroups.swift:79-89`). Quelques centaines de « Sans titre », « Mémoires » ou « Poèmes » suffisent à figer l'app. Le banc d'essai `sameTitle` échoue volontairement tant que ce n'est pas corrigé.
4. **Coût fixe de chaque rendu.** Entre 0,3 et 1,3 s par action à 10 000 livres. `ContentView` et `SidebarView` refont à chaque passage :
   - `visibleBooks` (sans cache) ;
   - les groupes ;
   - le tri ;
   - les listes auteurs, séries, étiquettes et genres ;
   - les compteurs.

   Piste : calculer ces listes une fois par changement de `books`, dans le store ou dans un `LibraryFilter` du cœur, comme le propose `architecture-review-2026-11-06.md`.
5. **Parcours sans changement.** 11,5 s à 100 000 livres, dont un blocage de 4,7 s. Ce parcours est relancé par FSEvents à chaque changement dans les dossiers. La partie faite sur le thread principal (reconstruction de `books`, `isOffline`, `hiddenDuplicates`) est à déplacer.
6. **Lancement et fermeture à 100 000 livres.**
   - Au lancement, l'index de 68 Mo est lu sur le thread principal (0,9 s, blocage de 1,9 s).
   - À la fermeture, `saveNow` l'écrit en 0,7 s.
7. **Première indexation.** Débit d'environ 800 livres/s, en série, soit un peu plus de 2 min pour 100 000 livres. C'est acceptable, et l'extraction pourrait se faire en parallèle. Pas encore mesuré : le coût des vues pendant cette indexation, fenêtre ouverte (un `append` par livre, chacun réévaluant les vues).

## Pas encore mesuré

- La recherche dans le contenu (`ContentIndexer` : `removeFirst` et `saveState` sur le thread principal).
- La mémoire des couvertures pendant le défilement de la grille (`NSCache` sans limite).
- La fluidité du défilement. Pour la voir : `FOLUNA_STRESS_UI_MANUAL=1 scripts/stress-ui.sh 10000`, puis `xctrace record --template 'Time Profiler'` pendant le défilement.
