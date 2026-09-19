# Amani Insurance — Integration Lab for WSO2 Agent Manager

Deployment repo for the **Amani General Insurance** claims chat agent, cut down to just the three
packages needed to run it on **WSO2 Agent Manager**. The full demo — the durable workflow, the
naive MCP server, the React claims portal — lives in
[`wso2con-NBO-Demo`](https://github.com/lkokila/wso2con-NBO-Demo); nothing here depends on it.

## What's here, and why only this

```
Amani-Claim-ChatAgent  ──MCP──▶  claimtools  ──REST──▶  claimapi
   (chat-api)                    (MCP toolset)          (/claims + /customers)
```

Three packages, in dependency order:

| Package | Role | Listens on |
|---|---|---|
| `claimapi` | Claims backend. In-memory store, seeded at startup — no database required. | `8080`, serving both `/claims` and `/customers` |
| `claimtools` | MCP toolset (Streamable HTTP). Seven tools carrying the business rules — coverage checks, authority limits, document guardrails. Calls `claimapi` only. | `9091` `/mcp` |
| `Amani-Claim-ChatAgent` | The agent itself. An `ai:Agent` with an inline system prompt and an `ai:McpToolKit`; `claimtools` is its only source of claim data. | chat-api fixed port, `/amani-claim-chat-agent/chat` |

The chat agent never calls `claimapi` directly, and `claimtools` holds no state of its own, so the
three deploy and scale independently.

## Deploying

Each package is a separate Agent Manager component built from this repo, distinguished by
`appPath`. Deploy bottom-up — `claimapi`, then `claimtools`, then the agent — since each needs the
previous one's URL.

| Component | `appPath` | Subtype | Port | Base path | Schema |
|---|---|---|---|---|---|
| `claimapi` | `/claimapi` | `custom-api` | `8080` | `/` | `/claimapi/openapi.yaml` |
| `claimtools` | `/claimtools` | `custom-api` | `9091` | `/mcp` | `/claimtools/openapi.yaml` |
| `Amani-Claim-ChatAgent` | `/Amani-Claim-ChatAgent` | `chat-api` | fixed | — | — |

Both `custom-api` components carry a committed OpenAPI document, since Agent Manager requires one.
`claimapi/openapi.yaml` is generated from the service declarations (`bal build --export-openapi`,
with the two per-service specs merged and re-rooted under `/claims` and `/customers`) — regenerate
it after changing any resource signature. `claimtools/openapi.yaml` is necessarily a transport
description, not a capability one: MCP multiplexes every tool over a single JSON-RPC endpoint, so
the seven tools are not URL paths and cannot be expressed in OpenAPI. Read the tool list from
`tools/list` over the protocol, never from that file.

The chat agent needs an attached LLM provider.

Build type is `buildpack` with language `ballerina` — which needs no `languageVersion` or
`runCommand`. All three packages target Ballerina Swan Lake `2201.13.5`.

## Configuration

**No `Config.toml` is committed, by design** — the chat agent's holds live model-provider
credentials. Every value below is supplied at deploy time instead.

| Component | Configurable | Default | Set to |
|---|---|---|---|
| `claimtools` | `backendUrl` | `http://localhost:8080` | Deployed `claimapi` `/claims` URL |
| `claimtools` | `customersBackendUrl` | same as `backendUrl` | Only if `/customers` is split onto its own host |
| `claimtools` | `autoApprovalLimit` | `1000.00` | Payout ceiling before the agent must escalate |
| `claimtools` | `servicePort` | `9091` | Leave as-is unless the component port changes |
| `claimapi` | `servicePort` | `8080` | Leave as-is |
| `Amani-Claim-ChatAgent` | `claimsToolsMcpServerUrl` | `http://localhost:9091/mcp` | Deployed `claimtools` URL, **including `/mcp`** |
| `Amani-Claim-ChatAgent` | `ballerina.ai.wso2ProviderConfig` | — | Attach an LLM provider in Agent Manager |

For a Ballerina configurable in a qualified module, the most predictable injection route is a
single `BAL_CONFIG_DATA` environment variable carrying TOML, rather than per-variable
`BAL_CONFIG_VAR_*` names:

```toml
[anupama.claimtools]
backendUrl = "https://<claimapi-host>"
customersBackendUrl = "https://<claimapi-host>"
```

## Local run

```bash
cd claimapi              && bal run     # 8080 (/claims + /customers)
cd claimtools            && bal run     # 9091
cd Amani-Claim-ChatAgent && bal run     # needs Config.toml with provider credentials
```

`Amani-Claim-ChatAgent/Config.toml` is gitignored; create it locally with:

```toml
[ballerina.ai.wso2ProviderConfig]
serviceUrl = "<generated>"
accessToken = "<generated>"
```

Generate both with the Ballerina VS Code extension: open the package, sign in when prompted, then
run **"Ballerina: Configure Default Model Provider"** from the Command Palette.

Then:

```bash
curl -X POST http://localhost:9090/amani-claim-chat-agent/chat \
  -H "Content-Type: application/json" \
  -d '{"message": "What is the status of claim CLM-1042?", "sessionId": "demo-1"}'
```

Keep the same `sessionId` across turns. Try asking it to decide `CLM-1042` while documents are
still outstanding — it should refuse and hand back a remedy rather than guess.

## Seed data

`claimapi` seeds itself on startup. There is no database.

| Claim | Customer | Type | Amount | Status | Missing documents |
|---|---|---|---|---|---|
| `CLM-1041` | `CUST-2001` Amara Okafor | Water damage | 450.00 | `READY` | — |
| `CLM-1042` | `CUST-2002` Thabo Nkosi | Water damage | 2500.00 | `MISSING_DOCUMENTS` | `proof_of_ownership.pdf`, `repair_estimate.pdf` |
| `CLM-1043` | `CUST-2003` Lindiwe Dlamini | Accidental damage | 800.00 | `READY` | — |

`POST /claims/{claimId}/reset` restores one claim to the state above.

## Known constraints

**One port, by design.** `/claims` and `/customers` are still two separate Ballerina services, but
they share a single listener. Upstream in `wso2con-NBO-Demo` they sit on `8080` and `8081`; an
Agent Manager component publishes exactly one port, so on two ports `/customers` would be
unroutable — and `getClaimAssessment`, the first tool the agent calls for any claim, fetches the
claimant through it. That failure is a transport error, which `ballerina/mcp` collapses to
`Tool 'getClaimAssessment' failed unexpectedly.`, so the model would be told nothing it could act
on. Keep both services on the one listener.

**State is per-replica and non-durable.** Everything lives in the `claimapi` process. A restart
reseeds all three claims mid-demo, and more than one replica would serve inconsistent claims. Keep
`claimapi` at a single replica.

**Divergence from the demo repo.** `claimapi/main.bal` here differs from `wso2con-NBO-Demo`: the
listener merge above, and the dropped `ai:TextDataLoader`. Port a fix to both, or treat this repo
as the source of truth for deployment.
