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

## 2026-11-06 Glisser vers le bureau sans fichier (S-050)

Symptôme : une carte glissée sur le bureau ne donnait pas de copie du livre. Avec l'ancienne version,
un fichier texte « alexandrie-livres:… » ; avec la `FileRepresentation` de S-050, toujours pas de fichier.
Cause : le Finder n'accepte pas la `FileRepresentation` d'un `Transferable` venu d'une autre app ;
il attend l'adresse d'un fichier (`public.file-url`).
Correction : `BookDragItem` exporte l'adresse d'une copie temporaire du livre (clone APFS), jamais le
fichier de la bibliothèque, que le Finder pourrait déplacer sur le même disque. La liste des livres pour
les liseuses passe en premier, visible de l'app seule.
Rule: vers le Finder, exporter une URL de fichier, et toujours celle d'une copie ; vérifier le glisser
à la main avec la version qui vient d'être construite (relancer l'app avant d'essayer).

## 2026-11-06 Action Raccourcis visible mais muette (S-053)

Symptôme : sous macOS 27.2, « Envoyer à la Kindle » apparaît dans Raccourcis, mais le choix du livre
ne s'ouvre pas et l'exécution échoue avec « LinkDaemon.ProcessRegistry.Errors erreur 0 ».
Cause : `linkd` identifie l'app par le team ID de sa signature. « Alexandrie Dev » (auto-signé) n'en a
pas : `linkd` journalise « Unable to get teamId » et coupe la connexion de l'app (« Unable to
re-register with Process Instance Registry »). Les métadonnées seules suffisent à montrer l'action,
pas à l'exécuter.
Correction : `scripts/bundle.sh` signe d'abord avec un certificat Apple Development (gratuit, créé par
Xcode). Le trousseau doit contenir l'intermédiaire Apple WWDR G3, sinon `codesign` échoue avec
`errSecInternalComponent`.
Rule: pour App Intents, vérifier `codesign -dv` (TeamIdentifier présent) et chercher « Registered
process » dans `log show --predicate 'process == "Alexandrie"'` ; essayer l'action en l'exécutant,
pas seulement en la voyant dans Raccourcis.
