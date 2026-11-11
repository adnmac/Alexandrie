import AppKit
import SwiftUI

/// Animations de l'app. Toutes passent par ici, pour que Réduire les animations s'applique partout.
@MainActor
enum Motion {
    /// Petite bascule : section repliée ou dépliée.
    static let quick = Animation.easeInOut(duration: 0.2)

    /// `withAnimation`, sans animation quand Réduire les animations est actif.
    static func run<Result>(_ animation: Animation, _ body: () throws -> Result) rethrows -> Result {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return try body()
        }
        return try withAnimation(animation, body)
    }
}
