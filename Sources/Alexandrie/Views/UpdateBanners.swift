import AlexandrieCore
import SwiftUI

/// Version publiée plus récente : installation depuis l'app.
struct ReleaseBanner: View {
    @Environment(UpdateMonitor.self) private var updates
    @Environment(\.openURL) private var openURL
    let release: ReleaseInfo

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Palette.info)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Alexandrie \(release.version) est disponible (vous avez la \(updates.currentVersion))")
                    .font(.callout.weight(.semibold))
                if case .failed(let why) = updates.installState {
                    Text(why).foregroundStyle(Palette.warning).lineLimit(3)
                } else if !release.notes.isEmpty {
                    Text(release.notes.components(separatedBy: .newlines).prefix(2).joined(separator: " "))
                        .foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .font(.caption)
            Spacer(minLength: 8)
            switch updates.installState {
            case .downloading, .installing:
                ProgressView().controlSize(.small)
                Text(updates.installState == .downloading ? String(localized: "Téléchargement…") : String(localized: "Installation…")).font(.caption)
            case .idle, .failed:
                if let page = release.pageURL { Button("Détails") { openURL(page) } }
                Button("Installer et relancer") { Task { await updates.install(release) } }
                    .buttonStyle(.borderedProminent)
                Button("Plus tard") { updates.dismissRelease() }
            }
        }
        .banner(Palette.info)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Bandeau signalant une version plus récente publiée sur GitHub.
struct UpdateBanner: View {
    @Environment(UpdateMonitor.self) private var updates
    @Environment(\.openURL) private var openURL
    let info: UpdateInfo

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Palette.info)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Une mise à jour d'Alexandrie est disponible sur GitHub").font(.callout.weight(.semibold))
                Text(String(localized: "\(info.newCommits) modifications"))
                    + Text(info.latestMessage.isEmpty ? "" : String(localized: " · dernière : \(info.latestMessage)"))
                Text("Pour l'installer : git pull, puis scripts/bundle.sh.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .lineLimit(2)
            Spacer(minLength: 8)
            if let url = info.url {
                Button("Voir les modifications") { openURL(url) }
            }
            Button("Plus tard") { updates.dismiss() }
        }
        .banner(Palette.info)
        .overlay(alignment: .bottom) { Divider() }
    }
}
