# Amani Insurance — Integration Lab for WSO2 Agent Manager

The **Amani General Insurance** claims chat agent, packaged as **one** WSO2 Agent Manager agent.
The full demo — the durable workflow, the naive MCP server, the React claims portal — lives in
[`wso2con-NBO-Demo`](https://github.com/lkokila/wso2con-NBO-Demo); nothing here depends on it.

## One agent, three services

Agent Manager hosts a single agent here, and an agent publishes exactly one port. So all three
services run in one Ballerina package, in one process, and talk to each other over localhost:

```
              +- container -----------------------------------+
  POST /chat  |  :8000  agent (root module)                   |
  ----------> |     |                                         |
              |     +--MCP--> :9091  claimtools  (localhost)  |
              |                  |                            |
              |                  +--REST--> :8080  claimapi   |
              +-----------------------------------------------+
```

Only `8000` is exposed. `9091` and `8080` are reachable only from inside the container, which is
all the agent needs — nothing external calls them.

| Module | Role | Port |
|---|---|---|
| root (`agent.bal`) | The agent. `ai:Agent` with an inline system prompt, `ai:McpToolKit` over `claimtools`. | `8000`, `POST /chat` |
| `modules/claimtools` | MCP toolset (Streamable HTTP). Seven tools carrying the business rules — coverage checks, authority limits, document guardrails. | `9091` `/mcp`, localhost |
| `modules/claimapi` | Claims backend, `/claims` and `/customers`. In-memory store seeded at startup — no database. | `8080`, localhost |

The submodules are imported by `agent.bal` as `_` purely so their listeners start; no symbol
crosses between them. They still talk over HTTP and MCP exactly as they would if deployed apart,
so splitting them back into separate agents later is a deployment change, not a code change.

## Deploying

One agent, from the **Source Code** source type:

| Field | Value |
|---|---|
| Name | `amani-claim-chat-agent` (or anything) |
| GitHub Repository | `https://github.com/lkokila/wso2con-NBO-Integration-Lab-Agent-Manager` |
| Git Secret | `Public Repo (None)` |
| Branch | `main` |
| **Project Path** | **`/`** — the package is the repo root |
| Build Details | **Ballerina** (no start command or language version) |
| Agent Type | **Chat Agent** |
| Enable auto instrumentation | on |

`import ballerinax/amp as _;` is already in `agent.bal`. The auto-instrumentation checkbox does
nothing for a Ballerina program without it, so removing that import silently costs every trace.

## Configuration

**No `Config.toml` is committed** — it holds live model-provider credentials. Supply configuration
at deploy time instead.

| Module | Configurable | Default | Change it? |
|---|---|---|---|
| root | `servicePort` | `8000` | No — Agent Manager's chat-api contract |
| root | `claimsToolsMcpServerUrl` | `http://localhost:9091/mcp` | No — co-located |
| `claimtools` | `backendUrl` | `http://localhost:8080` | No — co-located |
| `claimtools` | `customersBackendUrl` | same as `backendUrl` | No — co-located |
| `claimtools` | `autoApprovalLimit` | `1000.00` | Payout ceiling before the agent must escalate |
| `claimtools` | `servicePort` | `9091` | No |
| `claimapi` | `servicePort` | `8080` | No |

Because everything is co-located, the only value you *must* supply is the model provider — attach
one in the LLM Providers section, or set it as configuration.

Ballerina reads configuration from a single `BAL_CONFIG_DATA` environment variable holding TOML.
Verified working, including the submodule table names:

```toml
[ballerina.ai.wso2ProviderConfig]
serviceUrl = "<generated>"
accessToken = "<generated>"

[anupama.amani_claim_agent.claimtools]
autoApprovalLimit = 2500.00
```

Root-module settings go under `[anupama.amani_claim_agent]`. Note that **`BAL_CONFIG_FILES` takes
precedence over `BAL_CONFIG_DATA`** — if both are set, the file wins and the env var is silently
ignored.

## Local run

One command runs everything:

```bash
bal run      # :8000 /chat, :9091 /mcp, :8080 /claims + /customers
```

`Config.toml` is gitignored; create it in the repo root with:

```toml
[ballerina.ai.wso2ProviderConfig]
serviceUrl = "<generated>"
accessToken = "<generated>"
```

Generate both with the Ballerina VS Code extension: open the package, sign in when prompted, then
run **"Ballerina: Configure Default Model Provider"** from the Command Palette.

Then:

```bash
curl -X POST http://localhost:8000/chat \
  -H "Content-Type: application/json" \
  -d '{"message": "What is the status of claim CLM-1042?", "sessionId": "demo-1"}'
```

Keep the same `sessionId` across turns. Ask it to decide `CLM-1042` while documents are still
outstanding — it should refuse and hand back a remedy rather than guess.

## Seed data

`claimapi` seeds itself on startup. There is no database.

| Claim | Customer | Type | Amount | Status | Missing documents |
|---|---|---|---|---|---|
| `CLM-1041` | `CUST-2001` Amara Okafor | Water damage | 450.00 | `READY` | — |
| `CLM-1042` | `CUST-2002` Thabo Nkosi | Water damage | 2500.00 | `MISSING_DOCUMENTS` | `proof_of_ownership.pdf`, `repair_estimate.pdf` |
| `CLM-1043` | `CUST-2003` Lindiwe Dlamini | Accidental damage | 800.00 | `READY` | — |

`POST /claims/{claimId}/reset` (localhost only) restores one claim to the state above.

## Known constraints

**The agent is built on the first request, not at startup.** `ai:McpToolKit`'s constructor performs
the MCP `initialize` and `tools/list` round-trips immediately, and Ballerina runs every module's
init before starting any listener. Building the agent at module level would therefore try to reach
a `claimtools` listener that is not accepting connections yet, and the process would die at boot.
`getClaimChatAgent()` in `agent.bal` builds it on first use and caches it. Consequence: **the first
chat request is slow** — it pays for the MCP handshake and tool listing. Send one warm-up request
after deploying rather than letting a live demo absorb it.

**The chat request payload does not match the console's stated contract.** The create form
describes chat-api as `POST /chat` on port `8000` with request `{message, session_id, context}` and
response `{response}`. Path and port match. The field names do not, and cannot be changed from
here: `ai:ChatService` mandates the resource signature
`post chat(@http:Payload ChatReqMessage) returns ChatRespMessage|error`, and both records are
closed — `ai:ChatReqMessage` is `{sessionId, message}`, `ai:ChatRespMessage` is `{message}`.
Verified locally: `sessionId` returns 201, `session_id` returns 400
`undefined field 'session_id'`. Matching the documented shape would mean dropping `ai:Listener` for
a plain `http:Listener` with hand-rolled records, keeping `ai:Agent`. Confirm what the platform
actually sends before doing that — the info box may describe the Python contract.

**Responses are HTTP 201, not 200.** Ballerina's default for a POST resource returning a value.
Harmless if the platform accepts any 2xx.

**State is per-replica and non-durable.** Claims live in memory in this process. A restart reseeds
all three mid-demo, and more than one replica would serve inconsistent claims *and* hold separate
agent caches. Keep this at a single replica.

**Divergence from the demo repo.** This repo restructures `wso2con-NBO-Demo` into one package:
`/claims` and `/customers` share a listener, `ai:TextDataLoader` is gone, `ballerinax/amp` is
imported, the agent is lazy, and it serves `/chat` on 8000.
