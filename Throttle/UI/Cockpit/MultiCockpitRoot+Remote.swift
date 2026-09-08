import AppKit
import SwiftUI
import ThrottleShared

extension MultiCockpitRoot {
    /// Stop locally before starting the remote writer. Keep the tab locked for
    /// the complete transfer, including the network wait, to prevent a local wake.
    func offloadTab(_ session: CockpitTab) {
        guard !model.isQuitting, !session.isTransitioning, !session.hasRemoteOwnership else { return }
        session.isTransferring = true
        Task {
            defer { session.isTransferring = false; model.persist() }
            if let remoteID = await remoteSvc.transferToServer(session) { selectedRemoteID = remoteID }
        }
    }

    func bringBack(_ session: CockpitTab) {
        guard !model.isQuitting, !session.isTransitioning, let remoteID = session.offloadedRemoteID,
              let nativeID = session.sessionId else { return }
        guard !model.sessions.contains(where: {
            $0 !== session && $0.runtime == session.runtime && $0.isSpawned
                && ($0.isChoosingNativeSession || $0.sessionId?.caseInsensitiveCompare(nativeID) == .orderedSame)
            }),
            let reservation = RemoteTransferReservation.acquire(
                runtime: session.remoteRuntime, nativeID: nativeID)
        else {
            remoteSvc.offloadStatus =
                "Another local tab is using or transferring this conversation. Stop it before returning."
            return
        }
        session.isTransferring = true
        Task {
            defer {
                RemoteTransferReservation.release(
                    runtime: session.remoteRuntime, nativeID: nativeID, token: reservation)
            }
            guard await session.hibernate() else {
                session.isTransferring = false
                remoteSvc.offloadStatus = session.stopIssue
                return
            }
            let sessionID = await remoteSvc.bringBack(remoteID: remoteID, localCwd: session.cwd)
            session.isTransferring = false
            if let sessionID {
                session.offloadedRemoteID = nil
                session.sessionId = sessionID
                selectedRemoteID = nil
                // No suspension between releasing the reservation and launching
                // this exact tab. Aliases stayed blocked through service refresh.
                RemoteTransferReservation.release(
                    runtime: session.remoteRuntime, nativeID: nativeID, token: reservation)
                model.wake(session.id)
            }
            model.persist()
        }
    }

    /// Remote sessions NOT owned by any local tab (started from the sheet or
    /// another device). Owned ones are represented by their local row's badge.
    var orphanRemotes: [EdgeAgentService.RemoteSession] {
        remoteSvc.sessions.filter { rs in
            !model.sessions.contains { $0.offloadedRemoteID == rs.id }
        }
    }

    /// Rail row for a session running on the edge box. Deliberately lighter than
    /// the local rows (no RAM bar, no question feed — the box owns those), with an
    /// unmissable REMOTE badge answering "is this on my Mac or the server?".
    func remoteRailRow(_ rs: EdgeAgentService.RemoteSession) -> some View {
        let on = rs.id == selectedRemoteID
        return Button { selectedRemoteID = rs.id } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle().fill(rs.state == "working" ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(rs.project).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(on ? .primary : .secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    remoteChip
                }
                HStack(spacing: 8) {
                    if let m = rs.model { modelChip(m) }
                    if let t = rs.tokens, t > 0 {
                        Text(fmtTok(t)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Text(rs.state).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay { if on { RoundedRectangle(cornerRadius: 9).stroke(hair, lineWidth: 1) } }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityLabel(String.localizedStringWithFormat(
            String(localized: "Remote session %@, %@"), rs.project, rs.state))
        .contextMenu {
            Button("Pause") { Task { await remoteSvc.act(rs.id, "pause") } }
            Button("Resume") { Task { await remoteSvc.act(rs.id, "resume") } }
            Divider()
            Button("Stop session") {
                Task {
                    await remoteSvc.act(rs.id, "stop")
                    if selectedRemoteID == rs.id { selectedRemoteID = nil }
                }
            }
        }
    }

    var remoteChip: some View {
        Text("REMOTE")
            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            .padding(.horizontal, 4.5).padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(Color.accentColor)
    }

    func railRow(_ s: CockpitTab) -> some View {
        let on = s.id == model.active?.id
        // Offloaded-and-alive tabs open their REMOTE terminal, not the (hibernated)
        // local one — one row, one session, wherever it currently runs.
        let liveRemoteID = s.offloadedRemoteID.flatMap { rid in
            remoteSvc.sessions.contains(where: { $0.id == rid }) ? rid : nil
        }
        return Button {
            if let rid = liveRemoteID { selectedRemoteID = rid } else { model.wake(s.id) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    stateDot(s)
                    Text(s.projectName).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(on ? .primary : .secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if liveRemoteID != nil {
                        remoteChip
                    } else if s.isHibernated {
                        hibernatedChip
                    } else if s.needsInput {
                        waitingChip()
                    }
                    if let model = s.model { modelChip(model) }
                }
                if s.needsInput, let q = s.latestQuestion {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "arrow.turn.down.left").font(.system(size: 9, weight: .semibold))
                        Text(q).font(.system(size: 10.5)).lineLimit(2)
                    }.foregroundStyle(.orange)
                }
                sessionDiagnostics(s)
                questionFeed(s)
                sessionMetricsRow(s)
                sessionResourceRow(s)
            }
            .padding(.horizontal, 10).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay { if on { RoundedRectangle(cornerRadius: 9).stroke(hair, lineWidth: 1) } }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(railRowA11yLabel(s))
        .accessibilityAddTraits(s.id == model.active?.id ? [.isButton, .isSelected] : .isButton)
        .contextMenu { sessionMenu(s) }
        .overlay(alignment: .topTrailing) { railHoverActions(s) }
        .onHover { hoveredSession = $0 ? s.id : nil }
        .draggable(s.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let str = items.first, let dragged = UUID(uuidString: str) else { return false }
            model.move(dragged: dragged, onto: s.id)
            return true
        }
    }

    @ViewBuilder
    private func railHoverActions(_ session: CockpitTab) -> some View {
        if hoveredSession == session.id {
            // A solid cluster covers the model badge under the hovered actions.
            HStack(spacing: 9) {
                railAction("chart.bar.doc.horizontal", 11.5, .secondary, "Project stats + CLAUDE.md optimizer") {
                    ProjectWindowController.shared.show(
                        appState: appState, projectID: MultiCockpitModel.claudeProjectDirName(session.cwd))
                }
                if session.isSpawned {
                    railAction(session.isPaused ? "play.fill" : "pause.fill", 11,
                               session.isPaused ? .purple : .secondary,
                               session.isPaused ? "Resume — unfreeze this session"
                                   : "Pause — freeze this session (keeps state)") {
                        session.isPaused ? session.resumeProcess() : session.pauseProcess(reason: .user)
                    }
                    railAction("moon.zzz.fill", 12, .secondary, hibernateActionLabel(session)) {
                        Task { await model.hibernate(session.id) }
                    }
                }
                railAction("xmark.circle.fill", 13, .secondary, "Close session") {
                    Task { await model.close(session.id) }
                }
                // Also expose the context menu through a visible action.
                Menu {
                    sessionMenu(session)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More actions — switch model, offload to server…")
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(hair, lineWidth: 0.5))
            .padding(5)
        }
    }

}
