import AppKit
import SwiftUI

struct BufferedTranscriptEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let editor = NSTextView()
        editor.delegate = context.coordinator
        editor.drawsBackground = false
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.textColor = NSColor.white.withAlphaComponent(0.9)
        editor.insertionPointColor = .systemBlue
        editor.font = .systemFont(ofSize: 12, weight: .regular)
        editor.textContainerInset = NSSize(width: 5, height: 5)
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.autoresizingMask = [.width]
        editor.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.string = text
        scrollView.documentView = editor
        context.coordinator.editor = editor
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let editor = context.coordinator.editor, editor.string != text else { return }
        editor.string = text
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var editor: NSTextView?

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let editor else { return }
            text = editor.string
            editor.scrollRangeToVisible(editor.selectedRange())
        }
    }
}
