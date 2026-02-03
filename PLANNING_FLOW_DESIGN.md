# Planning Flow Design

## Overview

This document describes the design for implementing a **Planning Flow** that helps users create smart, effective plans for their Value Streams. The planning flow will emphasize the 80/20 principle (80% benefit for 20% effort) and work as a collaborative discussion between the AI and the user before finalizing and saving the plan.

## Goals

1. **Collaborative Planning**: AI asks clarification questions and discusses preferences with the user
2. **Research-Backed**: Use web search to find best practices and proven approaches
3. **Smart & Concise**: Focus on high-impact, low-effort strategies (80/20 principle)
4. **Iterative Refinement**: Allow multiple rounds of discussion before saving
5. **User Confirmation**: User must explicitly confirm final version before saving
6. **Revisable**: Inform users that plans can be revised at any time
7. **Macro-Level**: Keep plans high-level; detailed sub-tasks will be delegated to "strategies" later

## Architecture Pattern (Following Value Streams Example)

### 1. Context Detection

**Location**: `groq-workspace-admin-service.mo` → `buildAdminInstructions()`

Add a new context ID to trigger planning flow when a Value Stream lacks a plan:

```motoko
// Check if any active value stream needs a plan
let hasActiveStreamWithoutPlan = Array.any<ValueStreamModel.ValueStream>(
  streams,
  func(vs) {
    vs.status == #active and vs.plan == null
  },
);

if (hasActiveStreamWithoutPlan) {
  List.add(contextIds, #needsPlanCreation);
};

```

### 2. Context Layer Instruction

**Location**: `instructions/instruction-types.mo`

Add new context ID:

```motoko
public type ContextId = {
  #hasTools;
  #errorRecovery;
  #needsValueStreamSetup;
  #needsPlanCreation; // NEW
};

```

**Location**: `instructions/layers/context-layer.mo`

Add instruction block for planning:

```motoko
case (#needsPlanCreation) {
  {
    id = "needs-plan-creation";
    content = "**Planning Opportunity**: You have active Value Streams that need execution plans.

**Your Planning Approach**:

1. **Ask Clarifying Questions**:
   - Understand constraints (time, budget, team size, technical capabilities)
   - Identify user preferences (risk tolerance, pace, existing tools/systems)
   - Clarify desired outcomes and success criteria

2. **Research Best Practices**:
   - You have web search capabilities - use them to research proven approaches for this type of problem
   - Look for 80/20 solutions: high impact with low effort
   - Find common pitfalls to avoid
   - Visit specific websites or documentation when needed for deeper understanding

3. **Propose Smart Plan**:
   - Focus on macro-level strategy (detailed sub-tasks will come later via 'strategies')
   - Emphasize quick wins and foundational steps
   - Identify critical dependencies and risks
   - Suggest resources needed (tools, skills, external services)

4. **Iterate with User**:
   - Present your research findings and proposed plan
   - Discuss trade-offs and alternatives
   - Refine based on user feedback
   - Be conversational and collaborative

5. **Confirm Before Saving**:
   - Once you and the user are satisfied, explicitly ask for final confirmation
   - Remind them that plans can be revised at any time later
   - Use `save_plan` tool ONLY after explicit user confirmation

**Plan Structure**:
- **Summary**: One-paragraph overview of the approach
- **Current State**: Where things are today (problems, constraints)
- **Target State**: Where we want to be (specific, measurable)
- **Steps**: High-level phases or milestones (not detailed tasks)
- **Risks**: Key risks and mitigation strategies
- **Resources**: What's needed (people, tools, budget, knowledge)

Work smarter, not harder. Focus on leverage and impact.";
  };
};

```

### 3. Use Groq's Built-In Web Search

**Implementation Strategy**: Instead of implementing a custom web search tool, we'll leverage **Groq's built-in web search capability** via the `compound` model.

**Location**: `services/groq-workspace-admin-service.mo`

The planning flow will use Groq's `compound` model with built-in tools enabled. When the planning context is active, calls to Groq will automatically have web search capabilities without needing explicit tool definitions.

**How it works**:

- Use the compound model (`groq/compound`) for planning conversations
- The LLM automatically decides when to search based on the conversation context
- Search results are integrated directly into the LLM's response
- The `CompoundChatCompletionResponse` includes:
  - `reasoning`: The LLM's internal thought process
  - `executed_tools`: Details about searches performed (queries, results, relevance scores)
  - `content`: The synthesized answer incorporating search findings

**Built-In Tool Types**:

```motoko
public type BuiltInTool = {
  #web_search : { searchSettings : ?SearchSettings }; // Web search with optional configuration
  #visit_website; // Visit and analyze website content from a URL
};

```

**Optional Search Configuration**:

