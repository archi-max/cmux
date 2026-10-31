import CmuxCloud
import Foundation
import Testing

/// The Mac side of `cmux open` from a cmux-tui SSH terminal: which rows are
/// requests, which pane may open them, and what the host is told.
/// `CmuxTuiSurfaceProvider` feeds every accepted state through this and only
/// executes its actions.
@Suite("cmux open ingress on the Mac")
struct SSHTuiHostOpenIngressTests {
    static let machineID = "ssh:abc"
    static let terminalID = "term_0123456789abcdef0123456789abcdef"
    static let workspaceID = UUID()
    static let panelID = UUID()
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A live request opens in the pane showing its terminal and is answered ok after the open")
    func liveRequestOpens() {
        var ingress = SSHTuiHostOpenIngress(machineID: Self.machineID)
        _ = plan(&ingress, rows: [])
        let row = Self.row("notification_00000000000000000000000000000001")
        #expect(plan(&ingress, rows: [row]) == [
            .open(rowID: row.id, path: "/home/u/top.sv", workspaceID: Self.workspaceID, panelID: Self.panelID),
        ])
        // Already handled: the next state (before the answer lands) does not reopen it.
        #expect(plan(&ingress, rows: [row]).isEmpty)
    }

    @Test("Age is measured on the Mac: a live row with a skewed host clock still opens")
    func skewedHostClockStillOpens() {
        var ingress = SSHTuiHostOpenIngress(machineID: Self.machineID)
        _ = plan(&ingress, rows: [])
        let skewed = Self.row("notification_00000000000000000000000000000002", hostAge: 3_600)
        #expect(plan(&ingress, rows: [skewed]).first?.isOpen == true)
    }

    @Test("A request already present when the feed starts is a replay: opened only when its host time is recent")
    func baselineRowsNeedRecentHostTime() {
        var ingress = SSHTuiHostOpenIngress(machineID: Self.machineID)
        let old = Self.row("notification_00000000000000000000000000000003", hostAge: SSHTuiHostOpenIngress.replayWindow + 1)
        let recent = Self.row("notification_00000000000000000000000000000004", hostAge: 5)
        let actions = plan(&ingress, rows: [old, recent])
        #expect(actions.contains(.answer(rowID: old.id, .stale)))
        #expect(actions.contains { $0.isOpen && $0.rowID == recent.id })
        #expect(!actions.contains { $0.isOpen && $0.rowID == old.id })
    }

    @Test("A row that already carries an answer, or the CLI's cancel, is never acted on")
    func answeredRowsAreIgnored() {
        for answer in ["cmux-open:ok", "cmux-open:refused:type", SSHTuiHostOpenAnswer.cancelledClientID] {
            var ingress = SSHTuiHostOpenIngress(machineID: Self.machineID)
            _ = plan(&ingress, rows: [])
            #expect(plan(&ingress, rows: [Self.row("notification_00000000000000000000000000000005", readBy: ["mac-1", answer])]).isEmpty)
        }
        // A phone's read is not an answer.
        var ingress = SSHTuiHostOpenIngress(machineID: Self.machineID)
        _ = plan(&ingress, rows: [])
        #expect(plan(&ingress, rows: [Self.row("notification_00000000000000000000000000000006", readBy: ["phone-7"])]).first?.isOpen == true)
    }

    @Test("The placement must be a workspace of this SSH machine that is the projection's own workspace")
    func placementChecks() {
        let other = UUID()
        let wrong: [(String, SSHTuiHostOpenPlacement)] = [
            ("workspace lookup returned another workspace",
             .init(projectionWorkspaceID: Self.workspaceID, panelID: Self.panelID, workspaceID: other,
                   workspaceUsesSSHTui: true, workspaceConnectionID: Self.machineID)),
            ("workspace gone",
             .init(projectionWorkspaceID: Self.workspaceID, panelID: Self.panelID, workspaceID: nil,
                   workspaceUsesSSHTui: true, workspaceConnectionID: Self.machineID)),
            ("workspace bound to another SSH connection",
             .init(projectionWorkspaceID: Self.workspaceID, panelID: Self.panelID, workspaceID: Self.workspaceID,
                   workspaceUsesSSHTui: true, workspaceConnectionID: "ssh:other")),
            ("workspace not a cmux-tui SSH workspace",
             .init(projectionWorkspaceID: Self.workspaceID, panelID: Self.panelID, workspaceID: Self.workspaceID,
                   workspaceUsesSSHTui: false, workspaceConnectionID: Self.machineID)),
        ]
        for (label, placement) in wrong {
            var ingress = SSHTuiHostOpenIngress(machineID: Self.machineID)
            _ = plan(&ingress, rows: [])
            let row = Self.row("notification_00000000000000000000000000000007")
            let actions = ingress.plan(requests: [row], now: Self.now, placements: { _ in [placement] },
                                       pathIsAcceptable: { _ in true })
            #expect(!actions.contains { $0.isOpen }, "\(label)")
            // After the grace period the host hears that no window here shows it.
            let later = ingress.plan(requests: [row], now: Self.now.addingTimeInterval(SSHTuiHostOpenIngress.placementGrace),
                                     placements: { _ in [placement] }, pathIsAcceptable: { _ in true })
            #expect(later == [.answer(rowID: row.id, .notOpenHere)], "\(label)")
        }
    }

    @Test("A valid placement after a wrong one is used; a missing pane waits, then is refused")
    func placementGrace() {
        var ingress = SSHTuiHostOpenIngress(machineID: Self.machineID)
        _ = plan(&ingress, rows: [])
        let row = Self.row("notification_00000000000000000000000000000008")
        let waiting = ingress.plan(requests: [row], now: Self.now, placements: { _ in [] }, pathIsAcceptable: { _ in true })
        #expect(waiting == [.recheck(after: SSHTuiHostOpenIngress.placementGrace)])
        let good = Self.placement()
        let bad = SSHTuiHostOpenPlacement(projectionWorkspaceID: UUID(), panelID: UUID(), workspaceID: UUID(),
                                          workspaceUsesSSHTui: true, workspaceConnectionID: Self.machineID)
        let opened = ingress.plan(requests: [row], now: Self.now.addingTimeInterval(1), placements: { _ in [bad, good] },
                                  pathIsAcceptable: { _ in true })
        #expect(opened == [.open(rowID: row.id, path: "/home/u/top.sv", workspaceID: Self.workspaceID, panelID: Self.panelID)])
    }

    @Test("A Mac with no pane for the terminal stays silent, so another Mac that has one can answer")
    func noProjectionStaysSilent() {
        var ingress = SSHTuiHostOpenIngress(machineID: Self.machineID)
        _ = plan(&ingress, rows: [])
        let row = Self.row("notification_00000000000000000000000000000010")
        let none: (String) -> [SSHTuiHostOpenPlacement] = { _ in [] }
        #expect(ingress.plan(requests: [row], now: Self.now, placements: none, pathIsAcceptable: { _ in true })
                == [.recheck(after: SSHTuiHostOpenIngress.placementGrace)])
        let later = Self.now.addingTimeInterval(SSHTuiHostOpenIngress.placementGrace)
        #expect(ingress.plan(requests: [row], now: later, placements: none, pathIsAcceptable: { _ in true }).isEmpty)
        #expect(ingress.plan(requests: [row], now: later.addingTimeInterval(1), placements: none,
                             pathIsAcceptable: { _ in true }).isEmpty)
    }

    @Test("Another Mac's not-open-here is not an answer: this Mac still opens the row")
    func otherMacsSoftRefusalDoesNotStopThisOne() {
        var ingress = SSHTuiHostOpenIngress(machineID: Self.machineID)
        _ = plan(&ingress, rows: [])
        let row = Self.row("notification_00000000000000000000000000000011",
                           readBy: ["mac-2", SSHTuiHostOpenAnswer.notOpenHere.clientID])
        #expect(plan(&ingress, rows: [row]).first?.isOpen == true)
    }

    @Test("After a reconnect, rows posted during the outage get the host-time replay check")
    func resetBaselineChecksOutageRows() {
        var ingress = SSHTuiHostOpenIngress(machineID: Self.machineID)
        _ = plan(&ingress, rows: [])
        ingress.resetBaseline()
        let old = Self.row("notification_00000000000000000000000000000012", hostAge: SSHTuiHostOpenIngress.replayWindow + 1)
        #expect(plan(&ingress, rows: [old]) == [.answer(rowID: old.id, .stale)])
        // A row first seen after the new baseline is live again.
        let skewed = Self.row("notification_00000000000000000000000000000013", hostAge: 3_600)
        #expect(plan(&ingress, rows: [old, skewed]).first?.isOpen == true)
    }

    @Test("A handled row that vanishes and comes back is never opened twice, across a reconnect too")
    func handledSurvivesVanishAndReset() {
        var ingress = SSHTuiHostOpenIngress(machineID: Self.machineID)
        _ = plan(&ingress, rows: [])
        let row = Self.row("notification_00000000000000000000000000000014")
        #expect(plan(&ingress, rows: [row]).first?.isOpen == true)
        #expect(plan(&ingress, rows: []).isEmpty)
        #expect(plan(&ingress, rows: [row]).isEmpty)
        ingress.resetBaseline()
        #expect(plan(&ingress, rows: []).isEmpty)
        #expect(plan(&ingress, rows: [row]).isEmpty)
    }

    @Test("A malformed body or a refused path is answered without opening")
    func refusedBodies() {
        var ingress = SSHTuiHostOpenIngress(machineID: Self.machineID)
        _ = plan(&ingress, rows: [])
        let malformed = Self.row("notification_00000000000000000000000000000009", body: SSHTuiHostOpenCommand.bodyPrefix + "junk")
        #expect(plan(&ingress, rows: [malformed]) == [.answer(rowID: malformed.id, .malformed)])
        let path = Self.row("notification_0000000000000000000000000000000a")
        let actions = ingress.plan(requests: [path], now: Self.now, placements: { _ in [Self.placement()] },
                                   pathIsAcceptable: { _ in false })
        #expect(actions == [.answer(rowID: path.id, .path)])
    }

    @Test("Only an SSH machine routes requests; anything else stays an ordinary notification")
    func onlySSHMachinesRoute() {
        let request = Self.row("notification_0000000000000000000000000000000b")
        let ordinary = CloudVMNotificationRow(id: "notification_0000000000000000000000000000000c", title: "Build done",
                                              body: "ok", level: "info", createdAtMs: 1, readBy: [])
        let ssh = SSHTuiHostOpenIngress.partition([request, ordinary], isSSH: true)
        #expect(ssh.requests == [request])
        #expect(ssh.others == [ordinary])
        let cloud = SSHTuiHostOpenIngress.partition([request, ordinary], isSSH: false)
        #expect(cloud.requests.isEmpty)
        #expect(cloud.others == [request, ordinary])
    }

    @Test("Outcomes map to the answers the host CLI reads")
    func answerClientIDs() {
        #expect(SSHTuiHostOpenAnswer.ok.clientID == "cmux-open:ok")
        #expect(SSHTuiHostOpenAnswer.notOpenHere.clientID == "cmux-open:refused:not-open-here")
        for answer in SSHTuiHostOpenAnswer.allCases {
            #expect(answer.clientID.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F })
            #expect(answer.clientID.hasPrefix(SSHTuiHostOpenAnswer.clientIDPrefix))
        }
        #expect(SSHTuiHostOpenAnswer.cancelledClientID.hasPrefix(SSHTuiHostOpenAnswer.clientIDPrefix))
    }

    // MARK: Helpers

    private func plan(_ ingress: inout SSHTuiHostOpenIngress, rows: [CloudVMNotificationRow]) -> [SSHTuiHostOpenIngress.Action] {
        ingress.plan(requests: rows, now: Self.now, placements: { terminal in
            terminal == Self.terminalID ? [Self.placement()] : []
        }, pathIsAcceptable: { $0.hasPrefix("/") })
    }

    static func placement() -> SSHTuiHostOpenPlacement {
        SSHTuiHostOpenPlacement(projectionWorkspaceID: workspaceID, panelID: panelID, workspaceID: workspaceID,
                                workspaceUsesSSHTui: true, workspaceConnectionID: machineID)
    }

    static func row(_ id: String, hostAge: TimeInterval = 0, readBy: [String] = [],
                    body: String = SSHTuiHostOpenCommand.requestBody(path: "/home/u/top.sv", terminalID: terminalID)) -> CloudVMNotificationRow {
        CloudVMNotificationRow(id: id, title: SSHTuiHostOpenCommand.notificationTitle, body: body, level: "info",
                               createdAtMs: UInt64((now.timeIntervalSince1970 - hostAge) * 1000), readBy: readBy)
    }
}

private extension SSHTuiHostOpenIngress.Action {
    var isOpen: Bool { if case .open = self { true } else { false } }
    var rowID: String? {
        switch self {
        case .open(let id, _, _, _), .answer(let id, _): id
        case .recheck: nil
        }
    }
}
