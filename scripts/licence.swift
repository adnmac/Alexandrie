#!/usr/bin/env swift
// Clés de licence d'Alexandrie (docs/VENTE.md).
//
//   swift scripts/licence.swift init                  crée la paire de clés : la privée dans le trousseau,
//                                                     la publique affichée (à mettre dans Licensing.swift)
//   swift scripts/licence.swift "Léa Fontaine" CMD-42 délivre une clé pour cette commande
//   swift scripts/licence.swift exporter              affiche la clé privée (sauvegarde, site de vente)
//
// La clé privée ne quitte jamais le trousseau, sauf par « exporter ». Le format est celui de
// AlexandrieCore/Licence/LicenseKey.swift : « ALX1- » + licence JSON (base64url) + « . » + signature Ed25519.
import CryptoKit
import Foundation

let service = "be.adnmac.alexandrie.licence"
let account = "cle-privee"

@discardableResult
func security(_ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

func storedKey() -> Curve25519.Signing.PrivateKey? {
    let found = security(["find-generic-password", "-s", service, "-a", account, "-w"])
    guard found.status == 0, let raw = Data(base64Encoded: found.output) else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}

func base64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "init":
    if let key = storedKey() {
        print("Une clé privée existe déjà dans le trousseau. Clé publique :")
        print(key.publicKey.rawRepresentation.base64EncodedString())
        exit(0)
    }
    let key = Curve25519.Signing.PrivateKey()
    let added = security(["add-generic-password", "-s", service, "-a", account,
                          "-l", "Alexandrie : clé privée des licences", "-w", key.rawRepresentation.base64EncodedString()])
    guard added.status == 0 else { fail("Trousseau inaccessible : la clé n'a pas été créée.") }
    print("Clé privée enregistrée dans le trousseau (« \(service) »). Faites-en une sauvegarde : sans elle, plus aucune")
    print("clé ne pourra être délivrée pour les apps déjà vendues. Clé publique, à mettre dans Licensing.swift :")
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "exporter":
    guard let key = storedKey() else { fail("Aucune clé privée dans le trousseau : lancez d'abord « init ».") }
    print("Clé privée (32 octets, base64) — à garder secrète :")
    print(key.rawRepresentation.base64EncodedString())
case let name? where args.count == 2:
    guard let key = storedKey() else { fail("Aucune clé privée dans le trousseau : lancez d'abord « init ».") }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    // Même ordre de champs que l'app (clés triées) : id, issued, name.
    let license: [String: String] = ["id": args[1], "name": name, "issued": formatter.string(from: Date())]
    let payload = try JSONSerialization.data(withJSONObject: license, options: [.sortedKeys])
    let signature = try key.signature(for: payload)
    print("ALX1-" + base64url(payload) + "." + base64url(signature))
default:
    fail("Usage : swift scripts/licence.swift init | exporter | \"Nom de l'acheteur\" NUMERO-DE-COMMANDE")
}
