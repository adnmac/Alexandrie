import AppKit

/// Point d'entrée : l'app SwiftUI, le self-test sans fenêtre (`--selftest`)
/// ou le test de résistance (`--stress <nombre de livres>`).
@main
enum Entry {
    /// `FOLUNA_HANGLOG=1` : chaque blocage du thread principal de plus de 250 ms est écrit sur stderr.
    static let hangLog: MainThreadWatchdog? = ProcessInfo.processInfo.environment["FOLUNA_HANGLOG"] == "1"
        ? MainThreadWatchdog(log: true) : nil

    @MainActor static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.launch()
        } else if CommandLine.arguments.contains("--stress") {
            StressTest.launch()
        } else {
            hangLog?.start()
            SeedData.seedIfRequested()
            FolunaApp.main()
        }
    }
}
