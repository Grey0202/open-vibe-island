import Foundation
import Testing
@testable import OpenIslandCore

/// Pins the notify-only contract for Claude permission requests: the bridge
/// must release the hook immediately with no decision (Claude Code defers its
/// native TUI dialog while a PermissionRequest hook is running, so holding the
/// hook froze the terminal until the card was answered in the island), while
/// still tracking the request so later hook events clear the island card.
struct BridgeServerAdvisoryPermissionTests {
    @Test
    func permissionRequestIsReleasedImmediately() throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        defer { server.stop() }

        let sessionID = "claude-session-advisory-1"
        let payload = ClaudeHookPayload(
            cwd: "/tmp/worktree",
            hookEventName: .permissionRequest,
            sessionID: sessionID,
            toolName: "Bash"
        )

        // Before the notify-only change this call blocked until the island
        // resolved the approval; now it must return acknowledged right away.
        let response = try BridgeCommandClient(socketURL: socketURL)
            .send(.processClaudeHook(payload), timeout: 5)

        #expect(response == .acknowledged)
        #expect(server.pendingClaudeStateSnapshotForTests().advisoryPermissionCount == 1)
    }

    @Test
    func laterHookEventClearsAdvisoryPermission() throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        defer { server.stop() }

        let sessionID = "claude-session-advisory-2"
        let client = BridgeCommandClient(socketURL: socketURL)

        let permissionPayload = ClaudeHookPayload(
            cwd: "/tmp/worktree",
            hookEventName: .permissionRequest,
            sessionID: sessionID,
            toolName: "Bash"
        )
        _ = try client.send(.processClaudeHook(permissionPayload), timeout: 5)
        #expect(server.pendingClaudeStateSnapshotForTests().advisoryPermissionCount == 1)

        // The user answered the dialog in the terminal: the approved tool ran
        // and reported postToolUse, which must clear the tracked request so
        // the island card resolves.
        let postToolPayload = ClaudeHookPayload(
            cwd: "/tmp/worktree",
            hookEventName: .postToolUse,
            sessionID: sessionID,
            toolName: "Bash"
        )
        _ = try client.send(.processClaudeHook(postToolPayload), timeout: 5)
        #expect(server.pendingClaudeStateSnapshotForTests().advisoryPermissionCount == 0)
    }

    @Test
    func parallelToolCompletionDoesNotClearAdvisoryPermission() throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let server = BridgeServer(socketURL: socketURL)
        try server.start()
        defer { server.stop() }

        let sessionID = "claude-session-advisory-3"
        let client = BridgeCommandClient(socketURL: socketURL)

        let permissionPayload = ClaudeHookPayload(
            cwd: "/tmp/worktree",
            hookEventName: .permissionRequest,
            sessionID: sessionID,
            toolName: "Bash",
            toolUseID: "tool-use-waiting"
        )
        _ = try client.send(.processClaudeHook(permissionPayload), timeout: 5)
        #expect(server.pendingClaudeStateSnapshotForTests().advisoryPermissionCount == 1)

        // A different tool running in parallel finishes — the card for the
        // still-waiting permission must survive.
        let unrelatedPostToolPayload = ClaudeHookPayload(
            cwd: "/tmp/worktree",
            hookEventName: .postToolUse,
            sessionID: sessionID,
            toolName: "Read",
            toolUseID: "tool-use-other"
        )
        _ = try client.send(.processClaudeHook(unrelatedPostToolPayload), timeout: 5)
        #expect(server.pendingClaudeStateSnapshotForTests().advisoryPermissionCount == 1)

        // The matching tool completing clears it.
        let matchingPostToolPayload = ClaudeHookPayload(
            cwd: "/tmp/worktree",
            hookEventName: .postToolUse,
            sessionID: sessionID,
            toolName: "Bash",
            toolUseID: "tool-use-waiting"
        )
        _ = try client.send(.processClaudeHook(matchingPostToolPayload), timeout: 5)
        #expect(server.pendingClaudeStateSnapshotForTests().advisoryPermissionCount == 0)
    }
}
