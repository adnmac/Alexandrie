import CryptoKit
import Foundation

/// Licence d'Alexandrie : délivrée par le site de vente, vérifiée par l'app sans serveur.
/// Le site (ou `scripts/licence.swift`) signe la licence avec la clé privée ; l'app la vérifie avec la clé
/// publique qu'elle contient. Personne ne peut fabriquer une clé valide sans la clé privée.
public struct License: Codable, Equatable, Sendable {
    /// Numéro de la licence (celui de la commande, par exemple).
    public var id: String
    /// Nom affiché dans l'app (« Licence de … ») ; seule donnée personnelle de la clé, facultative.
    public var name: String
    /// Date de délivrance, « 2026-11-07 ».
    public var issued: String

    public init(id: String, name: String, issued: String) {
        self.id = id
        self.name = name
        self.issued = issued
    }
}

public enum LicenseKey {
    /// Version du format, en tête de chaque clé.
    public static let prefix = "ALX1-"

    /// Clé : « ALX1- » + licence (JSON, base64url) + « . » + signature Ed25519 (base64url).
    public static func make(_ license: License, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let payload = try encoder.encode(license)
        let signature = try privateKey.signature(for: payload)
        return prefix + base64url(payload) + "." + base64url(signature)
    }

    /// La licence, si la clé est bien signée par la clé privée qui correspond à `publicKey` ; nil sinon.
    /// Les blancs et retours à la ligne collés avec la clé (e-mail) sont ignorés.
    public static func verify(_ key: String, publicKey: Curve25519.Signing.PublicKey) -> License? {
        let compact = key.components(separatedBy: .whitespacesAndNewlines).joined()
        guard compact.hasPrefix(prefix) else { return nil }
        let parts = compact.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let payload = data(base64url: String(parts[0])),
              let signature = data(base64url: String(parts[1])),
              publicKey.isValidSignature(signature, for: payload) else { return nil }
        return try? JSONDecoder().decode(License.self, from: payload)
    }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func data(base64url: String) -> Data? {
        var s = base64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

/// Période d'essai (achat après essai) : toutes les fonctions pendant `days` jours à partir du premier lancement.
public struct Trial: Equatable, Sendable {
    public static let days = 14
    public let start: Date

    public init(start: Date) {
        self.start = start
    }

    /// Jours d'essai restants (0 une fois terminé), le jour du premier lancement compté.
    public func remainingDays(now: Date = Date(), calendar: Calendar = .current) -> Int {
        let elapsed = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: now)).day ?? 0
        return max(0, Self.days - max(0, elapsed))
    }

    public func isOver(now: Date = Date()) -> Bool { remainingDays(now: now) == 0 }
}
