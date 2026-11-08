import AlexandrieCore
import Foundation

/// Services de l'app, partagés par la fenêtre et les actions Raccourcis (qui n'ont pas de vue).
@MainActor
final class AppServices {
    static let shared = AppServices()

    let library: LibraryStore
    let kindle: KindleMonitor
    let updates = UpdateMonitor()
    /// Sauvegarde dans un dossier choisi (iCloud Drive…), avec la restauration appliquée à ce lancement.
    let backups: BackupMonitor
    lazy var reading = ReadingStore(directories: library.directories)
    lazy var researches = ResearchStore(directories: library.directories, kindle: kindle)
    lazy var contentIndexer = ContentIndexer(directories: library.directories)
    /// Catalogues OPDS ; en mode capture, un catalogue d'exemple sans réseau (`SeedData.opdsClient`).
    lazy var opds = OPDSStore(directories: library.directories, library: library,
                              client: Snapshot.directory != nil ? SeedData.opdsClient : OPDSClient())

    private init() {
        // Restauration demandée avant la relance : appliquée avant que la bibliothèque et les notes soient lues.
        let directories = AppDirectories()
        let restored = PendingRestore.apply(directories)
        library = LibraryStore()
        kindle = KindleMonitor()
        backups = BackupMonitor(directories: directories, library: library, restoreResult: restored)
    }
}
