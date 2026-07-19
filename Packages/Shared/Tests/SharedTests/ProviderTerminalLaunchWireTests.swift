import Testing
@testable import Shared

@Suite("provider terminal launch wire")
struct ProviderTerminalLaunchWireTests {
    @Test("provider identity survives terminal.start round trip")
    func requestRoundTrip() throws {
        let provider = AgentIdentifier("com.xai.grok")!
        let request = TerminalStartRequest(
            projectID: ProjectID.random(),
            agentID: provider,
            cols: 120,
            rows: 36
        )

        let decoded = try TerminalStartRequest(jsonValue: request.toJSONValue())
        #expect(decoded == request)
        #expect(decoded.agentID == provider)
    }

    @Test("plain shell remains backward compatible")
    func shellRoundTrip() throws {
        let request = TerminalStartRequest(projectID: ProjectID.random())
        let decoded = try TerminalStartRequest(jsonValue: request.toJSONValue())
        #expect(decoded == request)
        #expect(decoded.agentID == nil)
    }

    @Test("started response records the launched provider")
    func responseRoundTrip() throws {
        let provider = AgentIdentifier("com.anthropic.claude-code")!
        let response = TerminalStartedResponse(
            sessionID: SessionID.random(),
            projectID: ProjectID.random(),
            agentID: provider
        )

        let decoded = try TerminalStartedResponse(jsonValue: response.toJSONValue())
        #expect(decoded == response)
        #expect(decoded.agentID == provider)
    }

    @Test("command failures preserve operation and routing context")
    func commandErrorRoundTrip() throws {
        let sessionID = SessionID.random()
        let projectID = ProjectID.random()
        let response = RemoteCommandError(
            operation: FrameType.terminalStart.rawValue,
            message: "Provider is not installed",
            sessionID: sessionID,
            projectID: projectID
        )

        let decoded = try RemoteCommandError(jsonValue: response.toJSONValue())
        #expect(decoded == response)
    }
}
