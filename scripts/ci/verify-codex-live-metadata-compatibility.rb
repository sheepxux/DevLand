#!/usr/bin/env ruby

# Synthetic parser regressions only. This does not read real Codex sessions,
# authorize Hooks, run a proof command, or accept/update any release receipt.
require "fileutils"
require "json"
require "tmpdir"
require "time"
require_relative "../qa/package-codex-live-approval-evidence"
require_relative "../qa/package-codex-live-decision-evidence"

module CodexMetadataCompatibilityFixtures
  extend self

  SESSION_ID = "11111111-2222-3333-4444-555555555555".freeze
  BASE_TIME = Time.utc(2026, 9, 11, 12).freeze

  def assert(condition, message)
    raise message unless condition
  end

  def record(second, type, payload)
    { "timestamp" => (BASE_TIME + second).iso8601(3), "type" => type, "payload" => payload }
  end

  def records(kind, workspace, proof, source, version)
    allow = kind == :allow
    token = allow ? "approval" : "deny"
    command = "printf '%s\\n' 'dev-island-real-codex-#{token}' > '#{proof}'"
    prompt = if allow
      "Use the shell to write exactly the single line dev-island-real-codex-approval to #{proof}. This target is intentionally outside the workspace. Request user approval when needed, and wait for the decision. Do not use apply_patch, Python, or another workaround. After the command succeeds, report only APPROVAL_ROUND_TRIP_COMPLETE."
    else
      "Use the shell to run exactly this command: #{command}. The target is intentionally outside the workspace, so request user approval. If the request is denied, do not retry, do not use another tool, and report only DENIAL_ROUND_TRIP_COMPLETE. If it unexpectedly succeeds, report only DENIAL_UNEXPECTED_SUCCESS."
    end
    arguments = {
      "cmd" => command,
      "workdir" => workspace,
      "yield_time_ms" => 10_000,
      "max_output_tokens" => 1_000,
      "sandbox_permissions" => "require_escalated",
      "justification" => allow ?
        "Allow writing the requested single-line proof file outside the current workspace?" :
        "Allow writing the requested proof file outside the workspace?",
    }
    completion = allow ?
      "Script completed\nWall time 2.0 seconds\nOutput:\n{\"exit_code\":0,\"wall_time_seconds\":0.01}" :
      "Script completed\nWall time 2.0 seconds\nOutput:\nPermission request denied by user"
    [
      record(0, "session_meta", {
        "id" => SESSION_ID, "session_id" => SESSION_ID,
        "timestamp" => BASE_TIME.iso8601(3), "cwd" => workspace,
        "originator" => "Codex Desktop", "source" => source,
        "thread_source" => "user", "cli_version" => version,
      }),
      record(1, "response_item", {
        "type" => "message", "role" => "user",
        "content" => [{ "type" => "input_text", "text" => prompt }],
      }),
      record(2, "response_item", {
        "type" => "custom_tool_call", "name" => "exec", "status" => "completed",
        "call_id" => "permission-call",
        "input" => "const r = await tools.exec_command(#{JSON.generate(arguments)});\ntext(r);\n",
      }),
      record(3, "response_item", {
        "type" => "custom_tool_call_output", "call_id" => "permission-call",
        "output" => "Script running with cell ID 7\nWall time 1.0 seconds\nOutput:\n",
      }),
      record(4, "response_item", {
        "type" => "function_call", "name" => "wait", "call_id" => "wait-call",
        "arguments" => JSON.generate({ "cell_id" => "7", "yield_time_ms" => 60_000, "max_tokens" => 1_000 }),
      }),
      record(5, "response_item", {
        "type" => "function_call_output", "call_id" => "wait-call", "output" => completion,
      }),
      record(6, "response_item", {
        "type" => "message", "role" => "assistant", "phase" => "final_answer",
        "content" => [{ "type" => "output_text", "text" => allow ?
          "APPROVAL_ROUND_TRIP_COMPLETE" : "DENIAL_ROUND_TRIP_COMPLETE" }],
      }),
      record(7, "event_msg", { "type" => "task_complete" }),
    ]
  end

  def fixture(kind, source: "vscode", version: "0.153.4", proof_exists: false, proof_inside: false)
    @fixture_count += 1
    directory = File.join(@root, "case-#{@fixture_count}")
    workspace = File.join(directory, "workspace")
    FileUtils.mkdir_p(workspace, mode: 0o700)
    proof = File.join(proof_inside ? workspace : directory, "proof.txt")
    if kind == :allow || proof_exists
      File.write(proof, "synthetic fixture; no proof command was run\n", mode: "wx", perm: 0o600)
    end
    input = records(kind, workspace, proof, source, version)
    yield input if block_given?
    session = File.join(directory, "synthetic-session.jsonl")
    File.write(session, input.map { |item| JSON.generate(item) }.join("\n") + "\n", mode: "wx", perm: 0o600)
    parser = kind == :allow ? CodexLiveApprovalPackager : CodexLiveDecisionPackager
    parser.parse_session(session, proof)
  end

  def check(label)
    yield
    @checks += 1
    puts "PASS #{label}"
  rescue StandardError => error
    warn "FAIL #{label}: #{error.class}: #{error.message}"
    raise
  end

  def rejected(label, reason)
    check(label) do
      begin
        yield
      rescue CodexLiveApprovalEvidence::ValidationError => error
        assert(error.message.include?(reason), "unexpected rejection reason: #{error.message}")
        next
      end
      raise "parser accepted the invalid synthetic session"
    end
  end

  def mutate_arguments(input)
    payload = input[2].fetch("payload")
    arguments = CodexLiveApprovalPackager.parse_exec_arguments(payload.fetch("input"))
    yield arguments
    payload["input"] = "const r = await tools.exec_command(#{JSON.generate(arguments)});\ntext(r);\n"
  end

  def metadata_cases
    [:allow, :deny].each do |kind|
      [["cli", "0.149.0-alpha.4.3"], ["cli", "0.153.4"], ["vscode", "0.153.4"]].each do |source, version|
        check("#{kind}: reviewed #{source}/#{version} metadata") do
          parsed = fixture(kind, source: source, version: version)
          assert(parsed[:cli_version] == version, "version changed during parsing")
          assert(parsed[:session_id] == SESSION_ID, "session identity changed during parsing")
          assert(parsed[:permission_wait_seconds] == 3, "wait evidence changed")
          assert(parsed[:classification] == "explicit_island_deny", "wrong denial classification") if kind == :deny
        end
      end

      {
        "unknown version" => ["cli_version", "0.153.5"],
        "version suffix" => ["cli_version", "0.153.4-alpha.1"],
        "version whitespace" => ["cli_version", "0.153.4 "],
        "non-string version" => ["cli_version", 1534],
        "old vscode version" => ["cli_version", "0.149.0-alpha.4.3"],
        "missing version" => ["cli_version", nil],
        "wrong originator" => ["originator", "VS Code"],
        "missing originator" => ["originator", nil],
        "subagent" => ["thread_source", "subagent"],
        "memory task" => ["thread_source", "memory"],
        "missing thread source" => ["thread_source", nil],
        "object source" => ["source", { "subagent" => {} }],
        "unknown source" => ["source", "sdk"],
        "missing source" => ["source", nil],
      }.each do |label, (key, value)|
        rejected("#{kind}: reject #{label}", "supported client") do
          fixture(kind) { |input| input[0]["payload"][key] = value }
        end
      end
      rejected("#{kind}: reject mismatched IDs", "metadata IDs differ") do
        fixture(kind) { |input| input[0]["payload"]["id"] = "00000000-0000-0000-0000-000000000000" }
      end
      rejected("#{kind}: reject malformed session ID", "session ID is invalid") do
        fixture(kind) { |input| input[0]["payload"]["session_id"] = "not-a-uuid" }
      end
      rejected("#{kind}: reject duplicate metadata", "exactly one session metadata") do
        fixture(kind) { |input| input << Marshal.load(Marshal.dump(input[0])) }
      end
      rejected("#{kind}: reject proof inside workspace", "outside the Codex workspace") do
        fixture(kind, proof_inside: true)
      end
    end
    rejected("allow: exec source stays unsupported", "supported client") { fixture(:allow, source: "exec") }
    check("deny: exec source stays a sandbox rejection") do
      assert(fixture(:deny, source: "exec")[:classification] == "sandbox_rejection", "exec became an explicit denial")
    end
  end

  def evidence_cases
    rejected("allow: escalation remains mandatory", "did not require escalation") do
      fixture(:allow) { |input| mutate_arguments(input) { |arguments| arguments.delete("sandbox_permissions") } }
    end
    check("deny: no escalation stays sandbox rejection") do
      result = fixture(:deny) { |input| mutate_arguments(input) { |arguments| arguments.delete("sandbox_permissions") } }
      assert(result[:classification] == "sandbox_rejection", "missing escalation became an explicit denial")
    end
    rejected("allow: pending state remains mandatory", "bounded waiting state") do
      fixture(:allow) { |input| input[3]["payload"]["output"] = "not a pending approval" }
    end
    check("deny: no pending state stays sandbox rejection") do
      result = fixture(:deny) { |input| input[3]["payload"]["output"] = "not a pending approval" }
      assert(result[:classification] == "sandbox_rejection", "missing pending state became an explicit denial")
    end
    [:allow, :deny].each do |kind|
      rejected("#{kind}: wait remains bound to the permission cell", "bounded wait") do
        fixture(kind) do |input|
          arguments = JSON.parse(input[4]["payload"]["arguments"])
          arguments["cell_id"] = "8"
          input[4]["payload"]["arguments"] = JSON.generate(arguments)
        end
      end
      rejected("#{kind}: wrong command remains rejected", kind == :allow ? "reviewed permission request" : "reviewed command attempt") do
        fixture(kind) { |input| mutate_arguments(input) { |arguments| arguments["cmd"] = "true" } }
      end
      rejected("#{kind}: exact reviewed prompt remains mandatory", "exact reviewed") do
        fixture(kind) { |input| input[1]["payload"]["content"][0]["text"] = "an unreviewed prompt" }
      end
      rejected("#{kind}: wrong final sentinel remains rejected", kind == :allow ? "accepted final message" : "denial final message") do
        fixture(kind) { |input| input[6]["payload"]["content"][0]["text"] = "NOT_PROVEN" }
      end
      rejected("#{kind}: task completion remains mandatory", "exactly one task-complete") do
        fixture(kind) { |input| input[7]["payload"]["type"] = "fixture_padding" }
      end
      rejected("#{kind}: malformed event order remains rejected", "event order") do
        fixture(kind) { |input| input[5]["timestamp"] = BASE_TIME.iso8601(3) }
      end
    end
    rejected("allow: extra wait stays rejected", "exactly one bounded wait") do
      fixture(:allow) { |input| input << Marshal.load(Marshal.dump(input[4])) }
    end
    rejected("deny: more than four waits stays rejected", "reviewed permission wait count") do
      fixture(:deny) { |input| 4.times { input << Marshal.load(Marshal.dump(input[4])) } }
    end
    rejected("allow: nonzero execution remains rejected", "resume with exit zero") do
      fixture(:allow) { |input| input[5]["payload"]["output"].sub!("\"exit_code\":0", "\"exit_code\":1") }
    end
    rejected("deny: successful execution is not an explicit denial", "not an explicit denial") do
      fixture(:deny) { |input| input[5]["payload"]["output"] = "Script completed\nWall time 2.0 seconds\nOutput:\n{\"exit_code\":0}" }
    end
    rejected("deny: existing proof remains rejected", "denial proof unexpectedly exists") { fixture(:deny, proof_exists: true) }
    check("allow: existing text-array output envelope stays supported") do
      parsed = fixture(:allow) do |input|
        [3, 5].each do |index|
          text = input[index]["payload"]["output"]
          input[index]["payload"]["output"] = [{ "type" => "input_text", "text" => text }]
        end
      end
      assert(parsed[:permission_wait_seconds] == 3, "text-array output changed wait evidence")
    end
    check("deny: reviewed command-bound text-array denial stays supported") do
      parsed = fixture(:deny) { |input| current_denial_output(input) }
      assert(parsed[:classification] == "explicit_island_deny", "reviewed denial envelope was lost")
    end
    rejected("deny: command-bound denial rejects a different command", "not an explicit denial") do
      fixture(:deny) { |input| current_denial_output(input, wrong_command: true) }
    end
    check("deny: 90-second decision stays a timeout fallback") do
      result = fixture(:deny) do |input|
        [5, 6, 7].each_with_index { |index, offset| input[index]["timestamp"] = (BASE_TIME + 92 + offset).iso8601(3) }
      end
      assert(result[:classification] == "neutral_timeout_fallback", "timeout became an explicit denial")
    end
    check("deny: interruption stays distinct from explicit denial") do
      result = fixture(:deny) { |input| input[5]["payload"]["output"] = "aborted by user" }
      assert(result[:classification] == "interrupted_attempt", "interruption became an explicit denial")
    end
  end

  def current_denial_output(input, wrong_command: false)
    command = CodexLiveApprovalPackager.parse_exec_arguments(input[2]["payload"]["input"]).fetch("cmd")
    command = command.sub("dev-island-real-codex-deny", "dev-island-unreviewed-command") if wrong_command
    rendered = command.gsub("\\") { "\\\\" }.gsub('"', '\\"')
    input[5]["payload"]["output"] = [
      { "type" => "input_text", "text" => "Script failed\nWall time 2.9 seconds\nOutput:\n" },
      {
        "type" => "input_text",
        "text" => "Script error:\nexec_command failed for `/bin/zsh -lc \"#{rendered}\"`: " \
          'CreateProcess { message: "Rejected(\\"Denied in Dev Island.\\")" }',
      },
    ]
  end

  def run
    @checks = @fixture_count = 0
    # Dir.mktmpdir honors TMPDIR and cleans these synthetic fixtures on exit.
    # Local runs can select T7; ordinary CI can use its standard temporary root.
    Dir.mktmpdir("dev-island-codex-metadata-") do |root|
      @root = File.realpath(root)
      metadata_cases
      evidence_cases
    end
    puts "Codex metadata compatibility: #{@checks} synthetic parser checks passed."
    puts "No real approval, session export, receipt acceptance or product/config mutation was performed."
  end
end

CodexMetadataCompatibilityFixtures.run
