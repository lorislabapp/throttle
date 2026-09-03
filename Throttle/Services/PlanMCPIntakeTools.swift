import Foundation

// Intake and viability, split from the task tools: bootstrapping a plan and
// filing sourced research answer a different question than running a task, and
// keeping them apart keeps either file readable.
extension PlanMCPTools {

    static func bootstrapText(project: String?) -> String {
        let path = project ?? FileManager.default.currentDirectoryPath
        let repo = URL(fileURLWithPath: path, isDirectory: true)
        let survey = ProjectIntakeService.survey(repo: repo)
        guard survey.shape != .planned else {
            return "Refused: this project already has a plan. Read it with throttle_plan_read."
        }
        let plan = PlanTemplate.starter(for: survey)
        do {
            try store(project).bootstrap(plan)
        } catch {
            return "Refused: could not write the plan — \(error)."
        }
        return """
        Created a plan for \(survey.title) (\(survey.shape.rawValue)).
        Observed: \(survey.observations.joined(separator: "; ")).
        \(plan.tasks.count) tasks. Read it with throttle_plan_read, then claim one.
        """
    }

    struct FindingRequest {
        var project: String?
        var pillar: String
        var claim: String
        var source: String
        var rating: Int
        var author: String
    }

    static func researchRecordText(_ request: FindingRequest) -> String {
        let project = request.project
        let claim = request.claim
        guard let pillarValue = ViabilityPillar(rawValue: request.pillar) else {
            return "Refused: pillar must be one of "
                + ViabilityPillar.allCases.map(\.rawValue).joined(separator: ", ") + "."
        }
        let path = project ?? FileManager.default.currentDirectoryPath
        let repo = URL(fileURLWithPath: path, isDirectory: true)
        let projectId = (try? store(project).loadPlan().projectId) ?? ""
        let finding = ResearchFinding(pillar: pillarValue, claim: claim,
                                      source: request.source, rating: request.rating,
                                      recordedBy: request.author)
        do {
            let dossier = try ResearchDossierStore(projectRoot: repo)
                .record(finding, projectId: projectId)
            return "Recorded under \(pillarValue.label). "
                + "\(dossier.findings.count) finding(s) in the dossier.\n"
                + verdictLine(ViabilityScorer.assess(dossier))
        } catch ResearchDossierError.sourceRequired {
            return "Refused: a finding needs a source the user can check."
        } catch ResearchDossierError.claimRequired {
            return "Refused: a finding needs a claim."
        } catch {
            return "Refused: could not write the dossier — \(error)."
        }
    }

    static func viabilityText(project: String?) -> String {
        let path = project ?? FileManager.default.currentDirectoryPath
        let repo = URL(fileURLWithPath: path, isDirectory: true)
        let dossier = ResearchDossierStore(projectRoot: repo).load()
        guard !dossier.findings.isEmpty else {
            return "The viability dossier is empty. Record findings with throttle_research_record."
        }
        var out: [String] = ["VIABILITY DOSSIER"]
        for pillar in ViabilityPillar.allCases {
            let items = dossier.findings(for: pillar)
            out.append("")
            out.append("\(pillar.label.uppercased()) — \(items.count) finding(s)")
            for item in items {
                out.append("  [\(item.rating)/3] \(item.claim)")
                out.append("        source: \(item.source)")
            }
        }
        out.append("")
        out.append(verdictLine(ViabilityScorer.assess(dossier)))
        return out.joined(separator: "\n")
    }

    private static func verdictLine(_ assessment: ViabilityAssessment) -> String {
        switch assessment {
        case .insufficientEvidence(let missing):
            return "VERDICT: insufficient evidence — nothing sourced yet for "
                + missing.map(\.label).joined(separator: ", ") + "."
        case .scored(let score, let byPillar, let sources):
            let detail = ViabilityPillar.allCases.compactMap { pillar -> String? in
                guard let value = byPillar[pillar] else { return nil }
                return String(format: "%@ %.1f/3", pillar.label, value)
            }.joined(separator: " · ")
            return "VERDICT: \(score)/100 across \(sources) distinct source(s) — \(detail)."
        }
    }

}

