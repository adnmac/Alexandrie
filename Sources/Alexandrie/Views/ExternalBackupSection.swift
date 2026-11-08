import AlexandrieCore
import AppKit
import SwiftUI

/// Réglages › Sauvegarde : sauvegarde de chaque jour dans un dossier choisi (iCloud Drive, disque externe),
/// et restauration d'une de ses copies au lancement suivant.
struct ExternalBackupSection: View {
    @Environment(BackupMonitor.self) private var backups
    @State private var chosen: ExternalBackup.Snapshot?

    var body: some View {
        Section("Copie hors du Mac : iCloud Drive ou disque externe") {
            Toggle("Sauvegarder chaque jour", isOn: Binding(
                get: { backups.isEnabled },
                set: { on in
                    if on && backups.folder == nil { chooseFolder() }
                    backups.isEnabled = on && backups.folder != nil
                    if backups.isEnabled { Task { await backups.backUpIfDue() } }
                }))
            LabeledContent("Dossier") {
                HStack {
                    folderLabel
                    if backups.folder == nil, BackupMonitor.iCloudDrive != nil {
                        Button("iCloud Drive") { backups.folder = BackupMonitor.iCloudDrive }
                            .help("Sauvegarder dans iCloud Drive (dossier « Sauvegarde Foluna »)")
                    }
                    Button("Choisir…", action: chooseFolder)
                }
            }
            LabeledContent("Dernière sauvegarde") {
                HStack {
                    statusLabel
                    Button("Sauvegarder") { Task { await backups.backUpNow() } }
                        .disabled(backups.folder == nil || backups.status == .running || !backups.isFolderAvailable)
                        .help("Sauvegarder maintenant, sans attendre la copie du jour")
                }
            }
            LabeledContent("Copies datées") {
                HStack {
                    Text("\(backups.snapshots.count)").foregroundStyle(.secondary)
                    Menu("Restaurer…") {
                        ForEach(backups.snapshots) { s in
                            Button(s.date.formatted(date: .complete, time: .omitted)) { chosen = s }
                        }
                    }
                    .fixedSize()
                    .disabled(backups.snapshots.isEmpty)
                    if let folder = backups.folder, backups.isFolderAvailable {
                        Button("Afficher") {
                            NSWorkspace.shared.activateFileViewerSelecting([ExternalBackup.root(in: folder)])
                        }
                    }
                }
            }
            if let message = backups.restoreMessage {
                Label(message, systemImage: "arrow.uturn.backward.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Chaque jour, l'index (vos corrections, étagères, corbeille), les notes et surlignages, les thématiques, les positions de lecture et les catalogues sont copiés dans « Sauvegarde Foluna », avec les livres importés ou téléchargés et les couvertures ; les 30 derniers jours sont gardés. Vos dossiers de livres ne sont pas copiés : ils restent où ils sont.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Restaurer la sauvegarde du \(chosen?.date.formatted(date: .long, time: .omitted) ?? "") ?",
                            isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } })) {
            Button("Restaurer et relancer") {
                if let s = chosen { backups.restore(s) }
            }
        } message: {
            Text("Foluna se relance et reprend cette sauvegarde : les changements faits depuis seront remplacés. L'état actuel est d'abord mis de côté dans le dossier Sauvegardes de l'app ; les livres absents reviennent, aucun n'est effacé.")
        }
        .task { backups.refresh() }
    }

    @ViewBuilder private var folderLabel: some View {
        if let folder = backups.folder {
            if !backups.isFolderAvailable {
                Label("Introuvable", systemImage: "externaldrive.badge.xmark")
                    .foregroundStyle(Palette.warning)
                    .help("\(folder.path) : disque débranché ou dossier déplacé. La sauvegarde reprendra quand il sera de retour.")
            } else {
                Text(backups.isInICloud ? String(localized: "iCloud Drive") + Self.relative(folder) : (folder.path as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder.path)
            }
        } else {
            Text("aucun").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch backups.status {
        case .running:
            ProgressView().controlSize(.small)
        case .failed(let message):
            Label("Échec", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Palette.warning)
                .help(message)
        case .idle:
            Text(backups.lastBackupAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "jamais")
                .foregroundStyle(.secondary)
        }
    }

    /// « › Documents › Livres » : le chemin sous iCloud Drive.
    private static func relative(_ folder: URL) -> String {
        guard let icloud = BackupMonitor.iCloudDrive else { return "" }
        let rest = folder.standardizedFileURL.path.dropFirst(icloud.standardizedFileURL.path.count)
        return rest.split(separator: "/").map { " › " + $0 }.joined()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choisir")
        panel.message = String(localized: "Dossier de sauvegarde : iCloud Drive, un disque externe… Foluna y crée « Sauvegarde Foluna ».")
        panel.directoryURL = backups.folder ?? BackupMonitor.iCloudDrive
        if panel.runModal() == .OK, let url = panel.url {
            backups.folder = url
        }
    }
}
