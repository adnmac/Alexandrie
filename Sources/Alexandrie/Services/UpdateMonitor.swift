import AlexandrieCore
import Foundation
import Observation

/// Signale qu'une version plus récente d'Alexandrie est publiée sur GitHub.
@MainActor @Observable
final class UpdateMonitor {
    enum Status: Equatable {
        case idle, checking, upToDate
        case available(UpdateInfo)
        case failed(String)
    }

    /// Commit inscrit dans l'app par scripts/bundle.sh ; absent pour un binaire lancé avec `swift run`.
    let currentCommit = (Bundle.main.object(forInfoDictionaryKey: "AlexandrieCommit") as? String).flatMap { $0.isEmpty ? nil : $0 }
    private(set) var status: Status = .idle

    @ObservationIgnored private let checker = UpdateChecker()
    private static let dismissedKey = "updateDismissedSHA"

    init() {
        if autoCheck { Task { await check() } }
    }

    var autoCheck: Bool {
        get { access(keyPath: \.autoCheck); return UserDefaults.standard.object(forKey: "updateAutoCheck") as? Bool ?? true }
        set { withMutation(keyPath: \.autoCheck) { UserDefaults.standard.set(newValue, forKey: "updateAutoCheck") } }
    }

    /// Mise à jour à signaler dans la fenêtre principale (pas encore écartée par l'utilisateur).
    var banner: UpdateInfo? {
        guard case .available(let info) = status,
              UserDefaults.standard.string(forKey: Self.dismissedKey) != info.latestSHA else { return nil }
        return info
    }

    func check() async {
        guard let currentCommit, status != .checking else { return }
        status = .checking
        do {
            status = try await checker.check(currentCommit: currentCommit).map(Status.available) ?? .upToDate
        } catch {
            // Hors ligne, quota de l'API atteint, ou commit local absent de GitHub : rien à signaler.
            status = .failed(error.localizedDescription)
        }
    }

    /// « Plus tard » : la même version n'est plus signalée, une suivante le sera.
    func dismiss() {
        guard case .available(let info) = status else { return }
        withMutation(keyPath: \.status) { UserDefaults.standard.set(info.latestSHA, forKey: Self.dismissedKey) }
    }
}
