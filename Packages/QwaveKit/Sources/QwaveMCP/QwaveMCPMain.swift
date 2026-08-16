import Foundation
import MCP
import MCPSurface

// qwave-mcp — a read-only MCP server over Qwave's persisted browser state.
//
// stdio ONLY. `StdioTransport` is the sole transport constructed here; the SDK
// also ships HTTPClientTransport, NetworkTransport and two HTTP server
// transports, and none of them are referenced anywhere in this binary. Nothing
// in this process opens a socket, listens on a port, or resolves a host.
//
// stdout is the protocol channel. Every diagnostic goes to stderr, or it would
// corrupt the JSON-RPC stream.

@main
struct QwaveMCPMain {
    static func main() async {
        let service = QwaveMCPService(
            gate: MCPAccessGate(),
            reader: BrowserSnapshotReader(location: .resolved()))

        // Refuse to come up at all when the user has not opted in. The service
        // layer independently refuses every call (see QwaveMCPService.callTool)
        // — this is the outer of two gates, not the only one.
        guard await service.isEnabled else {
            FileHandle.standardError.write(Data((MCPAccessGate.disabledMessage + "\n").utf8))
            exit(2)
        }

        let server = Server(
            name: "qwave",
            version: "1.0.0",
            title: "Qwave Browser (read-only)",
            instructions: """
                Read-only access to the Qwave browser's persisted state: visit history, \
                bookmarks, and the last autosaved window/tab snapshot. This server cannot \
                navigate, click, type, or run scripts, and it cannot observe the browser's live \
                tab set — only what has been written to disk. It never surfaces Memory Wave \
                memories, which stay sealed.
                """,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: await service.listTools())
        }

        await server.withMethodHandler(CallTool.self) { parameters in
            await service.callTool(name: parameters.name, arguments: parameters.arguments)
        }

        do {
            try await server.start(transport: StdioTransport())
            await server.waitUntilCompleted()
        } catch {
            FileHandle.standardError.write(Data("qwave-mcp: \(error)\n".utf8))
            exit(1)
        }
    }
}