```motoko
public type SearchSettings = {
  exclude_domains : ?[Text]; // Exclude domains (supports wildcards like *.com)
  include_domains : ?[Text]; // Restrict to specific domains
  country : ?Text; // Boost results from specific country
};

```

**Benefits**:

- ✅ No need to implement custom HTTP outcall logic
- ✅ No need to manage search API keys or quotas
- ✅ LLM can intelligently decide when/what to search
- ✅ Results are automatically integrated and synthesized
- ✅ Built-in relevance scoring and ranking
- ✅ Can also use `#visit_website` for deep diving into specific resources

### 4. Save Plan Tool

**Location**: `tools/function-tool-registry.mo`

Add a `save_plan` tool (similar to `save_value_stream`):

```motoko
/// Save plan tool - requires workspaceId + valueStreams with write
private func savePlanTool(workspaceId : Nat, valueStreamsMap : ValueStreamModel.ValueStreamsMap) : FunctionTool {
  {
    definition = {
      tool_type = "function";
      function = {
        name = "save_plan";
        description = ?"Saves or updates a plan for a value stream. Use this ONLY after user has explicitly confirmed they are satisfied with the final plan.";
        parameters = ?"{\"type\":\"object\",\"properties\":{\"valueStreamId\":{\"type\":\"number\",\"description\":\"The ID of the value stream to plan for\"},\"summary\":{\"type\":\"string\",\"description\":\"One-paragraph overview of the approach\"},\"currentState\":{\"type\":\"string\",\"description\":\"Where things are today (problems, constraints)\"},\"targetState\":{\"type\":\"string\",\"description\":\"Where we want to be (specific, measurable)\"},\"steps\":{\"type\":\"string\",\"description\":\"High-level phases or milestones (not detailed tasks)\"},\"risks\":{\"type\":\"string\",\"description\":\"Key risks and mitigation strategies\"},\"resources\":{\"type\":\"string\",\"description\":\"What's needed (people, tools, budget, knowledge)\"}},\"required\":[\"valueStreamId\",\"summary\",\"currentState\",\"targetState\",\"steps\",\"risks\",\"resources\"]}";
      };
    };
    handler = func(args : Text) : async Text {
      // Parse JSON arguments
      switch (Json.parse(args)) {
        case (#err(error)) {
          return buildErrorResponse("Failed to parse arguments: " # debug_show error);
        };
        case (#ok(json)) {
          // Extract all required fields
          let valueStreamIdOpt = switch (Json.get(json, "valueStreamId")) {
            case (?#number(#int n)) {
              if (n >= 0) { ?Int.abs(n) } else { null };
            };
            case _ { null };
          };

          let summaryOpt = switch (Json.get(json, "summary")) {
            case (?#string(s)) { ?s };
            case (_) { null };
          };

          let currentStateOpt = switch (Json.get(json, "currentState")) {
            case (?#string(s)) { ?s };
            case (_) { null };
          };

          let targetStateOpt = switch (Json.get(json, "targetState")) {
            case (?#string(s)) { ?s };
            case (_) { null };
          };

          let stepsOpt = switch (Json.get(json, "steps")) {
            case (?#string(s)) { ?s };
            case (_) { null };
          };

          let risksOpt = switch (Json.get(json, "risks")) {
            case (?#string(s)) { ?s };
            case (_) { null };
          };

          let resourcesOpt = switch (Json.get(json, "resources")) {
            case (?#string(s)) { ?s };
            case (_) { null };
          };

          // Validate all required fields
          switch (valueStreamIdOpt, summaryOpt, currentStateOpt, targetStateOpt, stepsOpt, risksOpt, resourcesOpt) {
            case (?valueStreamId, ?summary, ?currentState, ?targetState, ?steps, ?risks, ?resources) {
              let planInput : ValueStreamModel.PlanInput = {
                summary;
                currentState;
                targetState;
                steps;
                risks;
                resources;
              };

              // TODO: Get actual assistant name from context
              let changedBy = #assistant("workspace-admin-ai");
              let diff = "Plan created/updated";

              let result = ValueStreamModel.setPlan(
                valueStreamsMap,
                workspaceId,
                valueStreamId,
                planInput,
                changedBy,
                diff,
              );

              switch (result) {
                case (#ok(())) {
                  return "{\"success\":true,\"valueStreamId\":" # Nat.toText(valueStreamId) # ",\"action\":\"plan_saved\"}";
                };
                case (#err(msg)) {
                  return buildErrorResponse(msg);
                };
              };
            };
            case _ {
              return buildErrorResponse("Missing required fields. All fields are required: valueStreamId, summary, currentState, targetState, steps, risks, resources");
            };
          };
        };
      };
    };
  };
};

```

### 5. Tool Registry Updates

**Location**: `tools/function-tool-registry.mo` → `getAllDefinitions()`

Update the tool registry to include the new tools:

