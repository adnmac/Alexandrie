# Journal des corrections

Chaque entrée : symptôme, cause, correction, et la règle à suivre ensuite.

## 2026-11-06 Menu Livre actif sans sélection (S-044)

Symptôme : sans livre sélectionné, les éléments du menu Livre restaient actifs.
Cause : les menus lisaient la sélection par `@FocusedValue` (`focusedSceneValue`) ; SwiftUI ne
reconstruit pas les `Commands` de façon fiable quand cette valeur change. La skill `swift-swiftui`
(« Menu commands ») le signalait, elle n'a pas été relue avant d'écrire S-040.
Correction : `MenuState` (un `ObservableObject`) reçoit les valeurs des menus depuis la fenêtre ;
l'`App` l'observe et les passe aux menus Livre et Kindle, qui relisent `MenuState.current` au choix.
Rule: un menu ne lit jamais l'état de l'app ni `@FocusedValue` ; il reçoit des valeurs de l'`App`,
qui observe un `ObservableObject`. Relire la skill `swift-swiftui` avant de toucher aux `Commands`.

## 2026-11-06 Page et sélection perdues au lancement (S-043)

Symptôme : après ⌘Q et relance, l'app revenait sur « Tous les livres » sans sélection.
Cause : `@SceneStorage` vit dans l'état de la fenêtre, que macOS jette au ⌘Q quand « Fermer les fenêtres
à la fermeture d'une app » est coché (le réglage par défaut, `NSQuitAlwaysKeepsWindows` absent).
Correction : page et sélection gardées dans `@AppStorage` (`lastSidebarPage`, `lastSelectedBooks`).
Rule: ce qui doit survivre au ⌘Q va dans `@AppStorage`, jamais dans `@SceneStorage` seul ; tester
la relance avec le réglage macOS par défaut.
