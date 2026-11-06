import CmuxSyntaxHighlighting
import Foundation
import os

nonisolated private let waveformTraceVerdiLogger = Logger(subsystem: "com.cmuxterm.app", category: "WaveformTraceVerdi")

/// Driver tracing's Verdi engine (status/tracex-design.md §A.2): on an SSH host where Verdi runs
/// and the FSDB has a KDB next to it (`<simv>.daidir` from `vcs -kdb`), one warm
/// `verdi -nogui -play` session per viewer answers the active driver at a time (nTrace's
/// `srcActiveTrace`). The page still re-executes the statement itself (branch taken, fan-in values,
/// trust); Verdi's answer confirms it, follows port connections to the real driver, or is shown
/// next to it when the two differ. The session starts in the background on the first trace (it
/// takes about 16 s on a course CPU) and the open-source engine answers meanwhile; without a KDB,
/// Verdi or a licence seat the page keeps the open-source engine and says why.
///
/// Nothing of Verdi is shipped: cmux sends its own two scripts (Resources/vaporview/verdi-trace)
/// to a private scratch folder on the host and runs the host's Verdi from there.
@MainActor
enum WaveformTraceVerdi {
    enum State: Equatable {
        case starting
        case ready
        case unavailable(code: String, message: String)
    }

    @MainActor
    final class Session {
        let key: String
        let sidecar: SVModelSidecar
        /// Verdi runs while its viewer is open: a long-lived run, on a
        /// connection of its own or one of the carrier's long-lived sessions,
        /// taken before it starts and held until it stops.
        let ssh: FSDBHelperSession
        var state: State = .starting
        /// Failed requests (or starts) in a row; after one, Verdi is asked again once
        /// `VerdiTraceLaunch.retryDelay(failures:)` has passed.
        var failures = 0
        var retryAt: Date?

        init(key: String, sidecar: SVModelSidecar, ssh: FSDBHelperSession) {
            self.key = key
            self.sidecar = sidecar
            self.ssh = ssh
        }

        /// Stops Verdi and gives its SSH session back.
        func stop() {
            sidecar.stop()
            ssh.release()
        }
    }

    private static var sessions: [String: Session] = [:]
    /// The sessions' keys, least recently used first.
    private static var order = VerdiTraceLaunch.SessionKeys()
    /// Which session each viewer uses, to stop it when the viewer closes or loads again.
    private static let viewerSessions = NSMapTable<FilePreviewPanel, Session>.weakToStrongObjects()
    /// Verdi sessions kept at most: each holds a licence seat and the design.
    private static let maxSessions = 2
    /// One active trace: about 0.1–2 s on a course CPU, more on the first of a large design.
    private static let requestTimeout: TimeInterval = 120

    static func bundledScripts(bundle: Bundle = .main) -> (launcher: Data, serve: Data)? {
        guard let dir = bundle.resourceURL?.appendingPathComponent("vaporview/verdi-trace", isDirectory: true) else { return nil }
        return VerdiTraceLaunch.scripts(in: dir)
    }

    /// The viewer's session (started in the background), or nil when the viewer shows no FSDB on
    /// an SSH host or this build lacks the scripts.
    static func session(for waveform: FilePreviewPanel) -> Session? {
        guard let remote = FilePreviewWaveformSession.RemoteFSDB.resolve(panel: waveform),
              let scripts = bundledScripts() else { return nil }
        let key = remote.host + "|" + remote.remotePath
        if let known = sessions[key] {
            viewerSessions.setObject(known, forKey: waveform)
            order.use(key)
            if case .unavailable = known.state, let at = known.retryAt, Date() >= at { probe(known, host: remote.host) }
            return known
        }
        let ssh = FSDBHelperSession(configuration: remote.configuration)
        let sshArguments = ssh.arguments
        let sidecar = SVModelSidecar(
            runner: { command in .init(executable: "/usr/bin/ssh", arguments: sshArguments("sh -c '\(command)'")) },
            launchCommand: VerdiTraceLaunch.command(launcher: scripts.launcher, serve: scripts.serve, fsdbPath: remote.remotePath),
            installCommand: nil
        )
        let session = Session(key: key, sidecar: sidecar, ssh: ssh)
        sessions[key] = session
        order.use(key)
        for gone in order.evict(keeping: maxSessions) {
            sessions.removeValue(forKey: gone)?.stop()
        }
        viewerSessions.setObject(session, forKey: waveform)
        probe(session, host: remote.host)
        return session
    }

