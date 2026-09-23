import Foundation

/// Builds the starting plan for a project, shaped by what is actually in the
/// directory.
///
/// The template's job is to ask the right questions in the right order, not to
/// pretend it knows the answers: every task it creates is work for an agent or
/// for the user, and none of them are marked done.
enum PlanTemplate {

    static func starter(for survey: ProjectIntakeService.Survey,
                        projectId: String = UUID().uuidString) -> Plan {
        switch survey.shape {
        case .empty:       return greenfield(survey, projectId: projectId)
        case .unplannedCode: return existingCode(survey, projectId: projectId)
        case .planned:     return Plan(projectId: projectId, title: survey.title, tasks: [])
        }
    }

    // MARK: - Nothing here yet

    /// An empty directory means the product is undecided, so the plan starts with
    /// the idea and refuses to reach `build` before viability has been answered.
    private static func greenfield(_ survey: ProjectIntakeService.Survey,
                                   projectId: String) -> Plan {
        var tasks: [PlanTask] = [
            PlanTask(id: "P1", order: 0, title: "Idea", kind: .decision),
            PlanTask(id: "T1.1", parent: "P1", order: 0,
                     title: "Write down the idea, who it is for, and what it refuses to be",
                     kind: .decision),
            PlanTask(id: "T1.2", parent: "P1", order: 1,
                     title: "Name the constraints: platform, budget, time, skills",
                     kind: .decision, dependsOn: ["T1.1"])
        ]
        tasks.append(contentsOf: viability(parent: "P2", order: 1, dependsOn: ["T1.2"]))
        tasks.append(contentsOf: [
            PlanTask(id: "P3", order: 2, title: "Build", kind: .build),
            PlanTask(id: "T3.1", parent: "P3", order: 0,
                     title: "Decompose the first slice into tasks an agent can finish alone",
                     kind: .decision, dependsOn: ["T2.5"], sotaGate: true)
        ])
        return Plan(projectId: projectId, title: survey.title, tasks: tasks)
    }

    // MARK: - Code, no plan

    /// Code already answers the "what is it" question. What is unknown is where it
    /// stands, so the plan starts by reading rather than by deciding.
    private static func existingCode(_ survey: ProjectIntakeService.Survey,
                                     projectId: String) -> Plan {
        let languages = survey.languages.prefix(2).joined(separator: " and ")
        var tasks: [PlanTask] = [
            PlanTask(id: "P1", order: 0, title: "Read what is already here", kind: .audit),
            PlanTask(id: "T1.1", parent: "P1", order: 0,
                     title: "Map the codebase: entry points, boundaries, what it actually does"
                        + (languages.isEmpty ? "" : " (\(languages))"),
                     kind: .audit),
            PlanTask(id: "T1.2", parent: "P1", order: 1,
                     title: "List what is unfinished, broken, or contradicted by the docs",
                     kind: .audit, dependsOn: ["T1.1"])
        ]
        tasks.append(contentsOf: viability(parent: "P2", order: 1, dependsOn: ["T1.2"]))
        tasks.append(contentsOf: [
            PlanTask(id: "P3", order: 2, title: "Close the gap", kind: .build),
            PlanTask(id: "T3.1", parent: "P3", order: 0,
                     title: "Turn the ranked gaps into tasks an agent can finish alone",
                     kind: .decision, dependsOn: ["T2.5"], sotaGate: true)
        ])
        return Plan(projectId: projectId, title: survey.title, tasks: tasks)
    }

    // MARK: - Shared viability phase

    /// The dossier the user asked for: feasibility, competitors, what is being
    /// missed, and only then a verdict. Each is a separate task because each has a
    /// different failure mode, and the verdict depends on all of them.
    private static func viability(parent: String, order: Int, dependsOn: [String]) -> [PlanTask] {
        [
            PlanTask(id: parent, order: order, title: "Viability", kind: .research),
            PlanTask(id: "T2.1", parent: parent, order: 0,
                     title: "Feasibility: what is provably buildable, and what is not",
                     kind: .research, dependsOn: dependsOn, sotaGate: true),
            PlanTask(id: "T2.2", parent: parent, order: 1,
                     title: "Competitors: who ships this, what they charge, how they position it",
                     kind: .research, dependsOn: dependsOn, sotaGate: true),
            PlanTask(id: "T2.3", parent: parent, order: 2,
                     title: "What their users complain about, in their own words",
                     kind: .research, dependsOn: ["T2.2"], sotaGate: true),
            PlanTask(id: "T2.4", parent: parent, order: 3,
                     title: "Missed opportunities: what nobody in this space does yet",
                     kind: .research, dependsOn: ["T2.2", "T2.3"], sotaGate: true),
            // Deliberately last and gated: a verdict written before the evidence
            // is an opinion with a number attached.
            PlanTask(id: "T2.5", parent: parent, order: 4,
                     title: "Verdict: chances of success and of making money, from the evidence above",
                     kind: .decision, dependsOn: ["T2.1", "T2.4"], sotaGate: true)
        ]
    }
}
