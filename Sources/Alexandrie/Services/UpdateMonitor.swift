import AlexandrieCore
import AppKit
import Foundation
import Observation

/// Signale qu'une version plus récente d'Alexandrie est publiée sur GitHub.
@MainActor @Observable
final class UpdateMonitor {
    enum Status: Equatable {
        case idle, checking, upToDate
        case available(UpdateInfo)
        /// Version publiée plus récente, installable depuis l'app.
        case release(ReleaseInfo)
        case failed(String)
    }

    enum InstallState: Equatable {
        case idle, downloading, installing
        case failed(String)
    }

    /// Commit inscrit dans l'app par scripts/bundle.sh ; absent pour un binaire lancé avec `swift run`.
    let currentCommit = (Bundle.main.object(forInfoDictionaryKey: "AlexandrieCommit") as? String).flatMap { $0.isEmpty ? nil : $0 }
    /// Version de l'app (fichier VERSION, inscrit par scripts/bundle.sh).
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    private(set) var status: Status = .idle
    private(set) var installState: InstallState = .idle
    private static let dismissedReleaseKey = "updateDismissedRelease"

    @ObservationIgnored private let checker = UpdateChecker()
    private static let dismissedKey = "updateDismissedSHA"

    init() {
        if autoCheck, AppDirectories.testStore == nil { Task { await check() } }
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

    /// Version publiée à proposer (pas encore écartée par l'utilisateur).
    var releaseBanner: ReleaseInfo? {
        guard case .release(let r) = status,
              UserDefaults.standard.string(forKey: Self.dismissedReleaseKey) != r.version else { return nil }
        return r
    }

    /// Versions publiées d'abord (installables), puis, pour une app construite depuis git, les commits de main.
    func check() async {
        guard status != .checking else { return }
        status = .checking
        var releasesReached = false
        do {
            if let release = try await checker.newerRelease(than: currentVersion) {
                status = .release(release)
                return
            }
            releasesReached = true
        } catch {}
        guard let currentCommit else {
            status = releasesReached ? .upToDate : .failed(String(localized: "versions publiées inaccessibles"))
            return
        }
        do {
            status = try await checker.check(currentCommit: currentCommit).map(Status.available) ?? .upToDate
        } catch {
            // Commit local pas encore sur GitHub (app construite sur ce Mac) : à jour si GitHub a répondu pour
            // les versions ; sinon hors ligne ou quota de l'API atteint.
            status = releasesReached ? .upToDate : .failed(error.localizedDescription)
        }
    }

    /// Recherche demandée par l'utilisateur (menu) : les versions écartées par « Plus tard » sont de nouveau
    /// proposées ; sans mise à jour, un message le dit.
    func checkManually() async {
        UserDefaults.standard.removeObject(forKey: Self.dismissedReleaseKey)
        UserDefaults.standard.removeObject(forKey: Self.dismissedKey)
        await check()
        let alert = NSAlert()
        switch status {
        case .release, .available:
            return  // le bandeau s'affiche dans la fenêtre principale
        case .failed(let why):
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Vérification impossible")
            alert.informativeText = String(localized: "GitHub n'a pas pu être interrogé (\(why)). Vérifiez la connexion Internet et réessayez.")
        default:
            alert.messageText = String(localized: "Alexandrie est à jour")
            alert.informativeText = String(localized: "Vous avez la version \(currentVersion), la plus récente publiée.")
        }
        alert.runModal()
    }

    func dismissRelease() {
        guard case .release(let r) = status else { return }
        withMutation(keyPath: \.status) { UserDefaults.standard.set(r.version, forKey: Self.dismissedReleaseKey) }
    }

    /// Télécharge la version, vérifie qu'elle porte la même signature, remplace l'app et la relance.
    func install(_ release: ReleaseInfo) async {
        guard installState != .downloading, installState != .installing else { return }
        installState = .downloading
        do {
            var request = URLRequest(url: release.downloadURL)
            request.setValue(UserAgent.value, forHTTPHeaderField: "User-Agent")
            let (downloaded, _) = try await URLSession.shared.download(for: request)
            // Le fichier téléchargé est temporaire : il est mis à l'abri tout de suite.
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("alexandrie-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("Alexandrie.zip")
            try FileManager.default.moveItem(at: downloaded, to: zip)
            installState = .installing
            let current = Bundle.main.bundleURL
            try await Task.detached(priority: .userInitiated) {
                defer { try? FileManager.default.removeItem(at: work) }
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", zip.path, work.path]
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
                let app = work.appendingPathComponent("Alexandrie.app")
                try SignatureCheck.verifySameSigner(app)
                _ = try FileManager.default.replaceItemAt(current, withItemAt: app)
            }.value
            relaunch(current)
        } catch {
            installState = .failed(error.localizedDescription)
        }
    }

    /// Relance la nouvelle version une fois celle-ci fermée (l'index est enregistré à la fermeture).
    private func relaunch(_ app: URL) {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? shell.run()
        NSApp.terminate(nil)
    }

    /// « Plus tard » : la même version n'est plus signalée, une suivante le sera.
    func dismiss() {
        guard case .available(let info) = status else { return }
        withMutation(keyPath: \.status) { UserDefaults.standard.set(info.latestSHA, forKey: Self.dismissedKey) }
    }
}
