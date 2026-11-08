import AlexandrieCore
import AppKit
import Foundation
import Observation

/// Sauvegarde automatique dans un dossier choisi (iCloud Drive, disque externe) : une fois par jour,
/// vérifiée chaque heure, et à la demande. La restauration est appliquée au lancement suivant (`PendingRestore`).
///
/// Avec `ALEXANDRIE_STORE` (self-test, captures), les réglages restent en mémoire : jamais de sauvegarde
/// des données de test dans le dossier de l'utilisateur, ni de changement de ses réglages.
@MainActor @Observable
final class BackupMonitor {
    enum Status: Equatable {
        case idle, running
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var snapshots: [ExternalBackup.Snapshot] = []
    /// Résultat de la restauration appliquée à ce lancement, s'il y en a eu une.
    private(set) var restoreMessage: String?

    @ObservationIgnored private let directories: AppDirectories
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var memory: [String: Any] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?

    static let folderKey = "externalBackupFolder"
    static let enabledKey = "externalBackupEnabled"
    static let lastKey = "externalBackupLast"
    /// Une sauvegarde par jour : au-delà de 20 h, la suivante est due (vérifié chaque heure).
    static let interval: TimeInterval = 20 * 3600

    init(directories: AppDirectories, library: LibraryStore, restoreResult: Result<URL, any Error>? = nil) {
        self.directories = directories
        self.library = library
        defaults = AppDirectories.testStore == nil ? .standard : nil
        switch restoreResult {
        case .success?: restoreMessage = "Sauvegarde restaurée à ce lancement ; l'état d'avant est dans le dossier Sauvegardes de l'app."
        case .failure(let error)?: restoreMessage = "Restauration impossible : \(error.localizedDescription)"
        case nil: break
        }
    }

    // MARK: - Réglages

    private func value(_ key: String) -> Any? { defaults?.object(forKey: key) ?? memory[key] }
    private func store(_ value: Any?, _ key: String) {
        if let defaults { defaults.set(value, forKey: key) } else { memory[key] = value }
    }

    /// Dossier choisi ; la sauvegarde va dans son sous-dossier « Sauvegarde Alexandrie ».
    var folder: URL? {
        get {
            access(keyPath: \.folder)
            return (value(Self.folderKey) as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        set {
            withMutation(keyPath: \.folder) { store(newValue?.path, Self.folderKey) }
            refresh()
        }
    }

    var isEnabled: Bool {
        get { access(keyPath: \.isEnabled); return value(Self.enabledKey) as? Bool ?? false }
        set { withMutation(keyPath: \.isEnabled) { store(newValue, Self.enabledKey) } }
    }

    private(set) var lastBackupAt: Date? {
        get { access(keyPath: \.lastBackupAt); return value(Self.lastKey) as? Date }
        set { withMutation(keyPath: \.lastBackupAt) { store(newValue, Self.lastKey) } }
    }

    /// iCloud Drive, s'il est activé sur ce Mac.
    static var iCloudDrive: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Le dossier choisi est dans iCloud Drive.
    var isInICloud: Bool {
        guard let folder, let icloud = Self.iCloudDrive else { return false }
        return folder.standardizedFileURL.path.hasPrefix(icloud.standardizedFileURL.path)
    }

    /// Le dossier choisi est joignable (un disque externe peut être débranché).
    var isFolderAvailable: Bool {
        guard let folder else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Sauvegarde

    /// Vérifie chaque heure si la sauvegarde du jour est due (première vérification une minute après le lancement).
    func start() {
        guard loop == nil else { return }
        refresh()
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                await self?.backUpIfDue()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    var isDue: Bool {
        guard isEnabled, folder != nil, status != .running else { return false }
        return lastBackupAt.map { Date().timeIntervalSince($0) >= Self.interval } ?? true
    }

    func backUpIfDue() async {
        if isDue { await backUpNow() }
    }

    /// Enregistre la bibliothèque, puis copie les données hors du thread principal.
    func backUpNow() async {
        guard let folder, status != .running else { return }
        status = .running
        library.saveNow()
        // L'index est écrit sur une file série : on lui laisse le temps de finir.
        try? await Task.sleep(for: .milliseconds(300))
        let directories = directories
        let result = await Task.detached(priority: .utility) {
            Result { try ExternalBackup.backUp(directories, to: folder) }
        }.value
        switch result {
        case .success:
            lastBackupAt = Date()
            status = .idle
        case .failure(let error):
            status = .failed(error.localizedDescription)
        }
        refresh()
    }

    /// Relit la liste des copies datées.
    func refresh() {
        guard let folder else { snapshots = []; return }
        Task {
            let list = await Task.detached(priority: .utility) { ExternalBackup.snapshots(in: folder) }.value
            snapshots = list
        }
    }

    // MARK: - Restauration

    /// Note la restauration et relance l'app : elle est appliquée avant que les données soient relues.
    func restore(_ snapshot: ExternalBackup.Snapshot) {
        guard let folder else { return }
        do {
            try PendingRestore(snapshot: snapshot.url, destination: folder).schedule(directories)
        } catch {
            status = .failed("Restauration impossible : \(error.localizedDescription)")
            return
        }
        guard AppDirectories.testStore == nil else { return }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? shell.run()
        NSApp.terminate(nil)
    }
}
