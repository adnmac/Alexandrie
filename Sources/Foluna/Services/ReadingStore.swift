import FolunaCore
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
            AppServices.shared.library.lastError = String(localized: "Impossible d'enregistrer la position de lecture : \(error.localizedDescription)")
        }
    }

    // MARK: Comparaison (S-104)

    static let companionsKey = "readerCompanions"

    /// Livre ouvert en face de celui-ci lors de la dernière comparaison (empreintes) ; repris à l'ouverture.
    func companion(of book: Book) -> String? {
        (UserDefaults.standard.dictionary(forKey: Self.companionsKey) as? [String: String])?[book.fingerprint]
    }

    func setCompanion(_ companion: Book?, for book: Book) {
        var all = UserDefaults.standard.dictionary(forKey: Self.companionsKey) as? [String: String] ?? [:]
        all[book.fingerprint] = companion?.fingerprint
        UserDefaults.standard.set(all, forKey: Self.companionsKey)
    }

    // MARK: Réglages du texte

    static let scaleKey = "readerTextScale", themeKey = "readerTheme", fontKey = "readerFont"
    /// Taille propre à un livre (S-105), par empreinte ; un livre absent suit la taille par défaut.
    static let bookScalesKey = "readerTextScales"
    static let scales: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.4, 1.6, 1.8, 2]

    /// Taille par défaut, pour les livres jamais réglés.
    var textScale: Double {
        get {
            access(keyPath: \.textScale)
            let value = UserDefaults.standard.double(forKey: Self.scaleKey)
            return value == 0 ? 1 : value
        }
        set { withMutation(keyPath: \.textScale) { UserDefaults.standard.set(newValue, forKey: Self.scaleKey) } }
    }

    private var bookScales: [String: Double] {
        get {
            access(keyPath: \.bookScales)
            return UserDefaults.standard.dictionary(forKey: Self.bookScalesKey) as? [String: Double] ?? [:]
        }
        set { withMutation(keyPath: \.bookScales) { UserDefaults.standard.set(newValue, forKey: Self.bookScalesKey) } }
    }

    /// Taille du texte de ce livre : la sienne s'il a été réglé, sinon la taille par défaut.
    func textScale(for book: Book) -> Double { bookScales[book.fingerprint] ?? textScale }

    /// Le livre a sa propre taille, différente de la taille par défaut.
    func hasOwnScale(_ book: Book) -> Bool { bookScales[book.fingerprint] != nil }

    /// Règle la taille de ce livre seulement ; la taille par défaut efface la valeur propre.
    func setTextScale(_ scale: Double, for book: Book) {
        bookScales[book.fingerprint] = abs(scale - textScale) < 0.001 ? nil : scale
    }

    /// Le livre revient à la taille par défaut (⌘0).
    func resetTextScale(for book: Book) { bookScales[book.fingerprint] = nil }

    /// La taille de ce livre devient la taille par défaut ; les livres réglés gardent la leur.
    func useAsDefault(_ book: Book) {
        textScale = textScale(for: book)
        resetTextScale(for: book)
    }

    var theme: ReaderTheme {
        get {
            access(keyPath: \.theme)
            return UserDefaults.standard.string(forKey: Self.themeKey).flatMap(ReaderTheme.init(rawValue:)) ?? .light
        }
        set { withMutation(keyPath: \.theme) { UserDefaults.standard.set(newValue.rawValue, forKey: Self.themeKey) } }
    }

    /// Police des livres (S-095) ; par défaut, celle de chaque livre.
    var font: ReaderFont {
        get {
            access(keyPath: \.font)
            return UserDefaults.standard.string(forKey: Self.fontKey).flatMap(ReaderFont.init(rawValue:)) ?? .book
        }
        set { withMutation(keyPath: \.font) { UserDefaults.standard.set(newValue.rawValue, forKey: Self.fontKey) } }
    }

    func canEnlarge(_ book: Book) -> Bool { textScale(for: book) < Self.scales.last! - 0.001 }
    func canReduce(_ book: Book) -> Bool { textScale(for: book) > Self.scales.first! + 0.001 }

    func enlarge(_ book: Book) {
        let current = textScale(for: book)
        setTextScale(Self.scales.first { $0 > current + 0.001 } ?? current, for: book)
    }

    func reduce(_ book: Book) {
        let current = textScale(for: book)
        setTextScale(Self.scales.last { $0 < current - 0.001 } ?? current, for: book)
    }
}
