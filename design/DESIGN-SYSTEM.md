# Système de design de Foluna

Foluna garde l'apparence d'Apple. Les jetons ne couvrent que ce que le système ne fournit pas.
Ils vivent dans `Sources/Foluna/UI/`. Les vues utilisent les jetons, jamais de valeurs brutes.
Règles générales du Mac : skill `mac-design`. Espacements et alignement : skill `layout-grid`.

## Couleurs — `Theme.swift`

Pas de couleur de marque : l'accent est celui du Mac (Réglages Système > Apparence).
L'app n'a donc pas de sélecteur d'accent ni de réglage clair/sombre : elle suit le Mac.

| Jeton | Quand |
| --- | --- |
| `Palette.accent` | contour de sélection d'une couverture, zone de dépôt ; ailleurs, `.tint` et les contrôles système |
| `Palette.onAccent` | texte ou symbole posé sur un remplissage d'accent |
| `Palette.success` | fait, envoyé, présent sur la Kindle, Kindle branchée |
| `Palette.warning` | à vérifier, corrections proposées, échec partiel, livres à ranger |
| `Palette.danger` | erreur qui bloque l'action |
| `Palette.info` | en attente d'envoi, mise à jour disponible, livres à envoyer (suit l'accent) |
| `Palette.favorite` | étoile pleine d'un livre favori (couverture, liste, fiche) ; l'étoile vide reste `.secondary` |

- Jamais `.blue`, `.green`, `.orange`, `.red`, `.yellow` ni un hexadécimal dans une vue : un jeton.
- Une couleur d'état va toujours avec un symbole ou un mot.
- Texte : `.primary`, `.secondary`, `.tertiary`. Fonds : système. Jamais de blanc ou de noir fixe dans
  l'interface (seule exception : le texte des couvertures générées, qui sont du contenu).
- Ne jamais copier une couleur sémantique ailleurs que dans son rôle (`.separator` en texte, etc.).
- Une nouvelle couleur propre à l'app a quatre valeurs : clair, sombre, et Contraste élevé pour chacun.
  Les couleurs système des jetons actuels les ont déjà.

## Surfaces — `Surfaces.swift`

| Jeton | Quand |
| --- | --- |
| `.banner(tint)` | bandeau en haut d'une page : commandes `.small`, marge `Space.md`, fond teinté à 12 % ; suivi d'un `Divider` |
| `Surface.coverShadow` (+ rayon, décalage) | ombre d'une couverture, seulement sur les couvertures |

- Les pastilles neutres (format, « principal », nombre de fichiers) : `.background(.quaternary, in: Capsule())`.
- Pas de verre (Liquid Glass) sur le contenu : couvertures, lignes, fiches. Le verre est pour les barres.
- Petite action posée dans une ligne (relevé de notes) : `.buttonStyle(.hover)`, qui répond au survol (fond `.quaternary`, `.tertiary` à l'appui, curseur en main) ; un bouton `.borderless` seul ne montre rien au survol.

## Rayons — `Radius.swift`

| Jeton | Valeur | Quand |
| --- | --- | --- |
| `Radius.cover` | 4 | couverture, et tout ce qui se pose dessus (contour de sélection) |
| `Radius.field` | 4 | cadre dessiné autour d'un `TextEditor` |
| `Radius.hover` | 5 | fond de survol d'un bouton sans bordure (`.buttonStyle(.hover)`) |
| `Radius.dropZone` | 12 | contour pointillé de dépôt de fichiers sur la fenêtre |

- Angles imbriqués concentriques : rayon intérieur = rayon extérieur - marge.
- Les contrôles, feuilles et fenêtres gardent les rayons du système.

## Animations — `Motion.swift`

| Jeton | Quand |
| --- | --- |
| `Motion.quick` | bascule courte : section de la barre latérale repliée ou dépliée |
| `Motion.run(animation) { … }` | à la place de `withAnimation` : rien n'anime sous Réduire les animations |

- Jamais `withAnimation(.easeInOut(duration:))` ni une durée brute dans une vue.
- La recherche et les changements de page n'animent pas : la vitesse prime.
- Le survol ne déplace jamais une sélection ; seuls un clic ou une touche le font.
- On n'anime pas la première mise en page d'une vue.

## Tailles — `Layout.swift` et `WindowBehavior.swift`

| Jeton | Quand |
| --- | --- |
| `Layout.sheetNarrow` 360 | feuille d'une question ou d'un nom seul |
| `Layout.sheet` 480 | feuille ordinaire : nommer une liseuse, corriger un livre sur la Kindle |
| `Layout.sheetWide` 640 | feuille à deux colonnes ou avec aperçu |
| `Layout.settingsWidth` 520 | chaque onglet des réglages |
| `.fitsContent()` | `Form` d'un onglet des réglages ou d'une feuille : la hauteur suit le contenu, défile au-delà de 640 pt (`Layout.maxPanelHeight`) |
| `.noInitialFocus()` | chaque feuille et la fenêtre des réglages : pas d'anneau de focus à l'ouverture |

- Les réglages sont en onglets (`SettingsTab` : Général, Bibliothèque, Kindle), rouverts sur le dernier
  utilisé ; la scène a `.windowResizability(.contentSize)`. Un onglet qui passerait 640 pt se coupe en deux.
- La vérification du catalogue (`CatalogReviewSheet`) garde sa grande feuille à deux volets (960 pt
  minimum) : une liste et une fiche côte à côte n'entrent pas dans 640 pt.

## Espacements — `Grid.swift`

Échelle `Space` sur 4 pt, sondes de mise en page : voir `CLAUDE.md` et le skill `layout-grid`.

## Vérification

Aucun résultat hors de `Sources/Foluna/UI/` :

    grep -rnE 'cornerRadius: [0-9]{1,2}\b|duration: [0-9]|\.spring\(response|\.snappy\b|\.easeInOut|\.easeOut\(|Color\(hex:|Color\(red:|\.(green|orange|red|blue)\b|accentColor' Sources/ | grep -v 'Sources/Foluna/UI/'
