import BlauCore
import BlauTelemetry
import Foundation
import Testing

@testable import BlauRealtime

/// Records the call context each call ran with.
struct ContextRecordingTool: RealtimeFunctionTool {
    static let name = "context"
    static let description = "Records its context."
    static let parameters = JSONSchema.noArguments

    let contexts = CallLog<RealtimeToolCallContext?>()

    func call(_ arguments: Data) async throws -> String {
        contexts.append(RealtimeToolCallContext.current)
        return "{}"
    }
}

@Suite("Tool call context and details")
struct RealtimeToolCallContextTests {
    @Test func toolsSeeWhichChainTheyRunIn() async throws {
        let sender = RecordingSender()
        let tool = ContextRecordingTool()
        let runner = RealtimeToolRunner(
            registry: try RealtimeToolRegistry([tool]), sender: sender, clock: ManualClock(),
            signposter: .disabled(.realtime))

        // The user's turn calls the tool; the follow-up calls it again.
        await runner.handle(ToolEvents.created("resp_1"))
        await runner.handle(ToolEvents.argumentsDone("call_1", name: "context", arguments: "{}"))
        await runner.handle(ToolEvents.done("resp_1"))
        try await sender.waitForSent(2)
        await runner.handle(ToolEvents.created("resp_2"))
        await runner.handle(ToolEvents.argumentsDone("call_2", name: "context", arguments: "{}", responseID: "resp_2"))
        await runner.handle(ToolEvents.done("resp_2"))
        try await sender.waitForSent(4)
        // The second follow-up answers without calls.
        await runner.handle(ToolEvents.created("resp_3"))
        await runner.handle(ToolEvents.done("resp_3"))
        // The user speaks again: a new chain.
        await runner.handle(ToolEvents.created("resp_4"))
        await runner.handle(ToolEvents.argumentsDone("call_3", name: "context", arguments: "{}", responseID: "resp_4"))
        await runner.handle(ToolEvents.done("resp_4"))
        try await sender.waitForSent(6)

        let contexts = tool.contexts.values.compactMap(\.self)
        #expect(contexts.map(\.callID) == ["call_1", "call_2", "call_3"])
        #expect(contexts.map(\.responseID) == ["resp_1", "resp_2", "resp_4"])
        #expect(contexts[0].chain == contexts[1].chain)
        #expect(contexts[2].chain == contexts[1].chain + 1)
        // Outside a call there is none.
        #expect(RealtimeToolCallContext.current == nil)
    }

    @Test func detailsAreReportedOnlyWhenAskedFor() async throws {
        for reports in [false, true] {
            let sender = RecordingSender()
            let runner = RealtimeToolRunner(
                registry: try RealtimeToolRegistry([EchoTool()]), sender: sender, clock: ManualClock(),
                configuration: .init(reportsCallDetails: reports), signposter: .disabled(.realtime))
            let activity = StreamCollector(runner.activity)
            await runner.handle(ToolEvents.created("resp_1"))
            await runner.handle(ToolEvents.argumentsDone("call_1", name: "echo", arguments: #"{"text":"hi"}"#))
            await runner.handle(ToolEvents.done("resp_1"))
            try await sender.waitForSent(2)
            try await activity.waitForCount(reports ? 4 : 3)
            let details = activity.values.filter {
                if case .details = $0 { true } else { false }
            }
            if reports {
                #expect(
                    details == [
                        .details(
                            callID: "call_1", name: "echo", arguments: #"{"text":"hi"}"#, output: #"{"text":"hi"}"#)
                    ])
                // Just before `finished`.
                #expect(activity.values[1] == details[0])
            } else {
                #expect(details.isEmpty)
            }
            activity.cancel()
        }
    }
}
