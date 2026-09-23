import SwiftUI

/// "Worth remembering": why recent attempts failed, each offered as a rule for
/// the project's CLAUDE.md. The next agent on the same task already receives
/// them; adding one to CLAUDE.md makes it apply to every session, and only a
/// click does that.
struct FlowLessonsSection: View {
    let lessons: [AttemptHistory.Lesson]
    let projectRoot: URL
    let openInPlan: (String) -> Void

    private static let handledKey = "flow.lessons.handled"
    @State private var handled = Set(UserDefaults.standard.stringArray(forKey: handledKey) ?? [])
    @State private var errorText: String?

    var body: some View {
        let open = lessons.filter { !handled.contains(key($0)) }
        if !open.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("WORTH REMEMBERING").font(.system(size: 10.5, weight: .semibold)).kerning(0.5)
                    .foregroundStyle(.secondary)
                Text("The next agent on the task already gets these. Add one to CLAUDE.md to apply it everywhere.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(open) { lesson in
                    VStack(alignment: .leading, spacing: 5) {
                        Button { openInPlan(lesson.taskID) } label: {
                            Text(verbatim: "\(lesson.taskID) · \(lesson.text)")
                                .font(.system(size: 11.5)).multilineTextAlignment(.leading).lineLimit(4)
                        }
                        .buttonStyle(.plain)
                        HStack(spacing: 8) {
                            Button("Add to CLAUDE.md") { add(lesson) }.controlSize(.small)
                            Button("Ignore") { markHandled(lesson) }.buttonStyle(.link).controlSize(.small)
                        }
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                }
                if let errorText {
                    Text(verbatim: errorText).font(.system(size: 11)).foregroundStyle(.red)
                }
            }
        }
    }

    private func key(_ lesson: AttemptHistory.Lesson) -> String { projectRoot.path + "|" + lesson.id }

    private func add(_ lesson: AttemptHistory.Lesson) {
        do {
            try AttemptHistory.appendToClaudeMd(lesson, projectRoot: projectRoot)
            markHandled(lesson)
        } catch {
            errorText = String(localized: "CLAUDE.md could not be written: \(error.localizedDescription)")
        }
    }

    private func markHandled(_ lesson: AttemptHistory.Lesson) {
        handled.insert(key(lesson))
        UserDefaults.standard.set(Array(handled), forKey: Self.handledKey)
    }
}
