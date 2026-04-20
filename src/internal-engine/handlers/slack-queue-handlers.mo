import Json "mo:json";
import { str; obj } "mo:json";
import ToolTypes "../tools/tool-types";

module {

  type CallCore = ToolTypes.CallCore;

  // ── Handlers ───────────────────────────────────────────────────────

  /// Get Slack queue stats. → GET /slack-queue/stats
  public func getSlackQueueStats(callCore : CallCore, _args : Text) : async Text {
    handleResult(await callCore(#get, "/slack-queue/stats", "{}"));
  };

  /// List failed Slack queue events. → GET /slack-queue/failed
  public func getFailedSlackQueueEvents(callCore : CallCore, _args : Text) : async Text {
    handleResult(await callCore(#get, "/slack-queue/failed", "{}"));
  };

  // ── Helpers ────────────────────────────────────────────────────────

  private func handleResult(result : { #ok : Text; #err : Text }) : Text {
    switch (result) {
      case (#ok(data)) { data };
      case (#err(e)) { errorJson(e) };
    };
  };

  private func errorJson(msg : Text) : Text {
    Json.stringify(obj([("error", str(msg))]), null);
  };
};
