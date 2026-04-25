/// Execution Runner
/// Multi-round LLM loop extracted from main.mo for testability.
/// Executes an envelope and returns a RunOutcome describing what happened.
///
/// Responsibilities of this module:
///   1. Extracts API key and model from the envelope
///   2. Runs the LLM → tool → milestone loop
///   3. Returns a RunOutcome for every exit path
///
/// NOT responsible for:
///   - Claiming / marking the run store  (done by the caller in main.mo)
///   - Emitting the final completion event to Core  (done by the caller in main.mo)
///   - Milestone emissions stay here — they are mid-loop, not final outcomes

import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Float "mo:core/Float";
import Text "mo:core/Text";
import Time "mo:core/Time";
import List "mo:core/List";
import Error "mo:core/Error";
import ExecutionTypes "../execution-types";
import CoreWrapper "../wrappers/core-wrapper";
import LlmWrapper "../wrappers/llm-wrapper";
import ToolRegistry "../tools/tool-registry";
import ToolExecutor "../tools/tool-executor";
import ToolTypes "../tools/tool-types";
import Constants "../constants";
import RunTypes "./run-types";
import CoreEmitter "./core-emitter";

module {

  /// Execute a single envelope to completion.
  /// Returns a RunOutcome for every exit path — the caller is responsible for
  /// marking the run store and emitting the final result to Core.
  /// Caller must wrap this in try/catch for trap safety.
  public func run(
    core : CoreWrapper.CoreActor,
    envelope : ExecutionTypes.EnvelopePayload,
  ) : async RunTypes.RunOutcome {

    let wrapper = CoreWrapper.CoreWrapper(core, envelope.envelopeNonce);

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
        let stats = buildStats(Time.now(), 0, 0, 0, 0, "", null);
        return {
          status = #failed(errMsg);
          humanSummary = errMsg;
          steps = [];
          summarizedSteps = [];
          stats;
        };
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
    var totalCost : ?Float = null;
    var resolvedModel : Text = model;
    let startNs = Time.now();

    loop {
      // Check round limit
      if (rounds >= envelope.constraints.maxRounds) {
        let stats = buildStats(startNs, rounds, totalInputTokens, totalOutputTokens, totalToolCalls, resolvedModel, totalCost);
        let msg = "Reached maximum rounds (" # Nat.toText(envelope.constraints.maxRounds) # ")";
        return {
          status = #roundLimitReached;
          humanSummary = msg;
          steps = List.toArray(runSteps);
          summarizedSteps = List.toArray(summarizedSteps);
          stats;
        };
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
        let stats = buildStats(startNs, rounds, totalInputTokens, totalOutputTokens, totalToolCalls, resolvedModel, totalCost);
        return {
          status = #failed(errMsg);
          humanSummary = errMsg;
          steps = List.toArray(runSteps);
          summarizedSteps = List.toArray(summarizedSteps);
          stats;
        };
      };

      rounds += 1;
      resolvedModel := response.model;

      // Accumulate token usage and cost
      switch (response.usage) {
        case (?u) {
          totalInputTokens += u.inputTokens;
          totalOutputTokens += u.outputTokens;
          switch (u.cost) {
            case (?c) {
              totalCost := ?(switch (totalCost) { case (?t) { t + c }; case null { c } });
            };
            case (null) {};
          };
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
          let stats = buildStats(startNs, rounds, totalInputTokens, totalOutputTokens, totalToolCalls, resolvedModel, totalCost);
          return {
            status = #completed;
            humanSummary = content;
            steps = List.toArray(runSteps);
            summarizedSteps = List.toArray(summarizedSteps);
            stats;
          };
        };

        // ── Tool calls — execute and continue loop ──
        case (#ok(#toolCalls(calls))) {
          let toolStartNs = Time.now();
          let results = try {
            await ToolExecutor.execute(
              wrapper,
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
            let stats = buildStats(startNs, rounds, totalInputTokens, totalOutputTokens, totalToolCalls, resolvedModel, totalCost);
            return {
              status = #failed(errMsg);
              humanSummary = errMsg;
              steps = List.toArray(runSteps);
              summarizedSteps = List.toArray(summarizedSteps);
              stats;
            };
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

          // Emit milestone if meaningful work was done (2+ tools, or any tool succeeded)
          if (results.size() >= 2 or hasAnySuccess(results)) {
            try {
              ignore await CoreEmitter.emitMilestone(
                wrapper,
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
          let stats = buildStats(startNs, rounds, totalInputTokens, totalOutputTokens, totalToolCalls, resolvedModel, totalCost);
          return {
            status = #failed(errMsg);
            humanSummary = errMsg;
            steps = List.toArray(runSteps);
            summarizedSteps = List.toArray(summarizedSteps);
            stats;
          };
        };
      };
    };
  };

  // ── Utility helpers ────────────────────────────────────────────────

  func buildStats(
    startNs : Int,
    rounds : Nat,
    inputTokens : Nat,
    outputTokens : Nat,
    toolCalls : Nat,
    model : Text,
    totalCost : ?Float,
  ) : ExecutionTypes.ExecutionStats {
    {
      durationNs = ?(Time.now() - startNs);
      llmCalls = ?rounds;
      toolCalls = ?toolCalls;
      inputTokens = ?inputTokens;
      outputTokens = ?outputTokens;
      model = ?model;
      rounds = ?rounds;
      estimatedDollarCost = totalCost;
    };
  };

  func resolveModel(envelope : ExecutionTypes.EnvelopePayload) : Text {
    switch (
      Array.find<(Text, Text)>(
        envelope.secrets.apiKeys,
        func(kv : (Text, Text)) : Bool { kv.0 == "model" },
      )
    ) {
      case (?(_, m)) { m };
      case (null) { Constants.DEFAULT_LLM_MODEL };
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

  func hasAnySuccess(results : [ToolTypes.ToolResult]) : Bool {
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
