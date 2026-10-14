import SwiftUI

/// Configuration UI for user-defined comment templates. The default is empty: a fresh
/// install shows no shortcut anywhere, and nothing is built in for a specific team.
struct CommentShortcutSettingsSection: View {
    @Binding var shortcuts: [CommentShortcut]
    @State private var editing: CommentShortcut?
    @State private var isAddingNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if shortcuts.isEmpty {
                Text("No shortcuts configured. Add one to get a one-click comment draft on a PR or review comment.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach($shortcuts) { $shortcut in
                HStack(spacing: 6) {
                    Toggle("", isOn: $shortcut.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    Text(shortcut.displayName.isEmpty ? String(localized: "(unnamed)") : shortcut.displayName)
                        .font(.system(size: 12, weight: .medium))
                    Text(shortcut.template)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Edit") { editing = shortcut }
                        .controlSize(.small)
                    Button("Remove") {
                        shortcuts.removeAll { $0.id == shortcut.id }
                    }
                    .controlSize(.small)
                }
            }

            Button {
                isAddingNew = true
                editing = CommentShortcut(displayName: "", template: "")
            } label: {
                Label("Add shortcut", systemImage: "plus")
            }
            .controlSize(.small)
        }
        .sheet(item: $editing) { shortcut in
            CommentShortcutEditorSheet(
                shortcut: shortcut,
                isNew: isAddingNew,
                onSave: { updated in
                    if let index = shortcuts.firstIndex(where: { $0.id == updated.id }) {
                        shortcuts[index] = updated
                    } else {
                        shortcuts.append(updated)
                    }
                    editing = nil
                    isAddingNew = false
                },
                onCancel: {
                    editing = nil
                    isAddingNew = false
                }
            )
        }
    }
}

struct CommentShortcutEditorSheet: View {
    @State private var draft: CommentShortcut
    @State private var contexts: Set<CommentShortcutContext>
    @State private var repositoryScopes: String
    @State private var previewContext: CommentShortcutContext = .pullRequest
    @State private var previewCommentBody: String = "Could you add a test for this branch?"
    let isNew: Bool
    let onSave: (CommentShortcut) -> Void
    let onCancel: () -> Void

    init(
        shortcut: CommentShortcut,
        isNew: Bool,
        onSave: @escaping (CommentShortcut) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: shortcut)
        _contexts = State(initialValue: shortcut.contexts)
        _repositoryScopes = State(initialValue: shortcut.repositoryScopes.joined(separator: ", "))
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? "New comment shortcut" : "Edit comment shortcut")
                .font(.headline)

            TextField("Name", text: $draft.displayName, prompt: Text("Ask for tests"))
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("Template")
                    .font(.caption)
                TextEditor(text: $draft.template)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 90)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                Text("Variables: \(CommentShortcutVariable.allCases.map { "{{\($0.rawValue)}}" }.joined(separator: " "))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Available for")
                    .font(.caption)
                ForEach(CommentShortcutContext.allCases, id: \.self) { context in
                    Toggle(context.displayName, isOn: binding(for: context))
                        .toggleStyle(.checkbox)
                }
            }

            TextField(
                "Repositories (comma separated, empty = all)",
                text: $repositoryScopes,
                prompt: Text("owner/repo")
            )
            .textFieldStyle(.roundedBorder)

            validationMessageView

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Preview")
                        .font(.caption)
                    Picker("", selection: $previewContext) {
                        ForEach(CommentShortcutContext.allCases, id: \.self) { context in
                            Text(context.displayName).tag(context)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                Text(previewText)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(4)
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || CommentShortcutTemplate.validate(template: draft.template) != nil)
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    private func binding(for context: CommentShortcutContext) -> Binding<Bool> {
        Binding(
            get: { contexts.contains(context) },
            set: { isOn in
                if isOn { contexts.insert(context) } else { contexts.remove(context) }
            }
        )
    }

    private var validationMessage: String? {
        CommentShortcutTemplate.validate(template: draft.template)?.errorDescription
    }

    @ViewBuilder
    private var validationMessageView: some View {
        if let validationMessage {
            Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var previewText: String {
        let values = CommentShortcutValues(
            context: previewContext,
            repository: "octocat/hello-world",
            prNumber: 42,
            prURL: URL(string: "https://github.com/octocat/hello-world/pull/42"),
            headSHA: "0f1e2d3c4b5a69788796a5b4c3d2e1f001234567",
            commentURL: URL(string: "https://github.com/octocat/hello-world/pull/42#discussion_r1"),
            commentBody: previewCommentBody
        )
        do {
            return try draft.render(with: values)
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func save() {
        var updated = draft
        updated.contexts = contexts
        updated.repositoryScopes = repositoryScopes
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        onSave(updated)
    }
}
