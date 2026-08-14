import AppKit
import SwiftUI

struct BufferedTranscriptEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, contentHeight: $contentHeight)
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
        editor.textContainerInset = NSSize(width: 32, height: 5)
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
        context.coordinator.updateHeight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let editor = context.coordinator.editor, editor.string != text else { return }
        editor.string = text
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        context.coordinator.updateHeight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var contentHeight: CGFloat
        weak var editor: NSTextView?

        init(text: Binding<String>, contentHeight: Binding<CGFloat>) {
            _text = text
            _contentHeight = contentHeight
        }

        func textDidChange(_ notification: Notification) {
            guard let editor else { return }
            text = editor.string
            editor.scrollRangeToVisible(editor.selectedRange())
            updateHeight()
        }

        func updateHeight() {
            guard let editor, let layoutManager = editor.layoutManager,
                  let textContainer = editor.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let measured = layoutManager.usedRect(for: textContainer).height
                + editor.textContainerInset.height * 2
            let nextHeight = min(92, max(36, ceil(measured)))
            guard abs(contentHeight - nextHeight) > 0.5 else { return }
            DispatchQueue.main.async { [weak self] in
                self?.contentHeight = nextHeight
            }
        }
    }
}
