import Json "mo:json";
import { str; obj; bool; arr; float } "mo:json";
import List "mo:core/List";
import GroqWrapper "../../wrappers/groq-wrapper";
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
            let excludeDomains = switch (Json.get(json, "exclude_domains")) {
              case (?#array(a)) {
                let domains = List.empty<Text>();
                for (item in a.vals()) {
                  switch (item) {
                    case (#string(s)) { List.add(domains, s) };
                    case (_) {};
                  };
                };
                let domainsArray = List.toArray(domains);
                if (domainsArray.size() > 0) { ?domainsArray } else { null };
              };
              case (_) { null };
            };

            let includeDomains = switch (Json.get(json, "include_domains")) {
              case (?#array(a)) {
                let domains = List.empty<Text>();
                for (item in a.vals()) {
                  switch (item) {
                    case (#string(s)) { List.add(domains, s) };
                    case (_) {};
                  };
                };
                let domainsArray = List.toArray(domains);
                if (domainsArray.size() > 0) { ?domainsArray } else { null };
              };
              case (_) { null };
            };

            let country = switch (Json.get(json, "country")) {
              case (?#string(s)) { ?s };
              case (_) { null };
            };

            let searchSettings : ?GroqWrapper.SearchSettings = if (excludeDomains != null or includeDomains != null or country != null) {
              ?{
                exclude_domains = excludeDomains;
                include_domains = includeDomains;
                country;
              };
            } else {
              null;
            };

            let result = await GroqWrapper.useBuiltInTool(
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
