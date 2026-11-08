import Testing
@testable import AlexandrieCore

struct SendSummaryTests {
    @Test("Texte de la notification d'envoi", arguments: [
        ([], 0, "Kindle de Léa", nil),
        (["Le Port des brumes"], 0, "Kindle de Léa", "« Le Port des brumes » envoyé sur « Kindle de Léa »"),
        (["Le Port des brumes"], 0, nil, "« Le Port des brumes » envoyé sur la liseuse"),
        (["A", "B", "C"], 0, "Kindle de Léa", "3 livres envoyés sur « Kindle de Léa »"),
        (["A", "B"], 1, "Kindle de Léa", "2 livres envoyés, 1 échec"),
        (["A"], 2, nil, "1 livre envoyé, 2 échecs"),
        ([], 1, nil, "Échec de l'envoi de 1 livre"),
        ([], 3, "Kindle de Léa", "Échec de l'envoi de 3 livres"),
    ] as [([String], Int, String?, String?)])
    func body(sent: [String], failed: Int, reader: String?, expected: String?) {
        #expect(SendSummary.body(sent: sent, failed: failed, reader: reader) == expected)
    }
}
