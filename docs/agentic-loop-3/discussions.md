# Agent-3 GitHub Discussion reporting

This contract applies only to the three `3️⃣` source profiles under #375.
It changes **agent-generated task/Epic issue-comment destinations**, not host
messages, PR comments, original human approval comments, canonical local state,
atomic events, worker capacity, repair limits or release/merge authority.
It overrides inherited task/Epic issue-comment instructions. There is no
issue-comment fallback on publication failure.

## Organization and ownership

| Mapping kind/key | Category | Purpose |
| --- | --- | --- |
| `task` / issue number | 🛠️ Task conversations | Full claim, acknowledgment/result mirrors, reports, blockers, clarification and recovery/completion notices |
| `epic` / Epic number | 🧭 Epic coordination | Brief cross-task progress and terminal/blocker outcomes |
| `agent` / `dispatcher`, `developer-1`, `developer-2` | 🤖 Agent logs | First substantive source line plus canonical link |
| `ideas` / Epic number | 🧭 Epic coordination | Optional ideas and improvements |
| `corners` / Epic number | 🧭 Epic coordination | Corner cases and unclear requirements |
| `problems` / Epic number | 🧭 Epic coordination | Agentic-loop problems; add a closing update when resolved |

The categories belong to the **Agentic loop** section, configured through
GitHub's web UI. The API verifies the exact categories and existing
`3️⃣disp`, `3️⃣dev1`, `3️⃣dev2` labels; missing setup blocks affected operations.
Agent logs get their role label; task/Epic/topic logs get all three participating
role labels. No test label or title prefix is used.

Dispatcher alone creates/verifies mappings under the existing owned repository
gate, after authorization and task selection and before first worker launch.
Use `Initialize-Agent3Discussion`; task IDs are not guessed from titles.
Use `Publish-Agent3IssueDiscussionLink` to add/read back a bounded link in the
issue body, preserving scope, checklist, labels and native relationships.
Workers obtain IDs from the shared registry using assignment issue/Epic/worker
identity, not new host-message fields.

Reuse the same live task Discussion across repair/finalize and reopening.
Do not replay old handoffs or reset history on reopening. Epic and agent logs
start clean; the deleted task trials are never adopted. Existing explicitly
chosen clean logs may be registered using `-ExistingId` during approved setup.
This verifies repository/category/labels and retains their opening body rather
than using the title as identity or silently remapping an active claim.

## Publication

Import `Agent3Coordination.psm1`. All Discussion GraphQL requests use files,
keeping large JSON bodies and Windows paths off the command line.

Under the existing gate, with independently verified authority, use:

```powershell
$taskLog = Initialize-Agent3Discussion -Repository $repository -Kind task `
    -Key ([string]$task.issue) -ActorLogin $actualLogin -Directory $sharedRoot `
    -GateOwner $gateOwner
$agentLog = Get-Agent3MappedDiscussion $repository agent $workerId $sharedRoot
Publish-Agent3IssueDiscussionLink $taskLog $sharedRoot $gateOwner
```

Initialize `epic`, all three `agent` mappings and the three fixed topic mappings
the same way before use. `-ExistingId` is explicit configuration, not authority
to adopt another workflow's claim. Freshly verify the intended actor's category
permissions and shared-directory access in the actual host.

Publish reports and full acknowledgment/result mirrors with:

```powershell
$publication = Publish-Agent3DiscussionReport -Mapping $taskLog `
    -AgentMapping $agentLog -Id $stableOperationId -Text $fullReportOrEvent `
    -ActorLogin $actualLogin -AgentId $workerId -CreatedUtc $actualUtc `
    -Directory $sharedRoot
