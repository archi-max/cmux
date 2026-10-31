import Foundation
import Testing
@testable import CmuxRemoteWorkspace

/// `file.open_remote` lets `cmux open` in an SSH session preview a file on
/// that SSH host. Both relay gates must keep it to the session's own
/// terminal, a plain absolute host path, and nothing else.
@Suite("Remote relay file.open_remote policy")
struct RemoteRelayRemoteFileOpenPolicyTests {
    private let workspace = UUID()
    private let surface = UUID()

    private func evaluate(_ params: [String: Any], method: String = "file.open_remote") -> RemoteRelayCommandPolicy.Verdict {
        let line = try! JSONSerialization.data(withJSONObject: ["id": "o1", "method": method, "params": params])
        return RemoteRelayCommandPolicy().evaluate(
            commandLine: line,
            workspaceAliases: [workspace: workspace],
            surfaceAliases: [surface: surface]
        )
    }

    private func validate(_ params: [String: Any], method: String = "file.open_remote") -> RemoteRelayAuthorizationPolicy.Decision {
        RemoteRelayAuthorizationPolicy().validate(
            method: method,
            parameters: params,
            ownerWorkspaceID: workspace,
            surfaceIDs: [surface]
        )
    }

    private var owned: [String: Any] {
        ["workspace_id": workspace.uuidString, "surface_id": surface.uuidString, "path": "/home/u/rtl/alu core.sv"]
    }

    private func isDenied(_ verdict: RemoteRelayCommandPolicy.Verdict) -> Bool {
        if case .deny = verdict { return true }
        return false
    }

    private func isDenied(_ decision: RemoteRelayAuthorizationPolicy.Decision) -> Bool {
        if case .denied = decision { return true }
        return false
    }

    @Test
    func testOwnedTerminalAndAbsoluteHostPathAreAllowed() {
        #expect(evaluate(owned) == .allow)
        #expect(validate(owned) == .allowed)
        #expect(RemoteRelayCommandPolicy().permittedMethods(from: ["file.open", "file.open_remote"]) == ["file.open_remote"])
    }

    @Test
    func testLocalFileOpenStaysDenied() {
        // file.open opens a path on this Mac; it must never be reachable from a host.
        let local: [String: Any] = ["workspace_id": workspace.uuidString, "surface_id": surface.uuidString, "paths": ["/etc/hosts"]]
        #expect(isDenied(evaluate(local, method: "file.open")))
        #expect(isDenied(validate(local, method: "file.open")))
    }

    @Test
    func testTargetsOutsideTheSessionAreDenied() {
        var other = owned
        other["surface_id"] = UUID().uuidString
        #expect(isDenied(evaluate(other)))
        #expect(isDenied(validate(other)))
        var otherWorkspace = owned
        otherWorkspace["workspace_id"] = UUID().uuidString
        #expect(isDenied(evaluate(otherWorkspace)))
        #expect(isDenied(validate(otherWorkspace)))
        for missing in ["workspace_id", "surface_id"] {
            var params = owned
            params.removeValue(forKey: missing)
            #expect(isDenied(validate(params)), "missing \(missing)")
        }
    }

    @Test
    func testOnlyAPlainAbsolutePathIsAccepted() {
        let rejected: [Any] = [
            "rtl/alu.sv", "~/.ssh/id_ed25519", "file:///etc/passwd", "", "/a\u{0}b", "/a\nb",
            "/" + String(repeating: "a", count: 4_096), ["/a", "/b"], 7, NSNull(),
        ]
        for path in rejected {
            var params = owned
            params["path"] = path
            #expect(isDenied(evaluate(params)), "path \(path)")
            #expect(isDenied(validate(params)), "path \(path)")
        }
        var noPath = owned
        noPath.removeValue(forKey: "path")
        #expect(isDenied(evaluate(noPath)))
        #expect(isDenied(validate(noPath)))
    }

    @Test
    func testCommandsSelectorsAndOtherParamsAreDenied() {
        let extras: [String: Any] = [
            "command": "open -a Calculator", "initial_command": "id", "cwd": "/", "paths": ["/etc/hosts"],
            "pane_id": UUID().uuidString, "window_id": UUID().uuidString, "focus": true, "url": "https://example.com",
            "line": 3,
        ]
        for (key, value) in extras {
            var params = owned
            params[key] = value
            #expect(isDenied(evaluate(params)), "extra \(key)")
            #expect(isDenied(validate(params)), "extra \(key)")
        }
    }
}
