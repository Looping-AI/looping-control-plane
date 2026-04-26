import Json "mo:json";
import { obj } "mo:json";
import ToolTypes "../tools/tool-types";
import CoreWrapper "../wrappers/core-wrapper";

module {

  type Wrapper = CoreWrapper.CoreWrapper;

  // ── Handlers ─────────────────────────────────────────────────

  /// Get Slack queue stats. → GET /slack-queue/stats
  public func getSlackQueueStats(wrapper : Wrapper, _args : Text) : async ToolTypes.ToolCallOutcome {
    handleResult(await wrapper.callCore(#get, "/slack-queue/stats", "{}"));
  };

  /// List failed Slack queue events. → GET /slack-queue/failed
  public func getFailedSlackQueueEvents(wrapper : Wrapper, _args : Text) : async ToolTypes.ToolCallOutcome {
    handleResult(await wrapper.callCore(#get, "/slack-queue/failed", "{}"));
  };

  // ── Helpers ────────────────────────────────────────────────────────

  private func handleResult(result : { #ok : Text; #err : Text }) : ToolTypes.ToolCallOutcome {
    switch (result) {
      case (#ok(data)) { #success(data) };
      case (#err(e)) { #error(e) };
    };
  };
};
