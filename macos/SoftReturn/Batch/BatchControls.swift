import AppKit
import CtrlKD
import os
import SoftReturnShared
import SwiftUI

// MARK: - A real NSPopUpButton, bridged into the SwiftUI column

/// Job 528: the SETTINGS way, bridged rather than hoisted — see the class doc comment above.
/// `titles` pairs each pulldown item's underlying value with its display string, in menu
/// order; `selection` is a plain `Binding` to the bound `@Published` model property, the same
/// contract a `Picker`'s own `selection:` argument offers. The width constraint lives on the
/// `NSPopUpButton` itself, never on a SwiftUI `.frame(width:)` wrapping it — that is the one
/// property this type exists to guarantee.
struct BatchPopUpButton<Tag: Hashable>: NSViewRepresentable {
    let titles: [(Tag, String)]
    @Binding var selection: Tag
    let width: CGFloat
    let accessibilityIdentifier: String
    let accessibilityLabel: String

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: titles.map(\.1))
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.setAccessibilityLabel(accessibilityLabel)
        button.translatesAutoresizingMaskIntoConstraints = false
        // The fix, in one line: a hard width constraint on the CONTROL, not an ignorable
        // frame offered to a SwiftUI wrapper around it. See the class doc comment.
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if let index = titles.firstIndex(where: { $0.0 == selection }),
           button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
        // SwiftUI's `.disabled(_:)` sets `\.isEnabled` in the environment; it does not reach
        // across the `NSViewRepresentable` boundary on its own the way it would for a native
        // SwiftUI control, so Font/Size's grey-out (`model.style != .modern`) has to be
        // applied by hand here, same as every other `updateNSView` bridging a stateful AppKit
        // control.
        button.isEnabled = context.environment.isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: BatchPopUpButton
        init(_ parent: BatchPopUpButton) { self.parent = parent }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let tag = parent.titles[safe: sender.indexOfSelectedItem]?.0 else { return }
            parent.selection = tag
        }
    }
}

// MARK: - Vertical centering, bridged into AppKit (job 545, R3)

/// Job 545 (R3, Jon's ruling from a macOS 26/Tahoe screenshot): job 536's SwiftUI
/// `.frame(maxHeight: .infinity, alignment: .center)` does not split `controlsColumn`'s slack
/// evenly on Jon's Mac — more blank space above the section stack than below it. Rather than
/// keep guessing at SwiftUI frame modifiers this environment cannot visually verify against
/// Tahoe, this hosts the column's content in a real `NSHostingView` and centers THAT with an
/// actual `centerYAnchor` constraint — the same "trust the real layout engine, not a SwiftUI
/// wrapper" move `BatchPopUpButton` above already makes for pulldown width. The `>=`/`<=`
/// guard constraints (not `.required`, so they yield instead of conflicting with `centerY` in
/// the pathological case the content ever exceeds the column's height) keep the hosted view
/// from being pushed off either edge.
struct VerticallyCenteringHost<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        let topGuard = hosting.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor)
        let bottomGuard = container.bottomAnchor.constraint(greaterThanOrEqualTo: hosting.bottomAnchor)
        topGuard.priority = .defaultHigh
        bottomGuard.priority = .defaultHigh
        NSLayoutConstraint.activate([topGuard, bottomGuard])
        context.coordinator.hostingView = hosting
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostingView?.rootView = content
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hostingView: NSHostingView<Content>?
    }
}
