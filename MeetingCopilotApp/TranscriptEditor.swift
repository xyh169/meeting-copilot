import AppKit
import SwiftUI

struct TranscriptInlineEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = NSTextView()
        editor.isRichText = false
        editor.font = .systemFont(ofSize: 14)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.string = text
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("Edit this segment")
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TranscriptInlineEditor
        init(_ parent: TranscriptInlineEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

@MainActor
final class TranscriptEditorController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private let editor = NSTextView()
    private let saveButton = NSButton(title: "Save and reanalyze", target: nil, action: nil)
    private var onSave: ((String) -> Void)?
    private var onClose: (() -> Void)?

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Edit transcript"
        panel.minSize = NSSize(width: 480, height: 360)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(original: String, corrected: String, parent: NSWindow,
                 onSave: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        guard let window, window.sheetParent == nil else { return }
        self.onSave = onSave
        self.onClose = onClose
        let content = NSView()
        window.contentView = content
        let originalView = NSTextView()
        originalView.string = original
        originalView.isEditable = false
        let originalScroll = scrollView(for: originalView)
        originalScroll.heightAnchor.constraint(equalToConstant: 85).isActive = true
        editor.string = corrected
        editor.delegate = self
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        let editorScroll = scrollView(for: editor)
        editorScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        let buttons = NSStackView(views: [spacer, cancel, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [NSTextField(labelWithString: "ASR original"), originalScroll,
                                        NSTextField(labelWithString: "Corrections"), editorScroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            originalScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            editorScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        updateSaveButton()
        parent.beginSheet(window)
        window.makeFirstResponder(editor)
    }

    private func scrollView(for textView: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 540, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = textView
        return scroll
    }

    func textDidChange(_ notification: Notification) { updateSaveButton() }

    private func updateSaveButton() {
        saveButton.isEnabled = !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && editor.string.count <= 2000
    }

    @objc private func save() {
        guard saveButton.isEnabled else { return }
        let value = editor.string
        let callback = onSave
        dismiss()
        // Apply the transcript change after AppKit has closed its editing sheet.
        DispatchQueue.main.async { callback?(value) }
    }

    @objc private func cancel() { dismiss() }

    private func dismiss() {
        if let window {
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
        }
        onSave = nil
        let callback = onClose
        onClose = nil
        callback?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }
}
