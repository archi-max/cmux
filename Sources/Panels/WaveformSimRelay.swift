import Foundation

/// Live simulation (the `liveSimulation` waveform setting, off by default): the sim.* requests the
/// page may send through `WaveformFSDBHelper`, and the one rule the relay adds for them.
///
/// The helper's sim.js reruns the simulator that wrote the panel's dump, from that run's
/// novas_dump.log. Which folder that is must not be up to the page: `sim.open` always gets the
/// panel file's own folder, and without a panel file there is no `sim.open`.
enum WaveformSimRelay {
    /// What the page sends for live simulation. No force/deposit/release or checkpoints yet.
    static let pageCommands: Set<String> = [
        "sim.open", "sim.run", "sim.until", "sim.stop", "sim.read", "sim.watch", "sim.unwatch", "sim.poll", "sim.close",
    ]

    /// The request as the helper should get it: `sim.open`'s folder replaced by the panel file's.
    /// Other sim.* requests pass unchanged.
    static func validated(_ object: [String: Any], allowedFile: String?) throws -> [String: Any] {
        let command = object["cmd"] as? String ?? ""
        guard pageCommands.contains(command) else { throw WaveformFSDBHelper.Failure.notAllowed(command) }
        guard command == "sim.open" else { return object }
        guard let allowedFile, allowedFile.hasPrefix("/") else { throw WaveformFSDBHelper.Failure.notAllowed(command) }
        var pinned: [String: Any] = ["cmd": command, "dir": (allowedFile as NSString).deletingLastPathComponent]
        if let id = object["id"] { pinned["id"] = id }
        if let clock = object["clock"] as? String { pinned["clock"] = clock }
        return pinned
    }
}
