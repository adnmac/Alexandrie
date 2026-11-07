# Vendre Alexandrie

Alexandrie se vend sur le site e-commerce de l'éditeur. L'app n'a ni Developer ID ni notarisation (choix du 7 novembre 2026). L'acheteur l'autorise donc une fois dans les Réglages de macOS. La procédure est expliquée dans le dépôt des versions et dans les conditions de vente.

## Ce que l'acheteur vit

1. Il télécharge l'app depuis le [dépôt public des versions](https://github.com/adnmac/Alexandrie-versions/releases/latest) ou depuis le site, puis l'installe.
2. **Essai de 14 jours** : tout fonctionne.
3. Les trois derniers jours, un bandeau l'avertit dans la fenêtre principale (« Acheter… », « Saisir la clé… »).
4. **Après l'essai**, l'envoi à la Kindle est refusé avec un message. La bibliothèque, la lecture, les notes, les thématiques et la recherche restent disponibles.
5. Il achète sur le site et reçoit une **clé de licence** par e-mail. Il la colle dans **Réglages > Licence**, et tout est débloqué, sans connexion Internet.

## Les clés de licence

Une clé ressemble à `ALX1-eyJpZCI6IkNNRC00MiIs…` (environ 150 caractères). Elle contient trois informations : le numéro de commande (`id`), le nom de l'acheteur (`name`, affiché dans l'app) et la date (`issued`). Elle est **signée** avec une clé privée Ed25519. L'app la vérifie avec la clé publique qu'elle contient (`Sources/Alexandrie/Services/Licensing.swift`). Personne ne peut fabriquer une clé sans la clé privée, et l'app n'a besoin d'aucun serveur.

**La clé privée est dans le trousseau macOS** de ce Mac : élément « Alexandrie : clé privée des licences », service `be.adnmac.alexandrie.licence`.

- **Faites-en une sauvegarde** (gestionnaire de mots de passe) : `swift scripts/licence.swift exporter`. Sans elle, plus aucune clé ne peut être délivrée pour cette version de l'app.
- **Ne la publiez jamais.** Avec elle, n'importe qui fabrique des clés valides. Si elle fuit, il faut créer une nouvelle paire et publier une version de l'app avec la nouvelle clé publique. Les clés déjà vendues ne valent plus alors pour cette version : prévenez les acheteurs et renvoyez-leur une clé.

### Délivrer une clé à la main

```bash
swift scripts/licence.swift "Léa Fontaine" CMD-1042
```

Copiez la clé affichée dans l'e-mail de confirmation de commande.

### Délivrer les clés automatiquement depuis le site

Si le site est en PHP (WooCommerce, PrestaShop…), il peut signer la clé à la validation du paiement, avec la bibliothèque `sodium` intégrée à PHP. La clé privée exportée (32 octets en base64) est la **graine** de la paire de clés. Gardez-la dans la configuration du serveur, jamais dans un fichier public.

```php
function alexandrie_cle(string $commande, string $nom, string $graineBase64): string {
    $paire = sodium_crypto_sign_seed_keypair(base64_decode($graineBase64));
    $secrete = sodium_crypto_sign_secretkey($paire);
    // Clés triées par ordre alphabétique, comme dans l'app ; l'app ne vérifie que la signature de ces octets.
    $licence = json_encode(['id' => $commande, 'issued' => date('Y-m-d'), 'name' => $nom],
                           JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    $b64url = fn(string $d) => rtrim(strtr(base64_encode($d), '+/', '-_'), '=');
    return 'ALX1-' . $b64url($licence) . '.' . $b64url(sodium_crypto_sign_detached($licence, $secrete));
}
```

Avant la mise en ligne, vérifiez une clé produite par le site : collez-la dans Réglages > Licence d'une app de test.

## Publier une version

Le code est dans un dépôt **privé** (`adnmac/Alexandrie`). Les versions vont dans le dépôt **public** `adnmac/Alexandrie-versions`, que l'app consulte pour ses mises à jour. Elle ne lui envoie rien d'autre que la demande de la dernière version.

```bash
ALEXANDRIE_STORE_URL=https://votre-site.be/alexandrie \
ALEXANDRIE_TERMS_URL=https://votre-site.be/alexandrie/conditions \
ALEXANDRIE_PRIVACY_URL=https://votre-site.be/alexandrie/confidentialite \
ALEXANDRIE_SUPPORT_EMAIL=support@votre-site.be \
scripts/release.sh 0.6.0
```

Ces quatre adresses sont écrites dans l'app :
- page d'achat : boutons « Acheter… » ;
- conditions et confidentialité : liens dans Réglages > Licence ;
- adresse d'assistance : bouton « Envoyer par e-mail… » des rapports de plantage.

Sans elles, les boutons correspondants n'apparaissent pas.

## TVA et comptabilité (à vérifier avec votre comptable)

- Une licence téléchargée est un **service fourni par voie électronique**. Pour un particulier d'un autre pays de l'UE, la TVA de son pays s'applique, déclarée par le guichet unique **OSS**, dès que vos ventes à l'étranger dans l'UE dépassent 10 000 € par an. En dessous, la TVA belge peut s'appliquer.
- Sous le **régime de la franchise** des petites entreprises (Belgique), vous ne facturez pas de TVA belge. Les règles des ventes à l'étranger restent à vérifier.
- Chaque vente donne une facture ou un ticket, que votre site produit en principe.

## Textes à publier sur le site

Modèles à compléter et à faire relire (`docs/legal/`) :
- [Conditions générales de vente et de licence](legal/conditions-de-vente.md) ;
- [Mentions légales](legal/mentions-legales.md) ;
- [Politique de confidentialité](legal/confidentialite.md).