$publication.canonical.url
$publication.indexStatus
```

The canonical body contains the source report/event exactly, with a compact
italic one-line header and bold agent name. `New-Agent3DiscussionBody` supports
inline source links and created/updated timestamps; equal instants use one
timestamp. Live posts never say "Historical copy". New posts are a chronological
top-level stream, not separate run threads. Preserve useful paragraph formatting
and collapsed diagnostics within the substantive body.

For a claim mirror, supply its full existing claim object as `-Claim`.
The helper emits the unchanged `fingvibe-real-claim-v1` marker and a single
fenced JSON block inside collapsed-by-default `<details>` / "Claim details".
Do not supply another JSON block in the prose. Raw-body readers recover and
validate the JSON regardless of visual collapse.

Each claim revision has a distinct operation ID; use `-CommentId` and a freshly
verified `-ExpectedBody` to update the same claim comment. Published event
mirrors are immutable by policy. Preserve actual reporter/host correlation;
matching GitHub account authorship alone is not authenticated agent identity.

Agent entries contain a canonical link and the first substantive source line
when available. Control markers, JSON-only content and HTML wrappers are not
previews. There is no invented summary or duplicated full control record.

Relevant topic observations need no per-post human approval. Publish them with
`New-Agent3DiscussionBody` and `Publish-Agent3DiscussionComment`, adding a stable
`<!-- agent3-publication:<operation-id> -->` marker. They are informational:
never ingest them as assignments/events, infer implementation authority or
automatically create issues from them. Task evidence stays canonical; link it.

## Failure and recovery

Canonical task/Epic publication and exact account/body/identity readback are
mandatory. Before mutation, immutable intents reserve an operation. A definitive
process-start failure can be retried only after fresh inspection. Throttling,
API/response failure or interrupted publication retains an uncertain intent;
absence from a later read is **not** permission to repeat it.

If the intended marker/body already exists exactly once, verify it rather than
publishing again. Wrong account, wrong destination, duplicate marker, changed
opening mapping, missing/deleted or unexpectedly edited verified canonical
content blocks affected verification. No expiry, silent recreation, invented
evidence or authority recovery is permitted.

After verified canonical publication, a failed agent index is explicitly
**pending and nonblocking**. Warnings and durable failure observations surface
the error. Calling the same report operation again verifies the canonical post
and reconciles only its projection; it never replays host delivery/execution.
An uncertain absent index still needs explicit disposition of that attempt
before another write. Reconstruct only from the verified canonical message,
original operation metadata and persisted pending record, not from other prose.

Publish only concise reports and necessary control JSON. Do not publish secrets,
sensitive data or raw transcripts. Preserve original owner approval issue
comments and their existing independent verification route.

## Evidence collection and storage

The existing shared root gains:

```text
discussions\                 Immutable repository/kind/key mappings
discussion-operations\       Mapping, label, issue-link and comment intents
discussion-publications\     Verified canonical/index receipts
discussion-indexes\          Exact pending projection records
discussion-index-errors\     Explicit failed projection observations
discussion-requests\         Temporary file-backed API requests
```

This is a reporting registry, not a replacement `state.json` or alternate
environment. Existing state/message/event schema versions stay unchanged.
Do not commit local registry files.

Run `Get-Agent3DispatcherPreflight.ps1 -DiscussionDirectory <absolute-shared-root>`.
It keeps fully paginated legacy/foreign issue-comment inspection and additionally
collects task Discussion claims and historical completion notices, including
all comment and historical reply pages. `discussion-claim` findings are
conservative owning-workflow evidence: compare them with authoritative state,
canonical events and actual stopped execution, never feed twelve-repair mirrors
to the legacy three-repair parser or assume every historical mirror is live.
Missing collection/mapping evidence is a blocker, not free capacity.

Dispatcher's historical completion self-healing notice moves to the task
Discussion; existing issue-comment notices remain valid and are still read.
The 30-minute rule, notice provenance and stopped/release safeguards do not change.

## Controlled cutover

Source delivery does not modify saved Automations or running sessions.
After affected workers are independently verified stopped and claims are
reconciled, obtain explicit approval to update saved profiles and select clean
Discussion mappings. Preserve original state/events/approvals; no in-flight
adoption, record deletion or live activation is authorized by this source change.

Before resuming, verify all three source selections, actual actor permissions,
canonical/index publication and readback, issue-body links, preflight discovery,
unchanged guarded host delivery and execution-stop correlation in an explicitly
authorized real-host trial. Synthetic tests prove helper behavior, not that
the desktop host supports delivery or that live cutover occurred.

If rollback is required, stop/reconcile first and restore the previously approved
source selections under explicit approval. Preserve reporting evidence and
claims. Never silently switch a failed operation back to issue comments.
