import CmuxFoundation
import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// Returns the last accepted cwd for a stale Cloud terminal, when its identity still exists.
    ///
    /// A stale graph is useful display state, but a resource row can also contain an optimistic
    /// requested cwd. Read the cached value from the accepted graph so that a request, a retired
    /// provider, or a resource whose identity disappeared cannot become a displayed path.
    private func acceptedStaleCloudDirectory(for resource: SurfaceResource) -> String? {
        guard resource.kind == .terminal,
              resource.machine.tuiMachineID != nil,
              cloudStateObservations[resource.machine]?.freshness == .stale,
              let directory = cloudStates[resource.machine]?.lookupIndex.terminal(id: resource.id.key)?.cwd else {
            return nil
        }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Retain stale graphs for diagnostics while presenting a previously accepted cwd as a
    /// cached value. A requested launch directory or a stale graph with no accepted cwd remains
    /// unavailable.
    func resourceForPresentation(_ resource: SurfaceResource) -> SurfaceResource {
        if resource.kind == .browser { return resourceWithCloudBrowserDocument(resource) }
        // Cloud VM freshness is tracked in `cloudStateObservations`; device
        // mirrors receive their directory from the synced workspace record and
        // intentionally have no CloudVM observation to consult.
        guard resource.kind == .terminal, resource.machine.tuiMachineID != nil else { return resource }
        guard cloudStateObservations[resource.machine]?.freshness != .current else { return resource }
        var result = resource
        result.detail = acceptedStaleCloudDirectory(for: resource)
        return result
    }

    /// Projects accepted directory and machine metadata independently from name reconciliation.
    /// The catalog remains authoritative; Workspace owns only the UI-facing projection.
    func updateCloudDirectoryMetadata(on machine: SurfaceMachineID, affectedResourceIDs: Set<SurfaceResourceID>? = nil) {
        guard !machine.isLocal else { return }
        let machineProjections = projections.filter {
            $0.resource.machine == machine && (affectedResourceIDs?.contains($0.resource) ?? true)
        }
        let projectedWorkspaceIDs = Set(machineProjections.map(\.workspaceID))
        if let affectedResourceIDs {
            // Group the complete projection set once. The workspace updater
            // needs all of a workspace's rows to preserve existing bindings,
            // but an incremental resource update must not rescan and sort the
            // global projection list once per affected workspace.
            let recordsByWorkspace = Dictionary(grouping: projections.filter { !$0.resource.machine.isLocal }) {
                $0.workspaceID
            }.mapValues { projections in
                projections.map {
                    SurfaceProjectionRecord(
                        panelID: $0.panelID,
                        resource: $0.resource,
                        remoteWorkspaceID: $0.remoteWorkspaceID,
                        remoteTabID: $0.remoteTabID
                    )
                }
            }
            for id in projectedWorkspaceIDs {
                guard let workspace = cloudWorkspaceRenameService.environment.workspace(id) else { continue }
                updateCloudDirectoryMetadata(
                    in: workspace,
                    affectedResourceIDs: affectedResourceIDs,
                    projected: recordsByWorkspace[id] ?? []
                )
            }
            return
        }
        for workspace in cloudWorkspaceRenameService.environment.workspaces()
            where (machine.tuiMachineID != nil && workspace.cloudVMBinding?.vmID == machine.tuiMachineID) || projectedWorkspaceIDs.contains(workspace.id)
                || workspace.cloudBindingState.projectedResources.values.contains(where: { $0.machine == machine }) {
            updateCloudDirectoryMetadata(in: workspace)
        }
    }

    func updateCloudDirectoryMetadata(localWorkspaceID: UUID) {
        guard let workspace = cloudWorkspaceRenameService.environment.workspace(localWorkspaceID) else { return }
        updateCloudDirectoryMetadata(in: workspace)
    }

    private func updateCloudDirectoryMetadata(
        in workspace: Workspace,
        affectedResourceIDs: Set<SurfaceResourceID>? = nil,
        projected suppliedProjections: [SurfaceProjectionRecord]? = nil
    ) {
        // Saved projections establish ownership even before their provider rediscovers the resource.
        let projected = (suppliedProjections ?? projectionRecords(forWorkspace: workspace.id))
            .filter { !$0.resource.machine.isLocal }
        let resourcesByPanel = Dictionary(projected.map { ($0.panelID, $0.resource) }, uniquingKeysWith: { first, _ in first })
        var machineIDs = Set(projected.map { $0.resource.machine.rawValue })
        if let id = workspace.cloudVMID { machineIDs.insert(id) }
        let names = Dictionary(uniqueKeysWithValues: machineIDs.map { id in
            (id, machines[SurfaceMachineID(rawValue: id)]?.name ?? id)
        })
        let previous = workspace.cloudBindingState.projectedResources
        let previousHostLabel = workspace.hostLabel
        // The sidebar hides a panel whose terminal row is missing or still launching, so the row's
        // arrival and readiness are presentation inputs even when the projection, names and cwd
        // stay the same. Without them the workspace row stays blank until an unrelated change.
        let terminalLifecycles = Dictionary(projected.compactMap { projection -> (UUID, SurfaceLifecycle)? in
            guard let resource = resources[projection.resource], resource.kind == .terminal else { return nil }
            return (projection.panelID, resource.lifecycle)
        }, uniquingKeysWith: { first, _ in first })
        workspace.cloudBindingState.updateCatalogMetadata(
            resources: resourcesByPanel, machineNames: names, terminalLifecycles: terminalLifecycles
        )
        if workspace.hostLabel != previousHostLabel {
            workspace.owningTabManager?.workspaceHostLabelDidChange(workspace)
        }
        for panelID in previous.keys where resourcesByPanel[panelID] == nil && workspace.panels[panelID] != nil {
            workspace.clearRemotePanelDirectory(panelId: panelID)
        }
        for projection in projected where workspace.panels[projection.panelID] != nil {
            if let affectedResourceIDs, !affectedResourceIDs.contains(projection.resource) { continue }
            let machine = projection.resource.machine
            let resource = resources[projection.resource]
            let current = cloudStateObservations[machine]?.freshness == .current
            let directory: String?
            if machine.deviceInstance != nil {
                directory = resource?.kind == .terminal ? resource?.detail : nil
            } else if let resource, resource.kind == .terminal {
                // A shell that never reports its directory leaves the graph at the
                // spawn directory; the live answer wins until it does report.
                directory = current
                    ? fallbackCloudDirectory(for: projection.resource)
                        ?? cloudStates[machine]?.lookupIndex.terminal(id: projection.resource.key)?.cwd
                    : acceptedStaleCloudDirectory(for: resource)
            } else {
                directory = nil
            }
            if let directory, workspace.reportedPanelDirectory(panelId: projection.panelID) == directory { continue }
            workspace.updateCloudPanelDirectory(panelId: projection.panelID, directory: directory)
        }
    }
}

