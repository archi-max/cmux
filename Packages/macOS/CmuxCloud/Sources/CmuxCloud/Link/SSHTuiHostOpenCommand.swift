import Foundation

/// `cmux open` in a cmux SSH terminal (placeholder, implemented next).
public struct SSHTuiHostOpenCommand: Sendable {
    public static let bodyPrefix = "cmux-open-v1:"
    public static let notificationTitle = "cmux open"
    public static let maximumPathBytes = 756
    public static let maximumRequestAge: TimeInterval = 60

    public let session: String
    public let remoteBinary: String

    public init(session: String, remoteBinary: String) {
        self.session = session
        self.remoteBinary = remoteBinary
    }

    public var script: String { "" }
    public var installDirectory: String { "" }
    public var shellPrelude: String { "" }
}

/// What one daemon notification row means to the `cmux open` ingress.
public enum SSHTuiHostOpenRequest: Equatable, Sendable {
    case notARequest
    case refused(String)
    case open(path: String, terminalID: String)

    public init(
        title: String, body: String, terminalID: String?, createdAtMs: UInt64, now: Date,
        pathIsAcceptable: (String) -> Bool
    ) {
        self = .notARequest
    }

    public init(row: CloudVMNotificationRow, now: Date, pathIsAcceptable: (String) -> Bool) {
        self.init(title: row.title, body: row.body, terminalID: row.terminalID, createdAtMs: row.createdAtMs,
                  now: now, pathIsAcceptable: pathIsAcceptable)
    }
}

extension SSHTuiConnection {
    /// The host side of `cmux open` for this connection's daemon session.
    public var hostOpenCommand: SSHTuiHostOpenCommand {
        SSHTuiHostOpenCommand(session: session, remoteBinary: remoteBinary)
    }
}
