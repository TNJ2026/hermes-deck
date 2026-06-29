import Foundation
import Testing
@testable import hermes_deck

struct DeckMCPServerTests {
    @Test func deckReplyMCPHandshakeAndToolCall() async throws {
        let server = DeckMCPServer.shared
        try server.start { message in "received: \(message)" }
        let endpoint = try #require(server.endpointURL())
        let url = try #require(URL(string: endpoint))
        let token = server.token

        func rpc(_ payload: [String: Any], auth: Bool = true) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return (code, json)
        }

        // Missing/wrong bearer token is rejected.
        let (unauthorized, _) = try await rpc(["jsonrpc": "2.0", "id": 1, "method": "initialize"], auth: false)
        #expect(unauthorized == 401)

        // initialize
        let (initCode, initJSON) = try await rpc([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18"],
        ])
        #expect(initCode == 200)
        let serverInfo = (initJSON["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
        #expect(serverInfo?["name"] as? String == "hermes-deck")

        // tools/list advertises deck_reply
        let (_, listJSON) = try await rpc(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = (listJSON["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        #expect(tools?.contains { $0["name"] as? String == "deck_reply" } == true)

        // tools/call reaches the handler and returns its text
        let (_, callJSON) = try await rpc([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "deck_reply", "arguments": ["message": "hi there"]],
        ])
        let content = ((callJSON["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first
        #expect(content?["text"] as? String == "received: hi there")
    }
}
