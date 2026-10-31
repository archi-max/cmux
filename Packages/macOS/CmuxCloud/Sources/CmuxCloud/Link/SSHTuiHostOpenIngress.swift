import Foundation

/// The Mac's answer to one `cmux open` row (placeholder, implemented next).
public enum SSHTuiHostOpenAnswer: String, CaseIterable, Equatable, Sendable {
    case ok
    case stale
    case malformed
    case path
    case notOpenHere
    case previewsOff
    case unsupportedType

    public static let clientIDPrefix = "cmux-open:"
    public static let cancelledClientID = "cmux-open:cancelled"
    public var clientID: String { rawValue }
}

public struct SSHTuiHostOpenPlacement: Equatable, Sendable {
    public var projectionWorkspaceID: UUID
    public var panelID: UUID
    public var workspaceID: UUID?
    public var workspaceUsesSSHTui: Bool
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

public struct SSHTuiHostOpenIngress: Sendable {
    public static let placementGrace: TimeInterval = 5
    public static let replayWindow: TimeInterval = 120

    public enum Action: Equatable, Sendable {
        case open(rowID: String, path: String, workspaceID: UUID, panelID: UUID)
        case answer(rowID: String, SSHTuiHostOpenAnswer)
        case recheck(after: TimeInterval)
    }

    public let machineID: String

    public init(machineID: String) {
        self.machineID = machineID
    }

    public static func partition(_ rows: [CloudVMNotificationRow], isSSH: Bool)
        -> (requests: [CloudVMNotificationRow], others: [CloudVMNotificationRow]) {
        ([], rows)
    }

    public mutating func plan(
        requests: [CloudVMNotificationRow], now: Date,
        placements: (String) -> [SSHTuiHostOpenPlacement], pathIsAcceptable: (String) -> Bool
    ) -> [Action] {
        []
    }
}
