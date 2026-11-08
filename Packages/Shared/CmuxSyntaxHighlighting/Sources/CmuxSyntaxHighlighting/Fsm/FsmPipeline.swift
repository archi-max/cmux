import Foundation

/// The state machine view's engines in order: Verdi's FSM analysis (where the dump and Verdi
/// are), then Yosys's FSM extraction over the design, then the dump alone with the names
/// slang knows. The callers run the engines (over ssh or here); this decides and names.
public enum FsmPipeline {
    /// Why an engine gave nothing, for the pane's note.
    public enum Note: Sendable, Equatable {
        case verdi(reason: String, detail: String)
        case yosys(YosysFsm.Failure)
    }

    public struct Result: Sendable, Equatable {
        public var model: FsmModel
        public var notes: [Note]
    }

    /// - verdi: runs Verdi (nil: no Verdi here, as for a dump that isn't a remote FSDB).
    /// - yosys: runs Yosys with slang's context (nil: no Yosys); not asked without a context.
    public static func run(
        signal: String,
        context: SlangFsmContext?,
        verdi: (@Sendable () async -> VerdiFsmEngine.Outcome)?,
        yosys: (@Sendable (SlangFsmContext) async -> Swift.Result<[String: FsmModel], YosysFsm.Failure>)?
    ) async -> Result {
        var notes: [Note] = []
        if let verdi {
            switch await verdi() {
            case .report(let text, _):
                if let model = VerdiFsmReport.parse(text) {
                    return Result(model: named(model, context: context), notes: notes)
                }
                notes.append(.verdi(reason: "failed", detail: "the report could not be read"))
            case .unavailable(let reason, let detail):
                notes.append(.verdi(reason: reason, detail: detail))
            }
        }
        if let context, let yosys {
            switch await yosys(context) {
            case .success(let models):
                if let model = models[signal] ?? models.first(where: { $0.key.hasSuffix("." + signal) })?.value {
                    return Result(model: named(model, context: context), notes: notes)
                }
                notes.append(.yosys(.notFound))
            case .failure(let failure):
                notes.append(.yosys(failure))
            }
        }
        return Result(model: observed(signal: signal, context: context), notes: notes)
    }

    /// Names for the states the engine left unnamed: the enum's members, else the localparams'.
    static func named(_ model: FsmModel, context: SlangFsmContext?) -> FsmModel {
        guard let context else { return model }
        if let type = context.enumType, type.width == model.width { return FsmNaming.named(model, enumType: type) }
        guard model.states.contains(where: { $0.name == nil }) else { return model }
        return FsmNaming.named(model, names: FsmNaming.names(params: context.parameters, width: model.width))
    }

    static func observed(signal: String, context: SlangFsmContext?) -> FsmModel {
        guard let context else { return FsmModel.observed(signal: signal, width: 0, names: [:]) }
        if let type = context.enumType { return FsmModel.observed(signal: signal, enumType: type) }
        return FsmModel.observed(signal: signal, width: context.width, names: FsmNaming.names(params: context.parameters, width: context.width))
    }
}
