// Amani-Claim-ChatAgent - a conversational assistant for an Amani General
// Insurance employee (a claims handler or adjuster) to perform claim
// operations by chatting, rather than calling the backend APIs directly.
//
// Backed by the Claims Handling MCP toolset (claimtools / "Amani General
// Insurance - Claims Handling", port 9091 by default) - the task-shaped
// toolset that carries the business rules (coverage checks, authority
// limits, outstanding-document guardrails) in the tool contracts themselves,
// so this agent's own instructions only need to describe the job, not
// re-implement the rules.
//
// Deployed on WSO2 Agent Manager as a SINGLE agent, so all three services run
// in this one process:
//
//   /chat       :8000  (this module)   - the only port the platform exposes
//   claimtools  :9091  (localhost)     - the MCP toolset this agent calls
//   claimapi    :8080  (localhost)     - the claims backend claimtools calls
//
// The two submodules below are imported for their listeners alone; nothing in
// this module references their symbols.

import ballerina/ai;
import ballerina/http;

import amani_claim_agent.claimapi as _;
import amani_claim_agent.claimtools as _;

// Enables the WSO2 Agent Manager (AMP) tracing extension. Import only - the
// platform's auto-instrumentation does nothing for a Ballerina program without it.
import ballerinax/amp as _;

configurable string claimsToolsMcpServerUrl = "http://localhost:9091/mcp";

// Agent Manager's chat-api contract is POST /chat on port 8000. Configurable so
// the package still runs locally on another port.
configurable int servicePort = 8000;

final ai:Wso2ModelProvider claimChatAgentModel = check ai:getDefaultModelProvider();

// The agent cannot be built at module init. ai:McpToolKit's constructor performs
// the MCP `initialize` and `tools/list` round-trips immediately, and Ballerina
// runs every module's init before starting any listener - so at init time the
// co-located claimtools listener on 9091 is not accepting connections yet and
// construction would fail, taking the whole process down. Build it on the first
// request instead, once all listeners are up, and keep it for later turns.
isolated ai:Agent? agentHolder = ();

isolated function getClaimChatAgent() returns ai:Agent|error {
    lock {
        ai:Agent? existing = agentHolder;
        if existing !is () {
            return existing;
        }
    }

    ai:McpToolKit toolkit = check new (claimsToolsMcpServerUrl);
    ai:Agent created = check buildAgent(toolkit);

    lock {
        // Two first requests can race here; keep whichever landed first so every
        // caller shares one agent.
        ai:Agent? existing = agentHolder;
        if existing !is () {
            return existing;
        }
        agentHolder = created;
        return created;
    }
}

isolated function buildAgent(ai:McpToolKit toolkit) returns ai:Agent|error => new (
    systemPrompt = {
        role: string `Amani General Insurance Claims Operations Assistant`,
        instructions: string `You help an Amani General Insurance employee (a claims handler or adjuster) carry out claim operations by chatting with you, one turn at a time.
Call getClaimAssessment first for any claim you are asked about; it returns the claim, the policy, the coverage finding and payable amount, the claimant's prior-claim history, the employee's authority limit, and any blockers currently preventing a decision, all in one call.
Call getCustomerProfile before deciding or escalating a claim, to see the claimant's other claims, open and closed - this can reveal patterns a single claim will not show, such as several claims open at once.
Never decide a claim that still has outstanding documents. Use requestMissingDocuments to ask the claimant for what is missing, and when the employee tells you documents have arrived, use recordDocumentsReceived and re-assess with getClaimAssessment before deciding.
When asked to decide a claim, ground the decision in the coverage finding and the policy clause getClaimAssessment returned - never assume an outcome before checking, and always give a rationale that cites that basis when you call decideClaim.
Tools refuse with a status of REFUSED and a remedy instead of throwing an error - read the remedy and follow it (for example, escalate when a decision exceeds the employee's authority limit or cover is genuinely arguable) rather than retrying blindly or giving up.
Only call settleClaim when asked to process payment on an approved claim.
Always tell the employee plainly what you found, what you did, and why, citing the coverage basis or policy clause when relevant, so they can trust and verify your work.`
    },
    model = claimChatAgentModel,
    tools = [toolkit]
);

listener ai:Listener claimChatAgentListener = new (listenOn = servicePort);

// Mounted at the root so the resource below answers on POST /chat, which is the
// path Agent Manager's chat-api contract requires.
service / on claimChatAgentListener {

    resource function post chat(@http:Payload ai:ChatReqMessage request) returns ai:ChatRespMessage|error {
        ai:Agent claimChatAgent = check getClaimChatAgent();
        string stringResult = check claimChatAgent.run(request.message, request.sessionId);
        return {message: stringResult};
    }
}