```motoko
public func getAllDefinitions(resources : ToolTypes.ToolResources) : [GroqWrapper.Tool] {
  var tools : List.List<GroqWrapper.Tool> = List.empty();

  // Always available tools
  List.add(tools, echoTool().definition);
  // Note: Web search is handled by Groq's built-in compound model, not as a custom tool

  // Value stream tools (when write access provided)
  switch (resources.valueStreams) {
    case (?{ map; write }) {
      if (write) {
        switch (resources.workspaceId) {
          case (?wid) {
            List.add(tools, saveValueStreamTool(wid, map).definition);
            List.add(tools, savePlanTool(wid, map).definition); // NEW
          };
          case (null) {};
        };
      };
    };
    case (null) {};
  };

  List.toArray(tools);
};

```

**Location**: `tools/tool-executor.mo` → `executeFunctionTool()`

Update the executor to handle new tools:

```motoko
public func executeFunctionTool(
  name : Text,
  args : Text,
  resources : ToolTypes.ToolResources,
) : async Text {
  switch (name) {
    case ("echo") {
      await echoTool().handler(args);
    };
    case ("save_value_stream") {
      // Existing implementation
    };
    case ("save_plan") {
      // NEW
      switch (resources.valueStreams, resources.workspaceId) {
        case (?{ map; write }, ?wid) {
          if (write) {
            await savePlanTool(wid, map).handler(args);
          } else {
            "{\"success\":false,\"error\":\"No write access to value streams\"}";
          };
        };
        case _ {
          "{\"success\":false,\"error\":\"Value streams resource not available\"}";
        };
      };
    };
    case (_) {
      "{\"success\":false,\"error\":\"Unknown function: " # name # "\"}";
    };
  };
};

```

## User Experience Flow

### Example Conversation

```
User: Let's create a plan for the "Improve API Response Times" value stream.

AI: Great! Let me help you build a smart, effective plan. First, I'd like to understand a few things:

1. **Constraints**:
   - How much time do you have to work on this? (e.g., 2 weeks, 1 month, ongoing)
   - What's your team size and technical expertise?
   - Any budget constraints for tools or services?

2. **Context**:
   - What's your current average response time?
   - What are the main bottlenecks you've identified?
   - Are you more concerned about certain endpoints or overall performance?

3. **Preferences**:
   - Would you prefer quick wins first, or tackling root causes?
   - How much risk are you comfortable with (e.g., caching strategies, infrastructure changes)?
   - Do you have monitoring tools in place already?

[User provides answers...]

AI: Thanks! Let me research some proven approaches for API performance optimization...

[AI internally uses Groq's built-in web search to research the topic]

Based on best practices and your constraints, here's what I found:
- Caching is the #1 quick win (80% of the benefit)
- Database query optimization is critical
- Consider using a CDN for static content
...

Here's my proposed plan:

**Summary**: Focus on high-impact, low-effort improvements: implement Redis caching for frequent queries, optimize the 3 slowest database queries, and add response time monitoring. This targets 70-80% improvement in 2-3 weeks.

**Current State**: Average response time is 800ms. No caching layer. Database queries not optimized. Limited monitoring.

**Target State**: Average response time under 200ms. Redis cache handling 60% of reads. Top queries optimized. Real-time performance dashboard.

**Steps**:
1. Week 1: Set up Redis and implement caching for top 5 API endpoints
2. Week 2: Profile and optimize the 3 slowest database queries
3. Week 3: Add comprehensive monitoring and fine-tune cache strategy

**Risks**:
- Cache invalidation complexity → Mitigate: Start with simple TTL-based caching
- Team learning curve with Redis → Mitigate: Allocate 2 days for team training
- Potential cache consistency issues → Mitigate: Use conservative TTLs initially

**Resources**:
- Redis instance (can use free tier initially)
- Database profiling tools (already have)
- 1 senior developer (primary) + 1 junior developer (support)
- Monitoring tool (can use open-source Grafana)

What do you think? Would you like to adjust anything?

[User discusses, AI refines...]

User: This looks great! Let's go with this plan.

AI: Perfect! Just to confirm - are you ready to save this as the official plan for your "Improve API Response Times" value stream?

Remember, you can always come back and revise the plan as you learn more or priorities change.

User: Yes, save it!

AI: [Uses save_plan tool]

Excellent! Your plan has been saved. The plan is now attached to your Value Stream.

Next steps:
- When you're ready to execute, we'll create specific "strategies" that break down these high-level steps into detailed tasks
- You can ask me to help monitor progress against your target metrics
- You can request plan revisions at any time

Would you like to start working on the first phase, or set up objectives and metrics for tracking?
```

## Implementation Phases

### Phase 1: Basic Structure (Foundation)