    /// Starts the session (or, after a failure, asks it again): ready when Verdi answers `info`
    /// with the FSDB's time unit. A start that failed for want of a seat or in time is retried
    /// with backoff; one the host refused (no KDB, no Verdi, other units) is not.
    private static func probe(_ session: Session, host: String) {
        session.state = .starting
        session.retryAt = nil
        Task { @MainActor in
            var retry = false
            do {
                // Its session first: on a host that takes only the terminal's
                // sign-in, a connection of its own couldn't log in.
                try await session.ssh.prepare()
                let info = try await session.sidecar.request(["cmd": "info"], timeout: requestTimeout)
                session.state = VerdiTraceLaunch.unitsMatch(info) ? .ready
                    : .unavailable(code: "units", message: "\(info["fileUnit"] ?? "") / \(info["windowUnit"] ?? "")")
            } catch SVModelSidecar.Failure.request(code: let code, message: let message) {
                session.state = .unavailable(code: code, message: message)
                retry = code == "licence" || code == "start"
            } catch let failure as SVModelSidecar.Failure {
                switch failure {
                case .timedOut(let detail), .exited(let detail):
                    let start = VerdiTraceLaunch.startFailure(detail: detail)
                    session.state = .unavailable(code: start.code, message: start.message.isEmpty
                        ? WaveformTrace.sidecarMessage(failure, host: host) : start.message)
                    retry = true
                case .stopped:
                    return
                default:
                    session.state = .unavailable(code: "start", message: WaveformTrace.sidecarMessage(failure, host: host))
                    retry = true
                }
            } catch {
                session.state = .unavailable(code: "start", message: WaveformTrace.sidecarMessage(error, host: host))
                retry = true
            }
            if case .unavailable(let code, _) = session.state {
                waveformTraceVerdiLogger.info("Verdi engine unavailable: \(code, privacy: .public)")
                if retry { failed(session) }
            }
        }
    }

    private static func failed(_ session: Session) {
        session.failures += 1
        session.retryAt = Date().addingTimeInterval(VerdiTraceLaunch.retryDelay(failures: session.failures))
    }

    /// The viewer closes or loads its file again: its Verdi session (the old FSDB) ends.
    static func stop(for waveform: FilePreviewPanel) {
        guard let session = viewerSessions.object(forKey: waveform) else { return }
        viewerSessions.removeObject(forKey: waveform)
        if sessions[session.key] === session {
            sessions.removeValue(forKey: session.key)
            order.remove(session.key)
        }
        session.stop()
    }

    /// `{type: 'trace', event: 'engine', id, cmd: 'active', signal (dump path), time}` from the page.
    /// Answers `{state: 'none' | 'starting' | 'unavailable' | 'ready', ...}`; when ready, Verdi's
    /// `{scope, file, line}` or `{notFound: true}`.
    static func answer(_ body: [String: Any], id: Int, waveform: FilePreviewPanel, reply: @escaping @MainActor (Any) -> Void) {
        guard body["cmd"] as? String == "active", let signal = body["signal"] as? String, !signal.isEmpty, signal.utf16.count <= 4096,
              let time = (body["time"] as? NSNumber)?.int64Value, time >= 0 else {
            reply(["state": "none"])
            return
        }
        guard let session = session(for: waveform) else {
            reply(["state": "none"])
            return
        }
        switch session.state {
        case .starting:
            reply(["state": "starting"])
        case .unavailable(let code, let message):
            reply(["state": "unavailable", "reason": code, "message": message])
        case .ready:
            Task { @MainActor in
                do {
                    let r = try await session.sidecar.request(["cmd": "active", "signal": signal, "time": time], timeout: requestTimeout)
                    session.failures = 0
                    reply(["state": "ready", "scope": r["scope"] ?? "", "file": r["file"] ?? "", "line": r["line"] ?? 0])
                } catch SVModelSidecar.Failure.request(code: "notFound", message: let message) {
                    reply(["state": "ready", "notFound": true, "message": message])
                } catch SVModelSidecar.Failure.stopped {
                    reply(["state": "none"])
                } catch {
                    // This request goes without Verdi; the session is asked again after a backoff
                    // (`session(for:)` probes it once `retryAt` has passed).
                    let message = WaveformTrace.sidecarMessage(error, host: nil)
                    if session.state == .ready {
                        session.state = .unavailable(code: "failed", message: message)
                        failed(session)
                    }
                    reply(["state": "unavailable", "reason": "failed", "message": message])
                }
            }
        }
    }
}
