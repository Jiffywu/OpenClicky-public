import Foundation
@testable import OpenClickyKit

/// A scratch folder that disappears with the test.
final class AgentTempDir: @unchecked Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("openclicky-agent-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var paths: AgentPaths { AgentPaths(root: url.appendingPathComponent("support", isDirectory: true)) }

    /// Writes an executable script.
    func script(_ name: String, _ body: String) throws -> URL {
        let file = url.appendingPathComponent(name)
        try body.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    /// Every file under the folder whose bytes contain `needle`.
    func filesContaining(_ needle: String) -> [String] {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var hits: [String] = []
        for case let file as URL in walker {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: file) else { continue }
            if data.range(of: Data(needle.utf8)) != nil { hits.append(file.path) }
        }
        return hits
    }
}

/// Polls until `condition` holds or `seconds` pass.
func agentEventually(_ seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

/// Collects a session's events until a predicate matches.
func collect(_ events: AsyncStream<AgentEvent>, until done: @escaping @Sendable (AgentEvent) -> Bool, timeout: Double = 15) async -> [AgentEvent] {
    await withTaskGroup(of: [AgentEvent]?.self) { group in
        group.addTask {
            var seen: [AgentEvent] = []
            for await event in events {
                seen.append(event)
                if done(event) { break }
            }
            return seen
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? []
    }
}

extension AgentEvent {
    var isTurnFinished: Bool { if case .turnFinished = self { true } else { false } }
    var approval: AgentApprovalRequest? { if case .approvalRequested(let request) = self { request } else { nil } }
}

/// Fake executables that behave like the real harnesses, replaying recorded JSON. `FAKE_LOG` receives what they
/// were sent; `FAKE_SCENARIO` picks the behavior.
enum FakeHarnessScripts {
    /// Behaves like `codex app-server`: answers the JSON-RPC handshake and replays a recorded turn.
    /// Scenarios: `approve` (asks to run a command, waits for the decision), `approve2` (asks twice at once),
    /// `wait` (works until steered or interrupted), `wait-approve` (works until steered, then asks to run a command),
    /// `quick` (finishes at once).
    static let codex = #"""
    #!/bin/sh
    LOG="${FAKE_LOG:-/dev/null}"
    say() { printf '%s\n' "$1"; }
    log() { printf '%s\n' "$1" >> "$LOG"; }
    printf 'args:' >> "$LOG"; for a in "$@"; do printf ' [%s]' "$a" >> "$LOG"; done; echo >> "$LOG"
    for v in CODEX_HOME OPENCLICKY_AGENT_API_KEY OPENCLICKY_MCP_TOKEN_BROWSER ANTHROPIC_API_KEY CLAUDECODE; do
      eval "val=\${$v-}"; [ -n "$val" ] && echo "env: $v is set" >> "$LOG"
    done
    case "$NO_PROXY" in *127.0.0.1*) echo "env: NO_PROXY has loopback" >> "$LOG";; esac
    T='"threadId":"thread-1","turnId":"turn-1"'
    finish() {
      mkdir -p output && printf 'notes\n' > output/notes.md
      say '{"method":"item/completed","params":{"item":{"type":"commandExecution","id":"call_1","command":"/bin/zsh -lc '"'"'mkdir -p output'"'"'","commandActions":[{"type":"unknown","command":"mkdir -p output"}],"status":"'"$1"'","exitCode":0},'"$T"'}}'
      say '{"method":"item/completed","params":{"item":{"type":"fileChange","id":"fc_1","status":"completed","changes":[{"path":"output/notes.md","kind":{"type":"add"},"diff":""}]},'"$T"'}}'
      say '{"method":"thread/tokenUsage/updated","params":{'"$T"',"tokenUsage":{"total":{"inputTokens":120,"cachedInputTokens":20,"outputTokens":30}}}}'
      say '{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_1","text":"Wrote the notes.\n\n<report>\nsay: Your notes are ready.\ntitle: Meeting Notes\nfiles:\n- output/notes.md\n</report>"},'"$T"'}}'
      say '{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"completed","error":null}}}'
    }
    decisions=0
    while IFS= read -r line; do
      log "in: $line"
      id=$(printf '%s' "$line" | sed -n 's/^{"id":\([0-9][0-9]*\),.*/\1/p')
      case "$line" in
        *'"method":"initialize"'*) say '{"id":'"$id"',"result":{"userAgent":"fake-codex","platformFamily":"unix","platformOs":"macos"}}' ;;
        *'"method":"thread/start"'*|*'"method":"thread/resume"'*) say '{"id":'"$id"',"result":{"thread":{"id":"thread-1","cwd":"/tmp/job"}}}' ;;
        *'"method":"skills/extraRoots/set"'*) say '{"id":'"$id"',"result":{}}' ;;
        *'"method":"turn/start"'*)
          say '{"id":'"$id"',"result":{"turn":{"id":"turn-1","items":[],"status":"inProgress"}}}'
          say '{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"inProgress"}}}'
          say '{"method":"turn/plan/updated","params":{'"$T"',"plan":[{"step":"Make the folder","status":"inProgress"},{"step":"Write notes","status":"pending"}]}}'
          say '{"method":"item/started","params":{"item":{"type":"commandExecution","id":"call_1","command":"/bin/zsh -lc '"'"'mkdir -p output'"'"'","commandActions":[{"type":"unknown","command":"mkdir -p output"}],"status":"inProgress"},'"$T"'}}'
          case "$FAKE_SCENARIO" in
            approve) say '{"method":"item/commandExecution/requestApproval","id":0,"params":{'"$T"',"itemId":"call_1","reason":"Needs network","command":"/bin/zsh -lc '"'"'mkdir -p output'"'"'","commandActions":[{"type":"unknown","command":"mkdir -p output"}],"availableDecisions":["accept","cancel"]}}' ;;
            approve2)
              say '{"method":"item/commandExecution/requestApproval","id":0,"params":{'"$T"',"itemId":"call_1","command":"/bin/zsh -lc '"'"'mkdir -p output'"'"'","commandActions":[{"type":"unknown","command":"mkdir -p output"}]}}'
              say '{"method":"item/commandExecution/requestApproval","id":1,"params":{'"$T"',"itemId":"call_2","command":"/bin/zsh -lc '"'"'rm -rf tmp/cache'"'"'","commandActions":[{"type":"unknown","command":"rm -rf tmp/cache"}]}}' ;;
            wait|wait-approve) ;;
            *) finish completed ;;
          esac ;;
        *'"result":{"decision"'*)
          log "decision: $line"
          decisions=$((decisions+1))
          if [ "$FAKE_SCENARIO" = approve2 ] && [ "$decisions" -lt 2 ]; then continue; fi
          case "$line" in *'"decline"'*) finish declined ;; *) finish completed ;; esac ;;
        *'"method":"turn/steer"'*)
          say '{"id":'"$id"',"result":{"turnId":"turn-1"}}'
          if [ "$FAKE_SCENARIO" = wait-approve ]; then
            say '{"method":"item/commandExecution/requestApproval","id":0,"params":{'"$T"',"itemId":"call_1","command":"/bin/zsh -lc '"'"'mkdir -p output'"'"'","commandActions":[{"type":"unknown","command":"mkdir -p output"}]}}'
          else
            finish completed
          fi ;;
        *'"method":"turn/interrupt"'*)
          say '{"id":'"$id"',"result":{}}'
          say '{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"interrupted","error":null}}}' ;;
      esac
    done
    """#

    /// Behaves like `claude -p --input-format stream-json --output-format stream-json`.
    /// Scenarios: `approve` (asks to use Bash, waits for the control_response), `wait` (works until interrupted),
    /// `quick` (finishes at once). Later user messages each get their own short turn.
    static let claude = #"""
    #!/bin/sh
    LOG="${FAKE_LOG:-/dev/null}"
    say() { printf '%s\n' "$1"; }
    log() { printf '%s\n' "$1" >> "$LOG"; }
    printf 'args:' >> "$LOG"; for a in "$@"; do printf ' [%s]' "$a" >> "$LOG"; done; echo >> "$LOG"
    for v in ANTHROPIC_API_KEY ANTHROPIC_BASE_URL CLAUDE_CONFIG_DIR OPENCLICKY_MCP_TOKEN_BROWSER OPENCLICKY_MCPVAR_1 CLAUDECODE CODEX_HOME; do
      eval "val=\${$v-}"; [ -n "$val" ] && echo "env: $v is set" >> "$LOG"
    done
    S='"session_id":"sess-1"'
    finish() {
      mkdir -p output && printf 'notes\n' > output/notes.md
      say '{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_2","type":"tool_result","content":"ok","is_error":false}]},"parent_tool_use_id":null,'"$S"'}'
      say '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Wrote the notes.\n\n<report>\nsay: Your notes are ready.\ntitle: Meeting Notes\nfiles:\n- output/notes.md\n</report>"}]},"parent_tool_use_id":null,'"$S"'}'
      say '{"type":"result","subtype":"success","is_error":false,"result":"Wrote the notes.\n\n<report>\nsay: Your notes are ready.\ntitle: Meeting Notes\nfiles:\n- output/notes.md\n</report>","usage":{"input_tokens":100,"cache_read_input_tokens":40,"output_tokens":20},'"$S"'}'
    }
    n=0
    while IFS= read -r line; do
      log "in: $line"
      case "$line" in
        *'"type":"user"'*)
          n=$((n+1))
          if [ "$n" -gt 1 ]; then
            say '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Follow-up done.\n<report>\nsay: I added the summary too.\n</report>"}]},"parent_tool_use_id":null,'"$S"'}'
            say '{"type":"result","subtype":"success","is_error":false,"result":"Follow-up done.\n<report>\nsay: I added the summary too.\n</report>",'"$S"'}'
            continue
          fi
          say '{"type":"system","subtype":"init","cwd":"/tmp/job",'"$S"',"tools":["Bash","Write"],"model":"fake"}'
          say '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Writing the notes now."},{"type":"tool_use","id":"toolu_1","name":"TodoWrite","input":{"todos":[{"content":"Write notes","status":"in_progress","activeForm":"Writing"}]}},{"type":"tool_use","id":"toolu_2","name":"Write","input":{"file_path":"output/notes.md","content":"notes"}}]},"parent_tool_use_id":null,'"$S"'}'
          case "$FAKE_SCENARIO" in
            approve) say '{"type":"control_request","request_id":"perm-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"curl -s https://example.com","description":"Fetch the page"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"curl -s *"}],"behavior":"allow","destination":"localSettings"}],"tool_use_id":"toolu_3"}}' ;;
            wait) ;;
            *) finish ;;
          esac ;;
        *'"type":"control_response"'*)
          log "decision: $line"
          finish ;;
        *'"subtype":"interrupt"'*)
          say '{"type":"control_response","response":{"subtype":"success","request_id":"x"}}'
          say '{"type":"result","subtype":"error_during_execution","is_error":true,'"$S"'}' ;;
      esac
    done
    """#
}
