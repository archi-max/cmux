import Foundation

/// The Mac's answer to one `cmux open` row, sent back to the host as a
/// `notification.ack` under the reserved client id ``clientID``. The host CLI
/// reads the row's `read_by` and succeeds only on `cmux-open:ok`; any other
/// client's read (a phone, the Mac's own sync id) is not an answer.
///
/// An ack is the one per-row reply the daemon already carries and persists,
/// so an answer survives a relaunch and needs no extra row in the ledger.
public enum SSHTuiHostOpenAnswer: String, CaseIterable, Equatable, Sendable {
    /// The Mac queued the preview. It opens when the download lands; when it
    /// then cannot, a notice on the terminal says why. There is no later
    /// completion signal to wait for.
    case ok = "ok"
    /// A row already present when the feed started, whose host time is too old: a replay.
    case stale = "refused:stale"
    case malformed = "refused:malformed"
    /// The path is not a canonical absolute host path (`file.open_remote`'s check).
    case path = "refused:path"
    /// This Mac shows the terminal, but in no workspace of this SSH
    /// connection. Soft: another Mac may still open it, so neither the CLI
    /// nor another Mac stops on it.
    case notOpenHere = "refused:not-open-here"
    /// Not an SSH terminal there, or file previews are off.
    case previewsOff = "refused:previews-off"
    /// The type opens from the Files panel only.
    case unsupportedType = "refused:type"

    public static let clientIDPrefix = "cmux-open:"
    /// What the host CLI acks when it gives up; the Mac then never acts on the row.
    public static let cancelledClientID = clientIDPrefix + "cancelled"

    public var clientID: String { Self.clientIDPrefix + rawValue }

    /// Whether a `read_by` entry ends the request for every Mac: the CLI's
    /// cancel or any answer but ``notOpenHere``.
    public static func isFinal(readBy clientID: String) -> Bool {
        clientID.hasPrefix(clientIDPrefix) && clientID != notOpenHere.clientID
    }
}

/// One pane that shows the request's terminal, as the app resolved it.
public struct SSHTuiHostOpenPlacement: Equatable, Sendable {
    /// The workspace the catalog projection names.
    public var projectionWorkspaceID: UUID
    public var panelID: UUID
    /// The workspace the app found for that id, nil when there is none.
    public var workspaceID: UUID?
    public var workspaceUsesSSHTui: Bool
    /// `SSHTuiConnection.id` of that workspace's remote configuration.
    public var workspaceConnectionID: String?

    public init(projectionWorkspaceID: UUID, panelID: UUID, workspaceID: UUID?,
                workspaceUsesSSHTui: Bool, workspaceConnectionID: String?) {
        self.projectionWorkspaceID = projectionWorkspaceID
        self.panelID = panelID
        self.workspaceID = workspaceID
        self.workspaceUsesSSHTui = workspaceUsesSSHTui
        self.workspaceConnectionID = workspaceConnectionID
    }
}

/// Decides what the Mac does with `cmux open` rows of one SSH machine.
///
/// The provider takes request rows out of the notification sync
/// (``partition(_:isSSH:)``), so they are never shown, and runs every accepted
/// state through ``plan(requests:now:placements:pathIsAcceptable:)``. It
/// executes `.open` and then acks the outcome, acks every `.answer`, and
/// re-plans after `.recheck`.
///
/// Timing, aligned with the host CLI (which waits 10 s, then withdraws the
/// row with ``SSHTuiHostOpenAnswer/cancelledClientID``):
/// - A row carrying a final answer (``SSHTuiHostOpenAnswer/isFinal(readBy:)``),
///   including the CLI's cancel, is never acted on. That state lives in the
///   daemon, so it survives relaunch.
/// - Age is the Mac's: a row seen live waits at most ``placementGrace`` for a
///   pane, whatever the host clock says.
/// - Host time is used only for rows already in the first state after a
///   start or ``resetBaseline()`` (a relaunch, reconnect or state reinstall):
///   those older than ``replayWindow`` are answered stale instead of opened.
/// - A row this ingress handled is never handled again, even if it leaves
///   the state and comes back; ``resetBaseline()`` keeps that memory.
///
/// Several Macs can view one session. One with no pane showing the
/// terminal stays silent; ``SSHTuiHostOpenAnswer/notOpenHere`` is only for a
/// pane that exists here but in the wrong workspace.
public struct SSHTuiHostOpenIngress: Sendable {
    /// How long a live request waits for a pane to show its terminal.
    public static let placementGrace: TimeInterval = 5
    /// Host-time bound for rows that predate this ingress.
    public static let replayWindow: TimeInterval = 120

