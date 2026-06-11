//
//  hermes_deckApp.swift
//  hermes_deck
//
//  Created by cxd on 2026/6/9.
//

import SwiftUI

@main
struct hermes_deckApp: App {
    private let agentClient: RoutingAgentClient

    init() {
        agentClient = RoutingAgentClient(
            hermes: HermesProfileGatewayClient(),
            agy: AgyClient(),
            claudeCLI: ClaudeCLIClient()
        )
    }

    var body: some Scene {
        // Single window: `Window` is a unique scene, and replacing `.newItem`
        // with nothing removes the "New Window" menu item / Cmd-N.
        Window("Hermes Deck", id: "chat") {
            ChatWindowRoot(agentClient: agentClient)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

private struct ChatWindowRoot: View {
    @State private var store: ChatStore
    private let agentClient: RoutingAgentClient

    init(agentClient: RoutingAgentClient) {
        self.agentClient = agentClient
        _store = State(initialValue: ChatStore(agentClient: agentClient))
    }

    var body: some View {
        ContentView(store: store)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                // Kill spawned agent subprocesses (ACP adapter subtrees and the
                // per-profile tui_gateways). Bounded wait: this notification is
                // the last chance to run — an un-awaited Task races app exit
                // and usually loses. The clients are plain actors, so blocking
                // the main thread here cannot deadlock them.
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    await agentClient.shutdown()
                    done.signal()
                }
                _ = done.wait(timeout: .now() + 2)
            }
    }
}

