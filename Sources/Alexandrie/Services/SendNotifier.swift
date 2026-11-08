import AlexandrieCore
import Foundation
import UserNotifications

/// Notification quand la file d'attente est partie sur la liseuse branchée (S-052).
///
/// La permission est demandée quand un livre est mis en attente, jamais au lancement. Rien en mode test
/// (`ALEXANDRIE_STORE`) ni hors d'un bundle d'app : `UNUserNotificationCenter` y plante.
@MainActor
enum SendNotifier {
    private static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
            && AppDirectories.testStore == nil
    }

    /// À l'ajout d'un livre à la file : demande la permission une fois (le système ne redemande pas).
    static func prepare() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    /// Après l'envoi de la file : combien de livres sont arrivés, combien ont échoué.
    static func post(sent: [String], failed: Int, reader: String?) {
        guard isAvailable, let body = SendSummary.body(sent: sent, failed: failed, reader: reader) else { return }
        let content = UNMutableNotificationContent()
        content.title = SendSummary.title
        content.body = body
        let request = UNNotificationRequest(identifier: "envoi-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
