/// Execution Runner
/// Multi-round LLM loop extracted from main.mo for testability.
/// All outcomes are reported to the run store and emitted to Core.
///
/// The runner:
///   1. Claims the run from the store
///   2. Extracts API key and model from the envelope
///   3. Runs the LLM → tool → emit loop
///   4. Marks the run as completed or failed in the store
///   5. Emits the final result to Core via executionApi

import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Time "mo:core/Time";
import List "mo:core/List";
import Error "mo:core/Error";
import Json "mo:json";
import { str; arr; int; bool; obj } "mo:json";
import ExecutionTypes "../execution-types";
import CoreApi "../wrappers/core-api";
import LlmWrapper "../wrappers/llm-wrapper";
import ToolRegistry "../tools/tool-registry";
import ToolExecutor "../tools/tool-executor";
import ToolTypes "../tools/tool-types";
import RunTypes "./run-types";
import RunStoreModel "../models/run-store-model";

module {

  /// Run a single envelope to completion. Claims the run from the store,
  /// executes the multi-round LLM loop, and marks the outcome.
  /// Caller must wrap this in try/catch for trap safety.
  public func run(
    core : CoreApi.CoreApi,
    envelopeId : Text,
    runStore : RunStoreModel.RunStoreState,
  ) : async () {

    // Claim the run
    let record = switch (RunStoreModel.claim(runStore, envelopeId)) {
      case (null) { return }; // Already claimed or missing — no-op
      case (?r) { r };
    };

    let envelope = record.envelope;
    let tokenNonce = envelope.tokenNonce;
    let callCore = ToolExecutor.buildCallCore(core, tokenNonce);

    // Extract API key
    let apiKey = switch (
      Array.find<(Text, Text)>(
        envelope.secrets.apiKeys,
        func(kv : (Text, Text)) : Bool { kv.0 == "openrouter" },
      )
    ) {
      case (?(_, key)) { key };
      case (null) {
        // Already validated at ingress, but handle defensively
        let errMsg = "Missing 'openrouter' API key in envelope secrets";
        let stats = buildStats(Time.now(), 0, 0, 0, 0, "");
        RunStoreModel.markFailed(runStore, envelopeId, errMsg, []);
        ignore emitComplete(core, tokenNonce, errMsg, [], #failed(errMsg), stats);
        return;
      };
    };

    let model = resolveModel(envelope);
    let tools = ToolRegistry.getDefinitions(envelope.workflowId, envelope.scopeGrants);
    let toolsArg : ?[LlmWrapper.Tool] = if (tools.size() > 0) { ?tools } else {
      null;
    };

    // Initialize conversation from envelope messages
    let inputHistory = List.empty<LlmWrapper.InputItem>();
    for (item in LlmWrapper.chatMessagesToInput(envelope.messages).vals()) {
      List.add(inputHistory, item);
    };

    let runSteps = List.empty<RunTypes.RunStep>();
    let summarizedSteps = List.empty<ExecutionTypes.SummarizedStep>();
    var rounds : Nat = 0;
    var totalInputTokens : Nat = 0;
    var totalOutputTokens : Nat = 0;
    var totalToolCalls : Nat = 0;
    var resolvedModel : Text = model;
    let startNs = Time.now();

    label loop_ loop {
      // Check round limit
      if (rounds >= envelope.constraints.maxRounds) {
        let stats = buildStats(startNs, rounds, totalInputTokens, totalOutputTokens, totalToolCalls, resolvedModel);
        let msg = "Reached maximum rounds (" # Nat.toText(envelope.constraints.maxRounds) # ")";
        RunStoreModel.markCompleted(runStore, envelopeId, #roundLimitReached, stats, List.toArray(runSteps));
        ignore emitComplete(core, tokenNonce, msg, List.toArray(summarizedSteps), #roundLimitReached, stats);
        return;
      };

      // Call LLM
      let llmStartNs = Time.now();
      let response = try {
        await LlmWrapper.reason(
          apiKey,
          List.toArray(inputHistory),
          model,
          ?envelope.instructions,
          null,
          toolsArg,
        );
      } catch (e : Error) {
        let errMsg = "LLM call failed: " # Error.message(e);
        List.add(
          runSteps,
          {
            action = "llm_call";
            summary = errMsg;
            result = #err(errMsg);
            timestamp = Time.now();
            durationNs = Time.now() - llmStartNs;
          },
        );
        let stats = buildStats(startNs, rounds, totalInputTokens, totalOutputTokens, totalToolCalls, resolvedModel);
        RunStoreModel.markFailed(runStore, envelopeId, errMsg, List.toArray(runSteps));
        ignore emitComplete(core, tokenNonce, errMsg, List.toArray(summarizedSteps), #failed(errMsg), stats);
        return;
      };

      rounds += 1;
      resolvedModel := response.model;

      // Accumulate token usage
      switch (response.usage) {
        case (?u) {
          totalInputTokens += u.inputTokens;
          totalOutputTokens += u.outputTokens;
        };
        case (null) {};
      };

      // Record LLM call step
      let llmSummary = switch (response.result) {
        case (#ok(#textResponse({ content; thinking = _ }))) {
          truncate(content, 200);
        };
        case (#ok(#toolCalls(calls))) {
          "Requested " # Nat.toText(calls.size()) # " tool call(s)";
        };
        case (#err(msg)) { msg };
      };
      List.add(
        runSteps,
        {
          action = "llm_call";
          summary = llmSummary;
          result = switch (response.result) {
            case (#err(msg)) { #err(msg) };
            case (_) { #ok };
          };
          timestamp = Time.now();
          durationNs = Time.now() - llmStartNs;
        },
      );

      switch (response.result) {
        // ── Text response — execution complete ──
        case (#ok(#textResponse({ content; thinking = _ }))) {
          let stats = buildStats(startNs, rounds, totalInputTokens, totalOutputTokens, totalToolCalls, resolvedModel);
          RunStoreModel.markCompleted(runStore, envelopeId, #completed, stats, List.toArray(runSteps));
          ignore emitComplete(core, tokenNonce, content, List.toArray(summarizedSteps), #completed, stats);
          return;
        };

        // ── Tool calls — execute and continue loop ──
        case (#ok(#toolCalls(calls))) {
          let toolStartNs = Time.now();
          let results = try {
            await ToolExecutor.execute(
              callCore,
              envelope.workflowId,
              envelope.scopeGrants,
              calls,
            );
          } catch (e : Error) {
            let errMsg = "Tool execution failed: " # Error.message(e);
            List.add(
              runSteps,
              {
                action = "tool_batch";
                summary = errMsg;
                result = #err(errMsg);
                timestamp = Time.now();
                durationNs = Time.now() - toolStartNs;
              },
            );
            let stats = buildStats(startNs, rounds, totalInputTokens, totalOutputTokens, totalToolCalls, resolvedModel);
            RunStoreModel.markFailed(runStore, envelopeId, errMsg, List.toArray(runSteps));
            ignore emitComplete(core, tokenNonce, errMsg, List.toArray(summarizedSteps), #failed(errMsg), stats);
            return;
          };

          totalToolCalls += results.size();

          // Record individual tool steps + summarized steps
          for (r in results.vals()) {
            let (summary, success) = switch (r.result) {
              case (#success(data)) { (truncate(data, 200), true) };
              case (#error(err)) { (err, false) };
            };
            let toolName = toolNameFromCallId(calls, r.callId);
            List.add(
              runSteps,
              {
                action = "tool:" # toolName;
                summary;
                result = if (success) { #ok } else { #err(summary) };
                timestamp = Time.now();
                durationNs = r.durationMs * 1_000_000; // ms → ns
              },
            );
            List.add(summarizedSteps, { tool = toolName; summary; success });
          };

          // Build LLM input items for the tool round
          let formattedResults = ToolExecutor.formatResultsForLlm(results);
          let roundInput = LlmWrapper.toolRoundToInput(calls, formattedResults);
          for (item in roundInput.vals()) {
            List.add(inputHistory, item);
          };

          // Emit milestone if meaningful work was done (write operations or 2+ tools)
          if (results.size() >= 2 or hasWriteOperation(results)) {
            try {
              ignore emitMilestone(
                core,
                tokenNonce,
                summarizeToolRound(results),
                List.toArray(summarizedSteps),
              );
            } catch (_e : Error) {
              // Milestone failure is non-fatal — continue execution
            };
          };
        };

        // ── LLM error ──
        case (#err(errMsg)) {
          let stats = buildStats(startNs, rounds, totalInputTokens, totalOutputTokens, totalToolCalls, resolvedModel);
          RunStoreModel.markFailed(runStore, envelopeId, errMsg, List.toArray(runSteps));
          ignore emitComplete(core, tokenNonce, errMsg, List.toArray(summarizedSteps), #failed(errMsg), stats);
          return;
        };
      };
    };
  };

  // ── Event emission helpers ─────────────────────────────────────────

  func emitComplete(
    core : CoreApi.CoreApi,
    tokenNonce : Text,
    humanSummary : Text,
    stepsDetail : [ExecutionTypes.SummarizedStep],
    status : ExecutionTypes.ExecutionStatus,
    stats : ExecutionTypes.ExecutionStats,
  ) : async { #ok : Text; #err : Text } {
    let body = Json.stringify(
      obj([
        ("tokenNonce", str(tokenNonce)),
        ("humanSummary", str(humanSummary)),
        ("stepsDetail", stepsToJson(stepsDetail)),
        ("status", statusToJson(status)),
        ("stats", statsToJson(stats)),
      ]),
      null,
    );
    try {
      await core.executionApi(#post, "/execution/complete", body);
    } catch (e : Error) {
      #err("Failed to emit complete: " # Error.message(e));
    };
  };

  func emitMilestone(
    core : CoreApi.CoreApi,
    tokenNonce : Text,
    humanSummary : Text,
    stepsDetail : [ExecutionTypes.SummarizedStep],
  ) : async { #ok : Text; #err : Text } {
    let body = Json.stringify(
      obj([
        ("tokenNonce", str(tokenNonce)),
        ("humanSummary", str(humanSummary)),
        ("stepsDetail", stepsToJson(stepsDetail)),
      ]),
      null,
    );
    try {
      await core.executionApi(#post, "/execution/milestone", body);
    } catch (e : Error) {
      #err("Failed to emit milestone: " # Error.message(e));
    };
  };

  // ── Serialization helpers ──────────────────────────────────────────

  func stepsToJson(steps : [ExecutionTypes.SummarizedStep]) : Json.Json {
    arr(
      Array.map<ExecutionTypes.SummarizedStep, Json.Json>(
        steps,
        func(s : ExecutionTypes.SummarizedStep) : Json.Json {
          obj([
            ("tool", str(s.tool)),
            ("summary", str(s.summary)),
            ("success", bool(s.success)),
          ]);
        },
      )
    );
  };

  func statusToJson(status : ExecutionTypes.ExecutionStatus) : Json.Json {
    switch (status) {
      case (#completed) { str("completed") };
      case (#failed(msg)) {
        obj([("failed", str(msg))]);
      };
      case (#roundLimitReached) { str("roundLimitReached") };
    };
  };

  func statsToJson(stats : ExecutionTypes.ExecutionStats) : Json.Json {
    obj([
      ("durationNs", int(stats.durationNs)),
      ("llmCalls", int(stats.llmCalls)),
      ("toolCalls", int(stats.toolCalls)),
      ("inputTokens", int(stats.inputTokens)),
      ("outputTokens", int(stats.outputTokens)),
      ("model", str(stats.model)),
      ("rounds", int(stats.rounds)),
    ]);
  };

  // ── Utility helpers ────────────────────────────────────────────────

  func buildStats(
    startNs : Int,
    rounds : Nat,
    inputTokens : Nat,
    outputTokens : Nat,
    toolCalls : Nat,
    model : Text,
  ) : ExecutionTypes.ExecutionStats {
    {
      durationNs = Time.now() - startNs;
      llmCalls = rounds;
      toolCalls;
      inputTokens;
      outputTokens;
      model;
      rounds;
    };
  };

  func resolveModel(envelope : ExecutionTypes.ExecutionEnvelope) : Text {
    switch (
      Array.find<(Text, Text)>(
        envelope.secrets.apiKeys,
        func(kv : (Text, Text)) : Bool { kv.0 == "model" },
      )
    ) {
      case (?(_, m)) { m };
      case (null) { "openai/gpt-4.1-mini" };
    };
  };

  func toolNameFromCallId(calls : [LlmWrapper.ToolCall], callId : Text) : Text {
    switch (
      Array.find<LlmWrapper.ToolCall>(
        calls,
        func(c : LlmWrapper.ToolCall) : Bool { c.callId == callId },
      )
    ) {
      case (?c) { c.toolName };
      case (null) { "unknown" };
    };
  };

  func truncate(text : Text, maxLen : Nat) : Text {
    if (text.size() <= maxLen) { text } else {
      let chars = text.chars();
      var result = "";
      var count : Nat = 0;
      label trunc loop {
        switch (chars.next()) {
          case (null) { break trunc };
          case (?c) {
            if (count >= maxLen) { break trunc };
            result #= Text.fromChar(c);
            count += 1;
          };
        };
      };
      result # "…";
    };
  };

  func hasWriteOperation(results : [ToolTypes.ToolResult]) : Bool {
    Array.any<ToolTypes.ToolResult>(
      results,
      func(r : ToolTypes.ToolResult) : Bool {
        switch (r.result) {
          case (#success(_)) { true };
          case (#error(_)) { false };
        };
      },
    );
  };

  func summarizeToolRound(results : [ToolTypes.ToolResult]) : Text {
    let count = results.size();
    var successCount : Nat = 0;
    for (r in results.vals()) {
      switch (r.result) {
        case (#success(_)) { successCount += 1 };
        case (#error(_)) {};
      };
    };
    "Executed " # Nat.toText(count) # " tool(s), " # Nat.toText(successCount) # " succeeded.";
  };

};
