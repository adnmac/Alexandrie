import AppKit

/// Point d'entrée : l'app SwiftUI, ou le self-test sans fenêtre (`--selftest`).
@main
enum Entry {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.launch()
        } else {
            SeedData.seedIfRequested()
            AlexandrieApp.main()
        }
    }
}
