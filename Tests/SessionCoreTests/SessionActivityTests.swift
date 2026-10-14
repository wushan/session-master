import XCTest
@testable import SessionCore

final class SessionActivityTests: XCTestCase {
    func codex(_ type: String, turn: String = "turn-1", at: String = "2026-10-14T04:00:00Z") -> [String: Any] {
        ["type": "event_msg", "timestamp": at, "payload": ["type": type, "turn_id": turn]]
    }

    func claude(_ type: String, stop: String? = nil, sidechain: Bool = false) -> [String: Any] {
        var message: [String: Any] = ["model": "claude-test"]
        if let stop { message["stop_reason"] = stop }
        return ["type": type, "timestamp": "2026-10-14T04:00:00Z", "message": message, "isSidechain": sidechain]
    }

    func testCodexOnlyLifecycleEndsWorkAndStaleCompletionCannotStopNewTurn() {
        var a = SessionActivity()
        a.consumeCodex(codex("task_started", turn: "older"))
        a.consumeCodex(codex("task_started", turn: "newer"))
        a.consumeCodex(codex("task_complete", turn: "older"))
        XCTAssertEqual(a.status, .busy, "An older turn completing must not hide current work")
        a.consumeCodex(codex("token_count"))
        XCTAssertEqual(a.status, .busy, "Elapsed time and unrelated writes are not completion")
        a.consumeCodex(codex("task_complete", turn: "newer"))
        XCTAssertEqual(a.status, .completed)
        a.consumeCodex(codex("item_completed"))
        XCTAssertEqual(a.status, .completed, "Post-completion writes must not restart a spinner")
    }

    func testAbortIsNotSuccessfulCompletion() {
        var a = SessionActivity()
        a.consumeCodex(codex("task_started")); a.consumeCodex(codex("turn_aborted"))
        XCTAssertEqual(a.status, .interrupted)
    }

    func testRuntimeApprovalHasPriorityAndDisconnectDoesNotClaimWork() {
        let busy = SessionActivity(status: .busy)
        XCTAssertEqual(CodexRuntimeObserver.reconcile(["type": "active", "activeFlags": ["waitingOnApproval"]], persisted: busy).status, .waiting)
        XCTAssertEqual(CodexRuntimeObserver.reconcile(["type": "active", "activeFlags": ["waitingOnUserInput"]], persisted: busy).status, .input)
        XCTAssertEqual(CodexRuntimeObserver.reconcile(["type": "active", "activeFlags": []], persisted: busy).status, .busy)
        XCTAssertEqual(CodexRuntimeObserver.reconcile(["type": "notLoaded"], persisted: busy).status, .interrupted)
        XCTAssertEqual(CodexRuntimeObserver.reconcile(nil, persisted: busy).status, .unknown)
        XCTAssertEqual(CodexRuntimeObserver.reconcile(nil, persisted: SessionActivity(status: .completed)).status, .completed)
    }

