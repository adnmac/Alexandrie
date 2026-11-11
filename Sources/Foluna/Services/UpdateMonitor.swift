import FolunaCore
import AppKit
import Foundation
import Observation

/// Signale qu'une version plus récente de Foluna est publiée sur GitHub.
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
    let currentCommit = (Bundle.main.object(forInfoDictionaryKey: "FolunaCommit") as? String).flatMap { $0.isEmpty ? nil : $0 }
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
            alert.messageText = String(localized: "Foluna est à jour")
            alert.informativeText = String(localized: "Vous avez la version \(currentVersion), la plus récente publiée.")
        }
        alert.runModal()
    }

    func dismissRelease() {
        guard case .release(let r) = status else { return }
        withMutation(keyPath: \.status) { UserDefaults.standard.set(r.version, forKey: Self.dismissedReleaseKey) }
    }

    /// Télécharge l'image disque de la version, en extrait l'app et vérifie qu'elle porte la même signature,
    /// puis ferme Foluna : un script remplace l'app une fois fermée et la relance.
    func install(_ release: ReleaseInfo) async {
        guard installState != .downloading, installState != .installing else { return }
        let current = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            installState = .failed(String(localized: "Le dossier « \(current.deletingLastPathComponent().path) » n'est pas modifiable : téléchargez le .dmg depuis « Détails » et installez-le à la main."))
            return
        }
        installState = .downloading
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("foluna-update-\(UUID().uuidString)", isDirectory: true)
        do {
            var request = URLRequest(url: release.downloadURL)
            request.setValue(UserAgent.value, forHTTPHeaderField: "User-Agent")
            let (downloaded, _) = try await URLSession.shared.download(for: request)
            // Le fichier téléchargé est temporaire : il est mis à l'abri tout de suite.
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let archive = work.appendingPathComponent(release.isDiskImage ? "Foluna.dmg" : "Foluna.zip")
            try FileManager.default.moveItem(at: downloaded, to: archive)
            installState = .installing
            let isDiskImage = release.isDiskImage
            let app = try await Task.detached(priority: .userInitiated) { () throws -> URL in
                let staged = work.appendingPathComponent("nouvelle", isDirectory: true)
                let app: URL
                if isDiskImage {
                    app = try DiskImage.extractApp(from: archive, to: staged)
                } else {
                    let unzip = Process()
                    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    unzip.arguments = ["-x", "-k", archive.path, staged.path]
                    try unzip.run()
                    unzip.waitUntilExit()
                    guard unzip.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
                    app = staged.appendingPathComponent("Foluna.app")
                }
                try SignatureCheck.verifySameSigner(app)
                return app
            }.value
            // L'index est enregistré à la fermeture ; le script attend qu'elle soit finie pour remplacer l'app.
            // Une copie encore nommée Alexandrie.app devient Foluna.app.
            let destination = current.deletingLastPathComponent().appendingPathComponent("Foluna.app")
            _ = try UpdateInstall.launch(waitingFor: ProcessInfo.processInfo.processIdentifier,
                                         newApp: app, installedApp: current, destination: destination, cleaning: work)
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: work)
            installState = .failed(error.localizedDescription)
        }
    }

    /// « Plus tard » : la même version n'est plus signalée, une suivante le sera.
    func dismiss() {
        guard case .available(let info) = status else { return }
        withMutation(keyPath: \.status) { UserDefaults.standard.set(info.latestSHA, forKey: Self.dismissedKey) }
    }
}
