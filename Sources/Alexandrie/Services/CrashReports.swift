import AlexandrieCore
import AppKit
import MetricKit
import Observation
import SwiftUI

/// Rapports de plantage (audit, § 4) : macOS les remet à l'app au lancement suivant (MetricKit). Ils restent
/// sur le Mac, dans `Rapports/`, et ne partent que si l'utilisateur choisit de les envoyer.
/// Un rapport contient les piles d'appels, la version de l'app, de macOS et le modèle du Mac : rien de personnel.
@MainActor @Observable
final class CrashReports {
    static let shared = CrashReports()

    /// Rapports reçus et pas encore traités, du plus ancien au plus récent.
    private(set) var pending: [URL] = []
    @ObservationIgnored private let folder = AppDirectories().base.appendingPathComponent("Rapports", isDirectory: true)
    @ObservationIgnored private let receiver = MetricReceiver()
    @ObservationIgnored private var started = false

    /// Adresse d'assistance, écrite dans l'Info.plist par `scripts/bundle.sh` (`ALEXANDRIE_SUPPORT_EMAIL`).
    var supportEmail: String? {
        (Bundle.main.object(forInfoDictionaryKey: "AlexandrieSupportEmail") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Pas en mode test ni capture : les rapports d'un vrai Mac ne s'y mêlent pas.
    var isEnabled: Bool { AppDirectories.testStore == nil }

    func start() {
        guard isEnabled, !started else { return }
        started = true
        MXMetricManager.shared.add(receiver)
        reload()
    }

    /// Enregistre un rapport (JSON de MetricKit).
    func store(_ data: Data, at date: Date = Date()) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime]
        let url = folder.appendingPathComponent("plantage-\(formatter.string(from: date)).json")
        try? data.write(to: url, options: .atomic)
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        pending = files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// « Ne pas envoyer » : les rapports sont effacés.
    func discardAll() {
        for url in pending { try? FileManager.default.removeItem(at: url) }
        reload()
    }

    func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting(pending)
    }

    /// Prépare un e-mail à l'assistance, rapports joints ; l'utilisateur le relit et l'envoie lui-même.
    func email() {
        guard let address = supportEmail, let service = NSSharingService(named: .composeEmail) else { return reveal() }
        service.recipients = [address]
        service.subject = "Alexandrie \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") : rapport de plantage"
        let body = "Bonjour,\n\nAlexandrie s'est arrêtée. Voici le rapport que macOS a remis à l'app.\n\nCe que je faisais à ce moment-là :\n\n"
        service.perform(withItems: [body] + pending)
        // Envoyés (ou confiés à Mail) : ils ne sont plus proposés.
        for url in pending { try? FileManager.default.removeItem(at: url) }
        reload()
    }
}

/// Reçoit les diagnostics de MetricKit (sur un fil quelconque) et garde ceux qui décrivent un plantage.
final class MetricReceiver: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let crashes = payloads.filter { !($0.crashDiagnostics ?? []).isEmpty }.map { $0.jsonRepresentation() }
        guard !crashes.isEmpty else { return }
        Task { @MainActor in
            for data in crashes { CrashReports.shared.store(data) }
        }
    }
}

/// Au lancement qui suit un plantage : l'utilisateur décide de l'envoi du rapport.
struct CrashReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let reports = CrashReports.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Label("Alexandrie s'est arrêtée", systemImage: "exclamationmark.triangle")
                .font(.title3.weight(.semibold))
            Text("macOS a remis à Alexandrie \(reports.pending.count == 1 ? "un rapport" : "\(reports.pending.count) rapports") de plantage. L'envoyer aide à corriger le problème.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Un rapport contient les fonctions en cours au moment de l'arrêt, la version d'Alexandrie et de macOS, et le modèle du Mac. Ni vos livres, ni vos notes, ni votre nom.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Afficher dans le Finder") { reports.reveal() }
                Spacer()
                Button("Ne pas envoyer") {
                    reports.discardAll()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if reports.supportEmail != nil {
                    Button("Envoyer par e-mail…") {
                        reports.email()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Space.xl)
        .frame(width: Layout.sheet)
    }
}