    func testRuntimePatchesFollowApprovalResolution() {
        var runtime: [String: Any]? = ["type": "active", "activeFlags": []]
        CodexRuntimeObserver.apply(["op": "add", "path": ["threadRuntimeStatus", "activeFlags", 0], "value": "waitingOnApproval"], to: &runtime)
        XCTAssertEqual(CodexRuntimeObserver.reconcile(runtime, persisted: SessionActivity()).status, .waiting)
        CodexRuntimeObserver.apply(["op": "remove", "path": ["threadRuntimeStatus", "activeFlags", 0]], to: &runtime)
        XCTAssertEqual(CodexRuntimeObserver.reconcile(runtime, persisted: SessionActivity()).status, .busy)
        CodexRuntimeObserver.apply(["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "idle"]], to: &runtime)
        XCTAssertEqual(CodexRuntimeObserver.reconcile(runtime, persisted: SessionActivity(status: .completed)).status, .completed)
    }

    func testClaudeToolUseIsWorkAndChildCompletionCannotStopParent() {
        var a = SessionActivity()
        a.consumeClaude(claude("user")); a.consumeClaude(claude("assistant", stop: "tool_use"))
        XCTAssertEqual(a.status, .busy)
        a.consumeClaude(claude("assistant", stop: "end_turn", sidechain: true))
        XCTAssertEqual(a.status, .busy)
        a.consumeClaude(claude("assistant", stop: "end_turn"))
        XCTAssertEqual(a.status, .completed)
        a.consumeClaude(["type": "custom-title"])
        XCTAssertEqual(a.status, .completed, "Desktop synchronization must not restart work")
    }

    func testClaudePermissionResponsesAndOldLaunchesDoNotLeaveStaleApprovals() throws {
        let line = "2026-10-14 12:00:01 [info] Emitted tool permission request ask-1 for Bash in session local_test"
        let ask = try XCTUnwrap(ClaudePermissionLog.parse(line))
        let response = try XCTUnwrap(ClaudePermissionLog.parse("2026-10-14 12:00:02 [info] Received permission response for ask-1: once (tool: Bash)"))
        let busy = SessionActivity(status: .busy)
        XCTAssertEqual(ClaudePermissionLog.pending(events: [ask], sessionId: "local_test", processStarted: ask.at.addingTimeInterval(-1), activity: busy).status, .waiting)
        XCTAssertEqual(ClaudePermissionLog.pending(events: [ask, response], sessionId: "local_test", processStarted: ask.at.addingTimeInterval(-1), activity: busy).status, .busy)
        XCTAssertEqual(ClaudePermissionLog.pending(events: [ask], sessionId: "local_test", processStarted: ask.at.addingTimeInterval(1), activity: busy).status, .busy)
        XCTAssertEqual(ClaudePermissionLog.pending(events: [ask], sessionId: "local_test", processStarted: ask.at.addingTimeInterval(-1), activity: SessionActivity(status: .completed)).status, .completed)
        XCTAssertEqual(ClaudePermissionLog.pending(events: [ask], sessionId: "local_other", processStarted: ask.at.addingTimeInterval(-1), activity: busy).status, .busy)
    }

    func testQuestionsAreNotAuthorizationRequests() throws {
        let ask = try XCTUnwrap(ClaudePermissionLog.parse("2026-10-14 12:00:01 [info] Emitted tool permission request ask-2 for AskUserQuestion in session local_test"))
        XCTAssertEqual(ClaudePermissionLog.pending(events: [ask], sessionId: "local_test", processStarted: ask.at.addingTimeInterval(-1), activity: SessionActivity(status: .busy)).status, .input)
    }

    func testClaudeInterruptAndNextTurnClearUnansweredOldPermission() throws {
        let ask = try XCTUnwrap(ClaudePermissionLog.parse("2026-10-14 12:00:01 [info] Emitted tool permission request ask-old for Bash in session local_test"))
        var a = SessionActivity(status: .busy)
        let clock = ISO8601DateFormatter()
        a.consumeClaude(["type": "user", "timestamp": clock.string(from: ask.at.addingTimeInterval(1)),
                         "message": ["content": "[Request interrupted by user for tool use]"]])
        XCTAssertEqual(a.status, .interrupted, "Cancellation must stop the spinner even while its process is alive")
        XCTAssertEqual(ClaudePermissionLog.pending(events: [ask], sessionId: "local_test", processStarted: ask.at.addingTimeInterval(-1), activity: a).status, .interrupted)
        a.consumeClaude(["type": "user", "timestamp": clock.string(from: ask.at.addingTimeInterval(60)), "message": ["content": "Next task"]])
        XCTAssertEqual(ClaudePermissionLog.pending(events: [ask], sessionId: "local_test", processStarted: ask.at.addingTimeInterval(-1), activity: a).status, .busy)
    }

    func testCompletionDoesNotFloodSavedClaudeOrAutomationNeedsYou() {
        func session(source: UnifiedSession.Source, pid: pid_t?, automation: Bool = false) -> UnifiedSession {
            UnifiedSession(id: "test", source: source, pid: pid, cwd: "/tmp", name: nil, title: nil,
                           model: nil, effort: nil, branch: nil, worktreeName: nil, originator: nil,
                           status: .completed, waitingFor: nil, terminal: .dead, updatedAt: nil,
                           isAutomationRun: automation)
        }
        XCTAssertEqual(session(source: .claudeDesktop, pid: nil).attention, .idle)
        XCTAssertEqual(session(source: .claudeDesktop, pid: 123).attention, .awaitingYou)
        XCTAssertEqual(session(source: .codexDesktop, pid: nil).attention, .awaitingYou)
        XCTAssertEqual(session(source: .codexDesktop, pid: nil, automation: true).attention, .idle)
    }

    func testReplayPreservesLongSilentTurnAndWaitsForCompleteLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rollout.jsonl")
        func line(_ record: [String: Any]) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: record); data.append(10); return data
        }
        var data = try line(codex("task_started", at: "2020-01-01T00:00:00Z"))
        data.append(try line(["type": "response_item", "payload": ["type": "message", "text": String(repeating: "x", count: 200_000)]]))
        try data.write(to: url)
        let replay = ActivityReplay()
        XCTAssertEqual(replay.read(url).status, .busy, "A start outside the tail still owns a silent turn")
        XCTAssertEqual(replay.read(url).status, .busy)
        let end = try line(codex("task_complete"))
        let fh = try FileHandle(forWritingTo: url); try fh.seekToEnd()
        try fh.write(contentsOf: end.dropLast())
        XCTAssertEqual(replay.read(url).status, .busy, "Never accept a partially written event")
        try fh.write(contentsOf: Data([10])); try fh.close()
        XCTAssertEqual(replay.read(url).status, .completed)
        try line(codex("turn_aborted")).write(to: url, options: .atomic)
        XCTAssertEqual(replay.read(url).status, .interrupted, "Replacement must discard cached running state")
    }

    func testUnknownFormatDoesNotPretendToBeWorking() throws {
        var a = SessionActivity(); a.consumeCodex(["type": "new_format"])
        XCTAssertEqual(a.status, .unknown)
    }
}
