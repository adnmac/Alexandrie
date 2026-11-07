import AlexandrieCore
import AppKit
import Foundation
import Observation

/// Lecture dans l'app : positions par livre (S-068) et réglages du texte (S-069).
@MainActor @Observable
final class ReadingStore {
    private(set) var positions: [String: ReadingPosition]
    @ObservationIgnored private let url: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(directories: AppDirectories) {
        url = directories.readingLog
        positions = ReadingLog.load(directories.readingLog)
        _ = try? IndexBackups.backUpToday(directories.readingLog, to: directories.backups, name: "reading")
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    func savedPosition(of book: Book) -> ReadingPosition? { positions[book.fingerprint] }

    /// Enregistre la page affichée ; l'écriture attend une courte pause (pages tournées vite).
    func record(_ position: ReadingPosition, for book: Book) {
        positions[book.fingerprint] = position
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        do {
            try ReadingLog.save(positions, to: url)
        } catch {
            // Signalé dans la fenêtre principale ; la position reste en mémoire et sera réessayée.
            AppServices.shared.library.lastError = "Impossible d'enregistrer la position de lecture : \(error.localizedDescription)"
        }
    }

    // MARK: Réglages du texte (valables pour tous les livres)

    static let scaleKey = "readerTextScale", themeKey = "readerTheme"
    static let scales: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.4, 1.6, 1.8, 2]

    var textScale: Double {
        get {
            access(keyPath: \.textScale)
            let value = UserDefaults.standard.double(forKey: Self.scaleKey)
            return value == 0 ? 1 : value
        }
        set { withMutation(keyPath: \.textScale) { UserDefaults.standard.set(newValue, forKey: Self.scaleKey) } }
    }

    var theme: ReaderTheme {
        get {
            access(keyPath: \.theme)
            return UserDefaults.standard.string(forKey: Self.themeKey).flatMap(ReaderTheme.init(rawValue:)) ?? .light
        }
        set { withMutation(keyPath: \.theme) { UserDefaults.standard.set(newValue.rawValue, forKey: Self.themeKey) } }
    }

    var canEnlarge: Bool { textScale < Self.scales.last! - 0.001 }
    var canReduce: Bool { textScale > Self.scales.first! + 0.001 }

    func enlarge() { textScale = Self.scales.first { $0 > textScale + 0.001 } ?? textScale }
    func reduce() { textScale = Self.scales.last { $0 < textScale - 0.001 } ?? textScale }
}
