import Foundation

// Intake and viability, split from the task tools: bootstrapping a plan and
// filing sourced research answer a different question than running a task, and
// keeping them apart keeps either file readable.
extension PlanMCPTools {

    static func bootstrapText(project: String?, authorizeMutation: () -> String? = { nil }) -> String {
        if let refusal = authorizeMutation() { return refusal }
        let path = project ?? FileManager.default.currentDirectoryPath
        let repo = URL(fileURLWithPath: path, isDirectory: true)
        let survey = ProjectIntakeService.survey(repo: repo)
        guard survey.shape != .planned else {
            return "Refused: this project already has a plan. Read it with throttle_plan_read."
        }
        let plan = PlanTemplate.starter(for: survey)
        do {
            return try store(project).mutate { store in
                if let refusal = authorizeMutation() { return refusal }
                try store.bootstrap(plan)
                return "Created a plan for \(survey.title) (\(survey.shape.rawValue)). "
                    + "\(plan.tasks.count) tasks. Read it with throttle_plan_read, then claim one."
            }
        } catch {
            return "Refused: could not write the plan — \(error)."
        }

    }

    struct FindingRequest {
        var project: String?
        var pillar: String
        var claim: String
        var source: String
        var rating: Int
        var author: String
        var authorizeMutation: () -> String? = { nil }
    }

    static func researchRecordText(_ request: FindingRequest) -> String {
        if let refusal = request.authorizeMutation() { return refusal }
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
                .record(finding, projectId: projectId, authorizeMutation: request.authorizeMutation)
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
        guard let dossier = try? ResearchDossierStore(projectRoot: repo).loadValidated() else {
            return "Refused: the research dossier is unreadable or corrupt."
        }
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
        var result = hasPlan() ? schemas : [planBootstrapSchema()]
        result.append(ProjectKnowledgeMCP.schema)
        return result
    }

    static func routeCall(
        name: String, arguments: [String: Any]?,
        authority: Result<PlanMCPAuthority?, PlanMCPAuthority.Failure>? = nil,
        onResult: (String) -> Void, onError: ([Any]) -> Void
    ) {
        switch name {
        case "throttle_project_explore":
            onResult(ProjectKnowledgeMCP.call(arguments))
        case "throttle_plan_bootstrap", "throttle_research_record", "throttle_viability_read":
            routeIntakeCall(name, arguments, authority: authority, onResult, onError)
        case "throttle_task_verdict", "throttle_plan_read", "throttle_task_claim", "throttle_task_event":
            routeTaskCall(name, arguments, authority: authority, onResult, onError)
        default:
            onError([-32602, "Unknown tool: \(name)"])
        }
    }

    private static func routeIntakeCall(
        _ name: String, _ args: [String: Any]?,
        authority: Result<PlanMCPAuthority?, PlanMCPAuthority.Failure>?,
        _ result: (String) -> Void, _ error: ([Any]) -> Void
    ) {
        let authorize = pinnedAuthorization(name, args, load: { authority ?? processAuthority })
        if let refusal = authorize() { result(refusal); return }
        switch name {
        case "throttle_plan_bootstrap":
            result(bootstrapText(project: args?["project"] as? String, authorizeMutation: authorize))
        case "throttle_research_record":
            guard let pillar = args?["pillar"] as? String,
                  let claim = args?["claim"] as? String,
                  let source = args?["source"] as? String,
                  let author = args?["by"] as? String else {
                error([-32602, "Missing pillar, claim, source or by"]); return
            }
            result(researchRecordText(FindingRequest(
                project: args?["project"] as? String, pillar: pillar, claim: claim,
                source: source, rating: (args?["rating"] as? Int) ?? 0, author: author, authorizeMutation: authorize
            )))
        default:
            result(viabilityText(project: args?["project"] as? String))
        }
    }

}
