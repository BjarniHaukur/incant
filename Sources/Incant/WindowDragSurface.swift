import AppKit
import SwiftUI

/// Moves whichever Incant window contains it using stable screen coordinates.
/// Unlike a SwiftUI DragGesture, its coordinate system does not move under the
/// pointer while the window is being repositioned.
struct WindowDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        private var mouseOrigin = NSPoint.zero
        private var windowOrigin = NSPoint.zero

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            mouseOrigin = NSEvent.mouseLocation
            windowOrigin = window?.frame.origin ?? .zero
            NSCursor.closedHand.push()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let pointer = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(
                x: windowOrigin.x + pointer.x - mouseOrigin.x,
                y: windowOrigin.y + pointer.y - mouseOrigin.y
            ))
        }

        override func mouseUp(with event: NSEvent) {
            NSCursor.pop()
        }
    }
}
