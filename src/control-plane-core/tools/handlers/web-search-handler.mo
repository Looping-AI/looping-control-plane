import Json "mo:json";
import { str; obj; bool; arr; float } "mo:json";
import List "mo:core/List";
import OpenRouterWrapper "../../wrappers/openrouter-wrapper";
import Helpers "./handler-helpers";

module {
  public func handle(
    apiKey : Text,
    args : Text,
  ) : async Text {
    switch (Json.parse(args)) {
      case (#err(error)) {
        Helpers.buildErrorResponse("Failed to parse arguments: " # debug_show error);
      };
      case (#ok(json)) {
        let searchQueryOpt = switch (Json.get(json, "query")) {
          case (?#string(s)) { ?s };
          case (_) { null };
        };

        switch (searchQueryOpt) {
          case (?searchQuery) {
            let searchSettings : ?OpenRouterWrapper.SearchSettings = null;

            let result = await OpenRouterWrapper.useBuiltInTool(
              apiKey,
              searchQuery,
              #web_search({ searchSettings }),
            );

            switch (result) {
              case (#ok(response)) {
                switch (response.choices[0]) {
                  case (choice) {
                    let message = choice.message;

                    let searchResultsJson = switch (message.executed_tools) {
                      case (?tools) {
                        let resultsArr = List.empty<Json.Json>();
                        for (tool in tools.vals()) {
                          switch (tool.search_results) {
                            case (?results) {
                              for (r in results.vals()) {
                                List.add(
                                  resultsArr,
                                  obj([
                                    ("title", str(r.title)),
                                    ("url", str(r.url)),
                                    ("content", str(r.content)),
                                    ("relevance_score", float(r.relevance_score)),
                                  ]),
                                );
                              };
                            };
                            case (null) {};
                          };
                        };
                        arr(List.toArray(resultsArr));
                      };
                      case (null) { arr([]) };
                    };

                    return Json.stringify(
                      obj([
                        ("success", bool(true)),
                        ("response", str(message.content)),
                        ("reasoning", str(switch (message.reasoning) { case (?r) { r }; case (null) { "" } })),
                        ("search_results", searchResultsJson),
                      ]),
                      null,
                    );
                  };
                };
              };
              case (#err(error)) {
                return Helpers.buildErrorResponse("Web search failed: " # error);
              };
            };
          };
          case (null) {
            return Helpers.buildErrorResponse("Missing required field: query");
          };
        };
      };
    };
  };
};
