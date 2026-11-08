import AlexandrieCore
import Foundation

/// Services de l'app, partagés par la fenêtre et les actions Raccourcis (qui n'ont pas de vue).
@MainActor
final class AppServices {
    static let shared = AppServices()

    let library = LibraryStore()
    let kindle = KindleMonitor()
    let updates = UpdateMonitor()
    lazy var reading = ReadingStore(directories: library.directories)
    lazy var researches = ResearchStore(directories: library.directories, kindle: kindle)
    lazy var contentIndexer = ContentIndexer(directories: library.directories)
    /// Catalogues OPDS ; en mode capture, un catalogue d'exemple sans réseau (`SeedData.opdsClient`).
    lazy var opds = OPDSStore(directories: library.directories, library: library,
                              client: Snapshot.directory != nil ? SeedData.opdsClient : OPDSClient())

    private init() {}
}
