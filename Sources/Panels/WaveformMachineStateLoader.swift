import AppKit
import UniformTypeIdentifiers

/// Loads the program image for a waveform viewer's machine state (WaveformMachineState): the ELF
/// next to a local dump when the commit stream is found, or one the user picks (Load ELF…).
@MainActor
enum WaveformMachineStateLoader {
    /// The viewers already given the ELF next to their dump (by dump path), so a rebuild doesn't read it again.
    private static let loaded = NSMapTable<FilePreviewPanel, NSString>.weakToStrongObjects()

    static func loadImageBeside(_ waveform: FilePreviewPanel) {
        guard let dump = waveform.nativeViewSessions.waveform.localDumpPath,
              loaded.object(forKey: waveform) as String? != dump,
              let elf = WaveformMachineState.elfBeside(dumpPath: dump) else { return }
        loaded.setObject(dump as NSString, forKey: waveform)
        load(elf, into: waveform, quiet: true)
    }

    static func chooseELF(for waveform: FilePreviewPanel) {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.message = String(
            localized: "waveformMachine.elf.choose",
            defaultValue: "Choose the program this run executed (an ELF file) for its memory image and symbols."
        )
        if let dump = waveform.nativeViewSessions.waveform.localDumpPath {
            openPanel.directoryURL = URL(fileURLWithPath: dump).deletingLastPathComponent()
        }
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = openPanel.url else { return }
            load(url.path, into: waveform, quiet: false)
        }
        if let window = waveform.nativeViewSessions.waveform.webViewWindow {
            openPanel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(openPanel.runModal())
        }
    }

    private static func load(_ path: String, into waveform: FilePreviewPanel, quiet: Bool) {
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<WaveformMachineState.Image, WaveformMachineState.LoadError> in
                do { return .success(try WaveformMachineState.loadImage(path: path)) } catch let error as WaveformMachineState.LoadError {
                    return .failure(error)
                } catch { return .failure(.unreadable(path)) }
            }.value
            let page = waveform.nativeViewSessions.waveform
            switch result {
            case .success(let image):
                _ = await page.callMachine("setImage", argument: image.pageArgument)
            case .failure(let error):
                // The ELF found next to the dump is a guess: only a chosen one's failure is shown.
                if !quiet { _ = await page.callMachine("say", argument: ["message": WaveformMachineState.message(for: error), "kind": "warning"]) }
            }
        }
    }
}
