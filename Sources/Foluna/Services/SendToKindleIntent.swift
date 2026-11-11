import FolunaCore
import AppIntents
import Foundation

/// Un livre de la bibliothèque, tel que Raccourcis le montre et le cherche.
struct BookEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Livre"
    static let defaultQuery = BookQuery()

    let id: String
    let title: String
    let authors: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(authors)")
    }

    init(_ book: Book) {
        id = book.id
        title = book.title
        authors = book.authorLine
    }
}

/// Recherche des livres par titre ou auteur, parmi les livres visibles (pas la corbeille).
struct BookQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [BookEntity] {
        identifiers.compactMap { AppServices.shared.library.book(id: $0) }.map(BookEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [BookEntity] {
        AppServices.shared.library.visibleBooks
            .filter { $0.title.localizedStandardContains(string) || $0.authorLine.localizedStandardContains(string) }
            .prefix(50).map(BookEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [BookEntity] {
        AppServices.shared.library.visibleBooks
            .sorted { $0.addedAt > $1.addedAt }
            .prefix(20).map(BookEntity.init)
    }
}

/// Erreurs montrées par Raccourcis, avec les mots de l'app.
enum SendToKindleError: Error, CustomLocalizedStringResourceConvertible {
    case notFound(String)
    case notSendable(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notFound(let title): "Aucun livre « \(title) » dans la bibliothèque"
        case .notSendable(let title): "« \(title) » ne peut pas être envoyé sur la liseuse"
        }
    }
}

/// Raccourcis > « Envoyer à la liseuse » : envoie tout de suite si la liseuse est branchée,
/// sinon met le livre en attente, comme Kindle > Envoyer à la liseuse (S-053).
struct SendToKindleIntent: AppIntent {
    static let title: LocalizedStringResource = "Envoyer à la liseuse"
    static let description = IntentDescription("Copie un livre de Foluna sur la liseuse branchée, ou le met en attente jusqu'à sa connexion.")

    @Parameter(title: "Livre")
    var book: BookEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Envoyer \(\.$book) à la liseuse")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let services = AppServices.shared
        guard let found = services.library.book(id: book.id), found.trashedAt == nil else {
            throw SendToKindleError.notFound(book.title)
        }
        guard services.kindle.canSend(found) else { throw SendToKindleError.notSendable(found.title) }
        let result = await SendToKindle.run(found, library: services.library, kindle: services.kindle)
        return .result(value: result, dialog: "\(result)")
    }
}

/// Envoi d'un livre hors de la fenêtre (Raccourcis, self-test).
@MainActor
enum SendToKindle {
    /// « Envoyé sur « Kindle de Léa » », « Échec : … » ou « En attente de la liseuse ».
    static func run(_ book: Book, library: LibraryStore, kindle: KindleMonitor) async -> String {
        if kindle.isConnected {
            await kindle.send([book], library: library)
            if case .failed(let message) = kindle.transfers[book.id] { return String(localized: "Échec : \(message)") }
            return kindle.currentReader.map { String(localized: "Envoyé sur « \($0.name) »") } ?? String(localized: "Envoyé sur la liseuse")
        }
        let reader = kindle.readers.count == 1 ? kindle.readers[0].id : nil
        library.queueForKindle([book], reader: reader)
        SendNotifier.prepare()
        return String(localized: "En attente de la liseuse")
    }
}

/// Phrases pour Siri et Spotlight.
struct FolunaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SendToKindleIntent(),
                    phrases: ["Envoyer un livre à la liseuse avec \(.applicationName)",
                              "Envoyer un livre à la Kindle avec \(.applicationName)"],
                    shortTitle: "Envoyer à la liseuse",
                    systemImageName: "arrow.down.to.line.compact")
    }
}
