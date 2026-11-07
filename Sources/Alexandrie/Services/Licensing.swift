import AlexandrieCore
import AppKit
import CryptoKit
import Foundation
import Observation

/// Licence et essai (docs/VENTE.md) : toutes les fonctions pendant 14 jours, puis l'envoi à la Kindle demande
/// une clé de licence. Sans clé, la bibliothèque, la lecture, les notes et la recherche restent disponibles.
@MainActor @Observable
final class Licensing {
    static let shared = Licensing()

    /// Clé publique des licences ; la clé privée est dans le trousseau du vendeur (`scripts/licence.swift`).
    static let publicKey = try! Curve25519.Signing.PublicKey(
        rawRepresentation: Data(base64Encoded: "HD7MXbDfOwxA2HCV6RVDbQ4hVYtoLx+REQqdRH2aog8=")!)

    private(set) var license: License?
    let trial: Trial
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    /// Clé publique qui vérifie les licences (une autre seulement dans le selftest).
    @ObservationIgnored private let verifier: Curve25519.Signing.PublicKey

    private static let keyKey = "licenseKey"
    private static let trialKey = "trialStart"

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         publicKey: Curve25519.Signing.PublicKey = Licensing.publicKey) {
        self.defaults = defaults
        self.now = now
        verifier = publicKey
        // Début de l'essai : enregistré au premier lancement, jamais déplacé ensuite.
        if let start = defaults.object(forKey: Self.trialKey) as? Date {
            trial = Trial(start: start)
        } else {
            let start = now()
            defaults.set(start, forKey: Self.trialKey)
            trial = Trial(start: start)
        }
        license = defaults.string(forKey: Self.keyKey).flatMap { LicenseKey.verify($0, publicKey: publicKey) }
    }

    var remainingTrialDays: Int { trial.remainingDays(now: now()) }

    /// L'envoi à la Kindle est permis : licence, essai en cours, ou données de test (selftest, captures).
    var canSend: Bool {
        license != nil || !trial.isOver(now: now()) || (AppDirectories.testStore != nil && !Self.enforcedInTests)
    }

    /// Le selftest vérifie le blocage avec ses propres réglages ; ailleurs, les données de test ne sont pas bridées.
    nonisolated(unsafe) static var enforcedInTests = false

    /// Rappel à montrer dans la fenêtre principale : les trois derniers jours d'essai, puis l'essai terminé.
    var showsReminder: Bool { license == nil && remainingTrialDays <= 3 }

    /// Active une clé ; false si elle n'est pas valide.
    @discardableResult
    func activate(_ key: String) -> Bool {
        guard let valid = LicenseKey.verify(key, publicKey: verifier) else { return false }
        defaults.set(key.components(separatedBy: .whitespacesAndNewlines).joined(), forKey: Self.keyKey)
        license = valid
        return true
    }

    /// Retire la licence de ce Mac (pour la déplacer sur un autre).
    func deactivate() {
        defaults.removeObject(forKey: Self.keyKey)
        license = nil
    }

    /// Message d'un envoi refusé.
    static let sendRefused = "L'essai de 14 jours est terminé : l'envoi à la Kindle demande une licence. Saisissez votre clé dans Réglages > Licence. La bibliothèque, la lecture et les notes restent disponibles."

    // MARK: Liens du site (Info.plist, écrits par scripts/bundle.sh)

    /// Page d'achat (`ALEXANDRIE_STORE_URL`).
    var storeURL: URL? { Self.url("AlexandrieStoreURL") }
    /// Conditions de vente (`ALEXANDRIE_TERMS_URL`).
    var termsURL: URL? { Self.url("AlexandrieTermsURL") }
    /// Politique de confidentialité (`ALEXANDRIE_PRIVACY_URL`).
    var privacyURL: URL? { Self.url("AlexandriePrivacyURL") }

    private static func url(_ key: String) -> URL? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }
}
