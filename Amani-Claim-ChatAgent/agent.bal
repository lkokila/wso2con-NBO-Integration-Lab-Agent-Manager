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
// Built to be deployed on WSO2 Agent Manager: a single ai:Agent construction
// with an inline systemPrompt, a concrete ai:Wso2ModelProvider, the MCP
// toolkit in `tools`, and a standard chat trigger service.

import ballerina/ai;
import ballerina/http;

// Enables the WSO2 Agent Manager (AMP) tracing extension. Import only - the
// platform's auto-instrumentation does nothing for a Ballerina program without it.
import ballerinax/amp as _;

configurable string claimsToolsMcpServerUrl = "http://localhost:9091/mcp";

// Agent Manager's chat-api contract is POST /chat on port 8000. Configurable so
// the package still runs locally on another port.
configurable int servicePort = 8000;

final ai:Wso2ModelProvider claimChatAgentModel = check ai:getDefaultModelProvider();

final ai:McpToolKit claimChatAgentMcpToolkit = check new (claimsToolsMcpServerUrl);

final ai:Agent claimChatAgent = check new (
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
    tools = [claimChatAgentMcpToolkit]
);

listener ai:Listener claimChatAgentListener = new (listenOn = servicePort);

// Mounted at the root so the resource below answers on POST /chat, which is the
// path Agent Manager's chat-api contract requires.
service / on claimChatAgentListener {

    resource function post chat(@http:Payload ai:ChatReqMessage request) returns ai:ChatRespMessage|error {
        string stringResult = check claimChatAgent.run(request.message, request.sessionId);
        return {message: stringResult};
    }
}
