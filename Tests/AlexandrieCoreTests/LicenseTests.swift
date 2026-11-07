import CryptoKit
import Foundation
import Testing
@testable import AlexandrieCore

@Suite struct LicenseTests {
    let key = Curve25519.Signing.PrivateKey()

    @Test func signedKeyIsAcceptedAndShowsItsLicense() throws {
        let license = License(id: "CMD-1042", name: "Léa Fontaine", issued: "2026-11-07")
        let text = try LicenseKey.make(license, privateKey: key)
        #expect(text.hasPrefix("ALX1-"))
        #expect(LicenseKey.verify(text, publicKey: key.publicKey) == license)
        // Collée depuis un e-mail : coupée en lignes, avec des espaces.
        let wrapped = stride(from: 0, to: text.count, by: 40).map { i in
            String(text.dropFirst(i).prefix(40)) }.joined(separator: "\n  ")
        #expect(LicenseKey.verify(wrapped, publicKey: key.publicKey) == license)
    }

    @Test func forgedOrForeignKeysAreRefused() throws {
        let license = License(id: "CMD-1", name: "A", issued: "2026-11-07")
        let text = try LicenseKey.make(license, privateKey: key)
        // Signée par une autre clé privée.
        let other = try LicenseKey.make(license, privateKey: Curve25519.Signing.PrivateKey())
        #expect(LicenseKey.verify(other, publicKey: key.publicKey) == nil)
        // Licence modifiée (autre nom), signature d'origine.
        let parts = text.dropFirst(5).split(separator: ".")
        let forged = License(id: "CMD-1", name: "Pirate", issued: "2026-11-07")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let tampered = "ALX1-" + LicenseKey.base64url(try encoder.encode(forged)) + "." + parts[1]
        #expect(LicenseKey.verify(tampered, publicKey: key.publicKey) == nil)
        for junk in ["", "ALX1-", "ALX1-abc.def", "XYZ" + text.dropFirst(3), String(text.dropLast(4))] {
            #expect(LicenseKey.verify(junk, publicKey: key.publicKey) == nil)
        }
    }

    @Test func trialLastsFourteenDays() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 22))!
        let trial = Trial(start: start)
        func day(_ d: Int) -> Date { calendar.date(byAdding: .day, value: d, to: start)! }
        #expect(trial.remainingDays(now: start, calendar: calendar) == 14)
        #expect(trial.remainingDays(now: day(1), calendar: calendar) == 13)
        #expect(trial.remainingDays(now: day(13), calendar: calendar) == 1)
        #expect(trial.remainingDays(now: day(14), calendar: calendar) == 0 && trial.isOver(now: day(30)))
        // Horloge reculée : l'essai ne s'allonge pas au-delà de 14 jours.
        #expect(trial.remainingDays(now: day(-5), calendar: calendar) == 14)
    }
}
