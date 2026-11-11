import AppKit
import SwiftUI

/// Bouton sans bordure qui répond au survol, comme ceux des barres de macOS : fond léger au survol,
/// plus marqué à l'appui, curseur en main. Pour les petites actions posées dans une ligne (relevés de notes).
struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverButton(configuration: configuration)
    }

    private struct HoverButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false
        /// Le curseur en main a été posé : il est retiré une fois, et une seule.
        @State private var cursorPushed = false

        var body: some View {
            configuration.label
                .padding(.horizontal, Space.xs)
                .padding(.vertical, 2)  // grid: ok fond de survol serré autour d'une légende
                .background {
                    RoundedRectangle(cornerRadius: Radius.hover)
                        .fill(configuration.isPressed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary))
                        .opacity(isEnabled && (hovering || configuration.isPressed) ? 1 : 0)
                }
                .foregroundStyle(isEnabled && hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
                .onHover { inside in
                    hovering = inside
                    if inside && isEnabled && !cursorPushed {
                        NSCursor.pointingHand.push()
                        cursorPushed = true
                    } else if !inside && cursorPushed {
                        NSCursor.pop()
                        cursorPushed = false
                    }
                }
                .onDisappear {
                    if cursorPushed { NSCursor.pop() }
                    cursorPushed = false
                }
        }
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    static var hover: HoverButtonStyle { HoverButtonStyle() }
}
