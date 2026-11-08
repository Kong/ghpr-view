import AppKit
import SwiftUI

/// A stable native editor: marked text stays in AppKit until composition commits.
struct PanelSearchField: NSViewRepresentable {
    @Binding var text: String
    var focusRequest: UInt64 = 0
    var onCompositionChanged: (Bool) -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search PRs, repos, authors, Jira keys…"
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.controlSize = .small
        field.font = .systemFont(ofSize: 13)
        field.delegate = context.coordinator
        field.stringValue = text
        field.setAccessibilityIdentifier("panel-search")
        field.setAccessibilityLabel("Search pull requests")
        context.coordinator.lastFocusRequest = focusRequest
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        let hasMarkedText = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if !hasMarkedText, field.stringValue != text {
            field.stringValue = text
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window, window.isVisible else { return }
                window.makeFirstResponder(field)
            }
        }
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        coordinator.setComposing(false)
        field.delegate = nil
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: PanelSearchField
        var lastFocusRequest: UInt64 = 0
        private var isComposing = false

        init(_ parent: PanelSearchField) { self.parent = parent }

        func setComposing(_ composing: Bool) {
            guard composing != isComposing else { return }
            isComposing = composing
            parent.onCompositionChanged(composing)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
            if composing {
                setComposing(true)
                return
            }
            if parent.text != field.stringValue { parent.text = field.stringValue }
            setComposing(false)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
            setComposing(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
                  !textView.hasMarkedText() else { return false }
            parent.onEscape()
            return true
        }
    }
}