- [ ] Add `#needsPlanCreation` context ID
- [ ] Add context layer instruction for planning
- [ ] Update context detection logic in service
- [ ] Add plan display to workspace context (so AI can see existing plans)

### Phase 2: Save Plan Tool

- [ ] Implement `savePlanTool()` in function registry
- [ ] Update `getAllDefinitions()` to include save_plan
- [ ] Update `executeFunctionTool()` to handle save_plan
- [ ] Add plan validation logic

### Phase 3: Web Search Tool (Stub First)

- [ ] Implement `webSearchTool()` with stub handler
- [ ] Add to tool registry
- [ ] Update executor
- [ ] Document TODO for actual web search implementation

### Phase 4: Integration Tests

- [ ] Test plan creation flow with cassettes
- [ ] Test plan update flow
- [ ] Test context detection (no plan vs has plan)
- [ ] Test web search tool (stub version)

### Phase 5: Web Search Implementation (Future PR)

- [ ] Choose search API (DuckDuckGo, Brave Search, etc.)
- [ ] Implement HTTP wrapper for search
- [ ] Parse and format results
- [ ] Add rate limiting
- [ ] Update integration tests with real searches

## Testing Strategy

### Unit Tests

- `value-stream-model.test.mo`: Test `setPlan()` function
- Test plan validation
- Test plan history tracking

### Integration Tests

- `workspace-admin-talk.spec.ts`:
  - Test planning flow conversation
  - Test `save_plan` tool execution
  - Test `web_search` tool (stub)
  - Test plan revision flow
  - Test context switching (needs plan → has plan)

### Cassettes

- Planning conversation with multiple rounds
- Plan save success
- Plan update with history
- Web search calls (stub responses)

## Edge Cases & Considerations

1. **Multiple Value Streams**: If multiple active streams lack plans, prioritize based on user context or ask which to plan first

2. **Plan Revisions**: When updating an existing plan, show diff and ask for confirmation

3. **Plan Quality**: The instruction emphasizes 80/20, research, and collaboration - trust the LLM to follow this

4. **Incomplete Plans**: Validate that all required fields are provided before saving

5. **Web Search Usage**: Groq's compound model handles search automatically, but we should monitor token usage as searches increase context size

6. **Search Result Quality**: The LLM decides when/what to search - trust its judgment but provide good context in instructions

7. **Context Window**: Keep plans concise to avoid bloating conversation context (especially with search results) a plan via `PlanChangeAuthor`

8. **Context Window**: Keep plans concise to avoid bloating conversation context

## Future Enhancements

1. **Plan Templates**: Pre-built plan structures for common problems
2. **Plan Comparison**: Compare different plan approaches before committing
3. **Cost Estimation**: Estimate time/cost for each plan step
4. **Risk Scoring**: Automated risk assessment based on plan complexity
5. **Progress Tracking**: Link plan steps to objectives and metrics
6. **Collaborative Planning**: Multiple users can discuss and refine plans
7. **Plan Export**: Generate PDF/Markdown summaries of plans

## Open Questions

1. **Search Settings**: Should we configure domain filters or country preferences for planning searches, or use defaults?

2. **Plan Approval Flow**: Should we add a formal approval state for plans (draft → approved), or is implicit confirmation enough?

3. **Plan Versioning**: Should we implement full version control with rollback, or is the change history sufficient?

4. **Search Transparency**: Should we show users what searches the AI performed, or just present the synthesized plan?

5. **Context Persistence**: Should planning conversations be preserved separately from regular admin conversations?

## Success Criteria

The planning flow is successful if:

1. ✅ Users can create plans through natural conversation
2. ✅ AI asks thoughtful clarifying questions
3. ✅ AI leverages web search to research best practices and proven approaches
4. ✅ Plans emphasize high-impact, low-effort approaches (80/20 principle)
5. ✅ Users must explicitly confirm before saving
6. ✅ Plans are stored with history and attribution
7. ✅ Plans can be revised later
8. ✅ Context detection works (shows planning guidance when needed)
9. ✅ Groq compound model seamlessly integrates search results into responses

## References

- Value Stream Model: [src/open-org-backend/models/value-stream-model.mo](src/open-org-backend/models/value-stream-model.mo)
- Function Tool Registry: [src/open-org-backend/tools/function-tool-registry.mo](src/open-org-backend/tools/function-tool-registry.mo)
- Groq Wrapper (Built-In Tools): [src/open-org-backend/wrappers/groq-wrapper.mo](src/open-org-backend/wrappers/groq-wrapper.mo)
- Admin Service: [src/open-org-backend/services/groq-workspace-admin-service.mo](src/open-org-backend/services/groq-workspace-admin-service.mo)
- Context Layer: [src/open-org-backend/instructions/layers/context-layer.mo](src/open-org-backend/instructions/layers/context-layer.mo)
