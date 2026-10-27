import AppKit
import SwiftUI

/// What the island needs to know about where it sits.
@MainActor
@Observable
final class IslandLayout {
    var isHovering = false
    /// Set after opening a session: the island stays folded until the mouse leaves it.
    var hoverSuppressed = false
    var notch = CGSize(width: 200, height: 24)
    /// False on displays without a notch: the island then draws its own.
    var hasNotch = false
}

/// Fixed-size transparent panel at the top-centre of the screen holding the mouse.
/// It never resizes: hover comes from mouse monitors, and clicks pass through outside the island.
final class NotchPanel: NSPanel {
    private static let size = CGSize(width: 480, height: 600)

    private let layout = IslandLayout()
    /// Island shape in window coordinates (SwiftUI space, origin top-left).
    private var islandRect = CGRect.zero
    private weak var currentScreen: NSScreen?

    init(store: SessionStore) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true

        let host = NSHostingView(rootView: IslandView(store: store, layout: layout) { [weak self] in
            self?.islandRect = $0
            self?.trackMouse()
        })
        host.sizingOptions = []
        contentView = host
        trackMouse()

        // Global: mouse over other apps (or while we ignore events). Local: mouse over the island.
        NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.trackMouse()
            return event
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.currentScreen = nil
                self?.trackMouse()
            }
        }
    }

    // Borderless windows may sit over the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    private func trackMouse() {
        let p = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }), screen != currentScreen {
            move(to: screen)
        }
        let island = CGRect(x: frame.minX + islandRect.minX, y: frame.maxY - islandRect.maxY,
                            width: islandRect.width, height: islandRect.height)
        // Closed ranges: the cursor pinned to the top edge sits at y == maxY, which `contains` excludes.
        let inside = (island.minX...island.maxX).contains(p.x) && (island.minY...island.maxY).contains(p.y)
        if !inside { layout.hoverSuppressed = false }
        let hovering = inside && !layout.hoverSuppressed
        if layout.isHovering != hovering { layout.isHovering = hovering }
        ignoresMouseEvents = !hovering
    }

    private func move(to screen: NSScreen) {
        currentScreen = screen
        layout.hasNotch = screen.safeAreaInsets.top > 0
        layout.notch = Self.notchSize(of: screen)
        setFrameOrigin(NSPoint(x: screen.frame.midX - Self.size.width / 2, y: screen.frame.maxY - Self.size.height))
    }

    private static func notchSize(of screen: NSScreen) -> CGSize {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
        else { return CGSize(width: 200, height: NSStatusBar.system.thickness) }
        return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
    }
}
