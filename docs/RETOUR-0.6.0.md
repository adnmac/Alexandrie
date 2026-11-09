# Revenir à la version 0.6.0

La version qui ajoute PRC, FB2, CBZ et TXT est faite pour qu'un retour à la 0.6.0 ne perde rien.

## Ce qui le permet

- `library.json` ne contient que des formats que la 0.6.0 sait lire (EPUB, MOBI, AZW3, AZW, PDF). Les livres des
  nouveaux formats sont dans `library.formats.json`, que la 0.6.0 ignore (`LibraryIndex.formatsFile`).
  Sans cela, la 0.6.0 jugerait l'index illisible, le mettrait de côté (`library.corrupt-…json`) et réindexerait la
  bibliothèque sans les corrections, étagères, corbeille ni historique d'envoi.
- `library.formats.json` est copié avec l'index : copie du jour dans `Sauvegardes/` et sauvegarde hors du Mac.
- Un index qui contient un format inconnu (écrit par une version plus récente) n'est plus jugé illisible à partir
  de cette version : ses entrées sont gardées telles quelles.
- Le réglage `disabledFormats` et l'onglet Réglages › Formats sont ignorés par la 0.6.0.

## Marche à suivre

1. Quitter Foluna.
2. Par précaution, copier le dossier `~/Library/Application Support/Alexandrie/` ailleurs.
3. Télécharger la release `v0.6.0` sur GitHub (`adnmac/Foluna`, page Releases) et l'installer à la place de
   l'app actuelle (la 0.6.0 porte encore le nom d'Alexandrie : supprimer `Foluna.app` d'Applications).
4. Lancer la 0.6.0 : bibliothèque, corrections, notes et réglages sont là.

## Ce que l'on voit sous la 0.6.0

- Les livres PRC, FB2, CBZ et TXT n'apparaissent pas. Leurs fichiers restent (dans `Imports/` ou dans les dossiers
  de livres) et leurs entrées restent dans `library.formats.json`.
- La 0.6.0 range leurs couvertures, conversions et copies de lecture parmi les fichiers inutiles et les efface.
  Au retour à une version récente, les couvertures sont relues dans les livres (`restoreMissingCovers`), les
  conversions et copies de lecture refaites à la demande.
- La sauvegarde hors du Mac de la 0.6.0 écrit dans « Sauvegarde Alexandrie » (le nom d'avant Foluna) : les copies
  déjà faites dans « Sauvegarde Foluna » restent à côté, intactes.

## Revenir ensuite à la version récente

Réinstaller la version récente : elle relit `library.json` et `library.formats.json` ; les livres des nouveaux
formats reviennent avec leurs corrections. Les corrections faites sous la 0.6.0 sur les autres livres sont gardées.