/// The Files panel follows a cmux-tui terminal's graph `cwd`, which moves only when the
/// remote shell reports its directory. For a terminal whose shell never does (fish, a
/// configured command, a shell started before its hook was installed), ask the daemon
/// for the foreground process's directory instead: when the terminal is shown and when
/// its title changes (graph or the terminal's own output), one query per terminal at a
/// time, starts at least a second apart, each bounded to 3 s, over an already connected
/// link only. No timer. Inside tmux the foreground process is the tmux client, whose
/// directory never moves, so that answer is skipped.
extension SurfaceCatalog {
    nonisolated static let cloudDirectoryProbeTimeout: Duration = .seconds(3)

    /// Starts the queries a newly accepted, current graph calls for.
    func observeCloudTerminalDirectories(in state: CloudVMState, observation: CloudVMStateObservation) {
        let machine = state.machine
        guard observation.freshness == .current, machine.tuiMachineID != nil else { return }
        let environment = cloudWorkspaceRenameService.environment
        let shown = Set(projections.lazy.filter {
            $0.resource.machine == machine && $0.resource.kind == .terminal
                && environment.workspace($0.workspaceID)?.usesSSHTui == true
        }.map(\.resource.key))
        guard !shown.isEmpty || cloudDirectoryFallbacks[machine] != nil else { return }
        var fallback = cloudDirectoryFallbacks[machine] ?? CloudTerminalDirectoryFallback()
        let probes = fallback.observe(state.terminals, projected: shown, now: ProcessInfo.processInfo.systemUptime)
        cloudDirectoryFallbacks[machine] = fallback
        for probe in probes { startCloudDirectoryProbe(probe, on: machine) }
    }

