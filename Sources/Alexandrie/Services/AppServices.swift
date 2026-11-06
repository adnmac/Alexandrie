import Foundation

/// Services de l'app, partagés par la fenêtre et les actions Raccourcis (qui n'ont pas de vue).
@MainActor
final class AppServices {
    static let shared = AppServices()

    let library = LibraryStore()
    let kindle = KindleMonitor()
    let updates = UpdateMonitor()

    private init() {}
}
