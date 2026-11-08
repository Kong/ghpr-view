import SwiftUI

struct FacetFilterPanel: View {
    let facetOptions: [FacetFieldID: [FacetOption]]
    let activeFacetSelections: [FacetFieldID: Set<String>]
    let savedViews: [SavedView]
    let actions: PRPanelActions
    let onSave: () -> Void
    @State private var selectedField: FacetFieldID = .githubLabel
    @State private var viewBeingRenamed: SavedView?
    @State private var renameName = ""

    private let fields = FacetFieldID.allCases
    var body: some View {
        let options = facetOptions[selectedField] ?? []
        return VStack(spacing: 0) {
            HStack {
                Text(selectedField.providerTitle).font(.headline)
                Spacer()
                Menu {
                    if savedViews.isEmpty {
                        Text("No Saved Views")
                    } else {
                        ForEach(savedViews) { view in
                            Button(view.name) {
                                actions.applySavedView(view)
                            }
                        }
                        Divider()
                        Menu("Rename") {
                            ForEach(savedViews) { view in
                                Button(view.name) {
                                    renameName = view.name
                                    viewBeingRenamed = view
                                }
                            }
                        }
                        Menu("Delete") {
                            ForEach(savedViews) { view in
                                Button(view.name, role: .destructive) {
                                    actions.deleteSavedView(view)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Views", systemImage: "bookmark")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.caption)
                .frame(height: 28)
                Button("Clear") { actions.clearFacetField(selectedField) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .frame(height: 28)
                    .disabled((activeFacetSelections[selectedField] ?? []).isEmpty)
                Button("Save View", action: onSave)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .frame(height: 28)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(fields, id: \.self) { field in
                        Button { selectedField = field } label: {
                            HStack { Image(systemName: field.symbolName).frame(width: 14); Text(field.title); Spacer(); if !(activeFacetSelections[field] ?? []).isEmpty { Text("\(activeFacetSelections[field]!.count)").font(.caption2) } }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedField == field ? Color.accentColor.opacity(0.15) : Color.clear)
                                .cornerRadius(5)
                        }.buttonStyle(.plain)
                    }
                    }
                    .padding(6)
                }
                .frame(width: 125)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(options) { option in
                            Button { actions.toggleFacet(selectedField, option.key) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: (activeFacetSelections[selectedField] ?? []).contains(option.key) ? "checkmark.square.fill" : "square")
                                        .foregroundColor(.accentColor)
                                    Image(systemName: selectedField.symbolName).foregroundColor(.secondary)
                                    Text(option.displayName).lineLimit(1)
                                    Spacer()
                                    Text("\(option.count)").foregroundColor(.secondary).font(.caption)
                                }
                                .padding(.horizontal, 7).padding(.vertical, 5)
                                .background((activeFacetSelections[selectedField] ?? []).contains(option.key) ? Color.accentColor.opacity(0.12) : Color.clear)
                                .cornerRadius(4)
                            }.buttonStyle(.plain)
                            .accessibilityLabel(option.displayName)
                            .accessibilityValue((activeFacetSelections[selectedField] ?? []).contains(option.key) ? "Selected, \(option.count) PRs" : "\(option.count) PRs")
                        }
                        if options.isEmpty { Text("No matching options").foregroundColor(.secondary).padding(12) }
                    }.padding(6)
                }
            }
        }
        .frame(height: 180)
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(item: $viewBeingRenamed) { view in
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename Saved View").font(.headline)
                TextField("View name", text: $renameName)
                HStack {
                    Spacer()
                    Button("Cancel") {
                        viewBeingRenamed = nil
                        renameName = ""
                    }
                    Button("Rename") {
                        actions.renameSavedView(view, renameName)
                        viewBeingRenamed = nil
                        renameName = ""
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 280)
        }
    }
}
