import SwiftUI

/// "New project space…" under the spaces: names a project, creates its space,
/// then opens the folder picker — the whole path to a project's first research
/// in one place, instead of a space that only appears once research exists.
struct NewProjectSpaceButton: View {
    let model: ResearchVaultWorkbenchModel
    let isEnabled: Bool
    @State private var isAsking = false
    @State private var name = ""

    var body: some View {
        Button {
            name = ""
            isAsking = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.rectangle.on.folder")
                Text("New project space…").font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tint)
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(isEnabled ? String(localized: "Create a space for a project, then add its research folder")
                        : String(localized: "Turn the vault on first"))
        .popover(isPresented: $isAsking, arrowEdge: .trailing) { form }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New project space").font(.system(size: 14, weight: .semibold))
            Text("Name the project. Next, choose the folder that holds its research.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("e.g. Eclair", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            if let key = ResearchVaultWorkbenchModel.spaceKey(for: name) {
                Text("Space: \(key)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isAsking = false }
                Button("Create and choose folder…", action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ResearchVaultWorkbenchModel.spaceKey(for: name) == nil)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func create() {
        guard model.createProjectSpace(named: name) else { return }
        isAsking = false
        Task { await model.chooseFolderSource() }
    }
}
