import Json "mo:json";
import { str; obj; int; bool; arr } "mo:json";
import Array "mo:core/Array";
import WorkspaceModel "../../../models/workspace-model";

module {
  public func handle(
    state : WorkspaceModel.WorkspacesState,
    _args : Text,
  ) : async Text {
    let records = WorkspaceModel.listWorkspaces(state);
    let items = Array.map<WorkspaceModel.WorkspaceRecord, Json.Json>(
      records,
      func(r : WorkspaceModel.WorkspaceRecord) : Json.Json {
        let adminCh : Json.Json = switch (r.adminChannelId) {
          case (?id) { str(id) };
          case (null) { #null_ };
        };
        let memberCh : Json.Json = switch (r.memberChannelId) {
          case (?id) { str(id) };
          case (null) { #null_ };
        };
        obj([
          ("id", int(r.id)),
          ("name", str(r.name)),
          ("adminChannelId", adminCh),
          ("memberChannelId", memberCh),
        ]);
      },
    );
    Json.stringify(
      obj([
        ("success", bool(true)),
        ("workspaces", arr(items)),
      ]),
      null,
    );
  };
};