    /// A title the terminal's own output set, as its local surface shows it. The daemon
    /// publishes no graph event for a title change, so this is what asks again after
    /// a `cd` in a shell that sets a `user@host: dir` title but never reports its
    /// directory. Terminals the fallback does not track ask nothing.
    func cloudTerminalTitleDidChange(_ resource: SurfaceResourceID, title: String) {
        guard resource.kind == .terminal, resource.machine.tuiMachineID != nil,
              cloudStateObservations[resource.machine]?.freshness == .current,
              var fallback = cloudDirectoryFallbacks[resource.machine] else { return }
        let probe = fallback.terminalTitleChanged(title, terminalID: resource.key, now: ProcessInfo.processInfo.systemUptime)
        cloudDirectoryFallbacks[resource.machine] = fallback
        if let probe { startCloudDirectoryProbe(probe, on: resource.machine) }
    }

    /// The live directory for a terminal that does not report its own, if one was found.
    func fallbackCloudDirectory(for resource: SurfaceResourceID) -> String? {
        cloudDirectoryFallbacks[resource.machine]?.directory(forTerminal: resource.key)
    }

    /// Forgets the machine's queries and answers when its graph goes away.
    func dropCloudDirectoryFallback(on machine: SurfaceMachineID) {
        cloudDirectoryFallbacks[machine] = nil
        for (id, task) in cloudDirectoryProbeTasks where id.machine == machine {
            task.cancel()
            cloudDirectoryProbeTasks[id] = nil
        }
    }

    private func startCloudDirectoryProbe(_ probe: CloudTerminalDirectoryFallback.Probe, on machine: SurfaceMachineID) {
        let id = SurfaceResourceID(machine: machine, kind: .terminal, key: probe.terminalID)
        guard let resource = resources[id], provider(for: machine) != nil else {
            finishCloudDirectoryProbe(probe, id: id, answer: .skipped)
            return
        }
        cloudDirectoryProbeTasks[id]?.cancel()
        let live: @MainActor @Sendable () async -> CloudTerminalDirectoryFallback.Answer = { [weak self] in
            guard let provider = self?.provider(for: machine) else { return .skipped }
            return await provider.foregroundDirectoryAnswer(of: resource)
        }
        cloudDirectoryProbeTasks[id] = Task { [weak self] in
            // Spacing between a terminal's queries, so a fast-changing title cannot
            // turn into back-to-back requests.
            if probe.delay > 0 {
                do { try await Task.sleep(for: .seconds(probe.delay)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let answer = await withTaskGroup(of: CloudTerminalDirectoryFallback.Answer.self) { group in
                group.addTask { await live() }
                group.addTask {
                    try? await Task.sleep(for: SurfaceCatalog.cloudDirectoryProbeTimeout)
                    return .failed
                }
                let first = await group.next() ?? .failed
                group.cancelAll()
                return first
            }
            guard let self, !Task.isCancelled else { return }
            self.finishCloudDirectoryProbe(probe, id: id, answer: answer)
        }
    }

    private func finishCloudDirectoryProbe(
        _ probe: CloudTerminalDirectoryFallback.Probe,
        id: SurfaceResourceID,
        answer: CloudTerminalDirectoryFallback.Answer
    ) {
        guard var fallback = cloudDirectoryFallbacks[id.machine] else { return }
        let result = fallback.finish(probe, answer: answer, now: ProcessInfo.processInfo.systemUptime)
        cloudDirectoryFallbacks[id.machine] = fallback
        cloudDirectoryProbeTasks[id] = nil
        if let next = result.next { startCloudDirectoryProbe(next, on: id.machine) }
        if result.directoryChanged { updateCloudDirectoryMetadata(on: id.machine, affectedResourceIDs: [id]) }
    }
}