    public enum Action: Equatable, Sendable {
        /// Open `path` from `panelID`, then ack the outcome for `rowID`.
        case open(rowID: String, path: String, workspaceID: UUID, panelID: UUID)
        case answer(rowID: String, SSHTuiHostOpenAnswer)
        /// Plan again after this many seconds (a request is waiting for a pane).
        case recheck(after: TimeInterval)
    }

    /// The machine's `SSHTuiConnection.id`.
    public let machineID: String
    private var baseline: Set<String>?
    private var firstSeen: [String: Date] = [:]
    private var handled: Set<String> = []
    /// `handled` in insertion order, so it stays bounded past the daemon's 256-row ledger.
    private var handledOrder: [String] = []
    static let handledLimit = 1024

    public init(machineID: String) {
        self.machineID = machineID
    }

    /// The feed restarted (reconnect, state reinstall): rows in the next
    /// state may have been posted while this Mac was not looking, so they get
    /// the host-time replay check. Handled rows stay handled.
    public mutating func resetBaseline() {
        baseline = nil
    }

    /// Request rows of an SSH machine, and everything else. A Cloud machine
    /// has no host CLI posting them, so its rows all stay ordinary.
    public static func partition(_ rows: [CloudVMNotificationRow], isSSH: Bool)
        -> (requests: [CloudVMNotificationRow], others: [CloudVMNotificationRow]) {
        guard isSSH else { return ([], rows) }
        var requests: [CloudVMNotificationRow] = []
        var others: [CloudVMNotificationRow] = []
        for row in rows {
            if row.body.hasPrefix(SSHTuiHostOpenCommand.bodyPrefix) { requests.append(row) } else { others.append(row) }
        }
        return (requests, others)
    }

    /// - Parameters:
    ///   - placements: Every pane showing a terminal of this machine, by terminal id.
    ///   - pathIsAcceptable: `RemoteRelayCommandPolicy.isAcceptableRemoteFileOpenPath`.
    public mutating func plan(
        requests: [CloudVMNotificationRow], now: Date,
        placements: (String) -> [SSHTuiHostOpenPlacement], pathIsAcceptable: (String) -> Bool
    ) -> [Action] {
        let present = Set(requests.map(\.id))
        if baseline == nil { baseline = present }
        baseline?.formIntersection(present)
        firstSeen = firstSeen.filter { present.contains($0.key) }

        var actions: [Action] = []
        var recheck: TimeInterval?
        for row in requests where !handled.contains(row.id) {
            if row.readBy.contains(where: SSHTuiHostOpenAnswer.isFinal(readBy:)) {
                markHandled(row.id)
                continue
            }
            let seen = firstSeen[row.id] ?? now
            firstSeen[row.id] = seen
            switch SSHTuiHostOpenRequest(body: row.body, pathIsAcceptable: pathIsAcceptable) {
            case .notARequest:
                continue
            case .refused(let answer):
                markHandled(row.id)
                actions.append(.answer(rowID: row.id, answer))
            case .open(let path, let terminalID):
                let hostAge = now.timeIntervalSince1970 - Double(row.createdAtMs) / 1000
                if baseline?.contains(row.id) == true, abs(hostAge) > Self.replayWindow {
                    markHandled(row.id)
                    actions.append(.answer(rowID: row.id, .stale))
                    continue
                }
                let shown = placements(terminalID)
                if let placement = shown.first(where: isValid) {
                    markHandled(row.id)
                    actions.append(.open(rowID: row.id, path: path, workspaceID: placement.projectionWorkspaceID,
                                         panelID: placement.panelID))
                    continue
                }
                let waited = now.timeIntervalSince(seen)
                if waited >= Self.placementGrace {
                    markHandled(row.id)
                    // No pane here at all: another Mac may have one, so say nothing.
                    if !shown.isEmpty { actions.append(.answer(rowID: row.id, .notOpenHere)) }
                } else {
                    recheck = min(recheck ?? .infinity, Self.placementGrace - waited)
                }
            }
        }
        if let recheck { actions.append(.recheck(after: recheck)) }
        return actions
    }

    private mutating func markHandled(_ id: String) {
        guard handled.insert(id).inserted else { return }
        handledOrder.append(id)
        if handledOrder.count > Self.handledLimit {
            handled.remove(handledOrder.removeFirst())
        }
    }

    /// The pane's workspace is the projection's own workspace, a cmux-tui SSH
    /// workspace whose connection is this machine.
    private func isValid(_ placement: SSHTuiHostOpenPlacement) -> Bool {
        placement.workspaceID == placement.projectionWorkspaceID
            && placement.workspaceUsesSSHTui
            && placement.workspaceConnectionID == machineID
    }
}