// MARK: - Transport routing

extension PlanMCPTools {
    /// Bootstrap is the sole useful plan command before a plan exists.
    static var advertisedSchemas: [[String: Any]] {
        hasPlan() ? schemas : [planBootstrapSchema()]
    }

    static func routeCall(
        name: String,
        arguments: [String: Any]?,
        id: Any?
    ) {
        routeCall(
            name: name,
            arguments: arguments,
            onResult: { ThrottleMCPServer.respond(id: id, result: ThrottleMCPServer.textResult($0)) },
            onError: { ThrottleMCPServer.respond(id: id, error: $0) }
        )
    }

    static func routeCall(
        name: String, arguments: [String: Any]?,
        onResult: (String) -> Void, onError: ([Any]) -> Void
    ) {
        switch name {
        case "throttle_plan_bootstrap", "throttle_research_record", "throttle_viability_read":
            routeIntakeCall(name, arguments, onResult, onError)
        case "throttle_task_verdict", "throttle_plan_read", "throttle_task_claim", "throttle_task_event":
            routeTaskCall(name, arguments, onResult, onError)
        default:
            onError([-32602, "Unknown tool: \(name)"])
        }
    }

    private static func routeIntakeCall(
        _ name: String, _ args: [String: Any]?,
        _ result: (String) -> Void, _ error: ([Any]) -> Void
    ) {
        switch name {
        case "throttle_plan_bootstrap":
            result(bootstrapText(project: args?["project"] as? String))
        case "throttle_research_record":
            guard let pillar = args?["pillar"] as? String,
                  let claim = args?["claim"] as? String,
                  let source = args?["source"] as? String,
                  let author = args?["by"] as? String else {
                error([-32602, "Missing pillar, claim, source or by"]); return
            }
            result(researchRecordText(FindingRequest(
                project: args?["project"] as? String, pillar: pillar, claim: claim,
                source: source, rating: (args?["rating"] as? Int) ?? 0, author: author
            )))
        default:
            result(viabilityText(project: args?["project"] as? String))
        }
    }

    private static func routeTaskCall(
        _ name: String, _ args: [String: Any]?,
        _ result: (String) -> Void, _ error: ([Any]) -> Void
    ) {
        switch name {
        case "throttle_task_verdict":
            guard let taskID = args?["task_id"] as? String,
                  let author = args?["by"] as? String,
                  let verdict = args?["verdict"] as? String else {
                error([-32602, "Missing task_id, by or verdict"]); return
            }
            result(verdictText(VerdictRequest(
                project: args?["project"] as? String, taskID: taskID, author: author,
                verdict: verdict, reason: args?["reason"] as? String,
                summary: args?["summary"] as? String
            )))
        case "throttle_plan_read":
            result(planReadText(project: args?["project"] as? String))
        case "throttle_task_claim":
            guard let taskID = args?["task_id"] as? String,
                  let author = args?["by"] as? String else {
                error([-32602, "Missing task_id or by"]); return
            }
            result(claimText(project: args?["project"] as? String, taskID: taskID,
                             author: author, missionID: args?["mission_id"] as? String))
        default:
            routeEventCall(args, result, error)
        }
    }

    private static func routeEventCall(
        _ args: [String: Any]?, _ result: (String) -> Void, _ error: ([Any]) -> Void
    ) {
        guard let taskID = args?["task_id"] as? String,
              let author = args?["by"] as? String,
              let type = args?["type"] as? String else {
            error([-32602, "Missing task_id, by or type"]); return
        }
        result(eventText(EventRequest(
            project: args?["project"] as? String, taskID: taskID, author: author, type: type,
            pct: args?["pct"] as? Int, note: args?["note"] as? String,
            kind: args?["kind"] as? String, ref: args?["ref"] as? String,
            reason: args?["reason"] as? String, summary: args?["summary"] as? String
        )))
    }
}
