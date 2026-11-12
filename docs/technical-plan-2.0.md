# BLACK MERIDIAN

## Technical Implementation Correction — Revised Contracts, 136-Task Backlog, and Dependency Audit

Revision: Technical Plan 2.0 | Target: Roblox / Luau | Scope: Engineering corrections, not a game redesign

This document is the authoritative engineering plan for the repository. Task progress is tracked in `docs/task-log.md`.

## 1. Executive correction

The established Black Meridian universe remains unchanged. Orthea, the Aster Loom, Cants, Verses, Burdens, Dissonance, Descents, and Waymarks retain their existing narrative and gameplay roles.

This revision focuses on making the implementation plan safer, more complete, and enforceable.

The principal corrections are:

1. Establish a 136-task engineering baseline with explicit priority, dependencies, implementation scope, security requirements, tests, and definition of done.
2. Enforce BM-016, BM-046, and BM-075 as genuine downstream dependencies rather than isolated completed tasks.
3. Route every client-to-server gameplay request through validated, rate-limited, server-authoritative adapters.
4. Replace unrestricted persistence structures with typed schemas and runtime-enforced limits.
5. Introduce fenced session leases, durable reward receipts, uncertain-write recovery, and conservative profile-size budgets.
6. Require measurable implementation coverage for every launch region, quest, Cant, Verse, Burden, progression milestone, Descent, and endgame feature.
7. Preserve Nearness as the first vertical-slice Cant while making future starting-Cant choices data-driven.

One source limitation matters: the previous complete 96-row task register and canonical content inventory are not included in this document. Therefore, the 136-row register below is a corrected proposed baseline, not a verified one-to-one renumbering of the original 96 tasks. The specifically identified tasks BM-001, BM-016, BM-046, and BM-075 retain their stated responsibilities. Other existing task IDs must be reconciled against the original register before this becomes the authoritative replacement.

## 2. Corrected Roblox architecture

### 2.1 Server authority

Black Meridian must use a server-authoritative model. The client controls presentation and submits player intentions; the server decides whether those intentions are legal and what effects they produce.

| Component          | Authority                              | Responsibility                                           |
| ------------------ | -------------------------------------- | -------------------------------------------------------- |
| Client controllers | Client                                 | Input, camera, animations, UI, visual prediction         |
| Request adapters   | Server                                 | Validate and authorize incoming requests                 |
| CombatService      | Server                                 | Damage, hit validation, resources, combat state          |
| CantService        | Server                                 | Cant eligibility, activation, cooldowns                  |
| VerseService       | Server                                 | Verse execution and effects                              |
| BurdenService      | Server                                 | Burden selection and consequences                        |
| QuestService       | Server                                 | Quest state, choices, progression                        |
| WaymarkService     | Server                                 | Waymark activation and unlocks                           |
| TravelService      | Server                                 | Travel eligibility, party readiness, teleport initiation |
| DescentService     | Server                                 | Run lifecycle, encounters, completion                    |
| RewardService      | Server                                 | Grant decisions, receipts, reconciliation                |
| ProfileService     | Server                                 | Profile loading, leases, persistence                     |
| ContentRegistry    | Shared definitions, server enforcement | Canonical content IDs and definitions                    |

Clients must never directly assign permanent rewards, quest completion, Cant unlocks, Waymark progress, or Descent results.

### 2.2 Recommended project structure

```
BlackMeridian/
  default.project.json
  src/
    shared/
      Contracts/
      Types/
      Catalogs/
      Constants/
    server/
      Bootstrap.server.luau
      Network/
        RequestDispatcher.luau
        Validators/
        Adapters/
      Services/
        ProfileService.luau
        RewardService.luau
        CombatService.luau
        CantService.luau
        VerseService.luau
        BurdenService.luau
        QuestService.luau
        WaymarkService.luau
        TravelService.luau
        DescentService.luau
      Persistence/
      Content/
    client/
      Bootstrap.client.luau
      Controllers/
      UI/
    tests/
      Unit/
      Integration/
      Security/
      Persistence/
      Content/
```

Use Rojo for project synchronization, Luau type checking, StyLua for formatting, Selene for static linting, and automated tests in CI. Exact tool versions are pinned by BM-002.

### 2.3 Server initialization order

The server must initialize in this order:

1. Content registries, configuration, and schema validation
2. Persistence, lease, and reward infrastructure
3. Gameplay services and their dependencies
4. Request adapters and remote dispatcher
5. Player session activation and gameplay availability

If profile loading or a required service fails, the player enters a non-mutating loading/error state. Gameplay must not proceed with a fabricated empty profile.

## 3. Revised client/server contracts

### 3.1 Remote architecture

Use one versioned gameplay ingress, `ActionRequest`, with an `ActionResult` response. Server-to-client presentation uses separate one-way remotes such as `StateDelta`, `CombatCue`, `PartyState`, and `TravelState`.

Every request passes through the same validation pipeline, including combat requests. The dispatcher may internally prioritize high-frequency combat actions, but they must not bypass security checks.

Request envelope:

```
{
    v = 1,
    requestId = "client-generated-uuid",
    sessionEpoch = "server-issued-epoch",
    seq = 42,
    action = "QuestChoice",
    payload = {
        questId = "canonical-quest-id",
        nodeId = "canonical-node-id",
        choiceId = "canonical-choice-id",
        offerId = "server-issued-offer-id",
        revision = 7
    }
}
```

The server obtains player identity from `OnServerEvent(player, request)`, never from a claimed `userId` field.

The session epoch is a freshness identifier, not a secret or proof of authorization.

### 3.2 Mandatory validation sequence

Every request must pass these checks, in order:

1. Envelope: correct version, known action, bounded structure, valid request ID, valid sequence number.
2. Session: player connected, profile loaded, session epoch current, server lease valid.
3. Replay: request ID not previously committed with conflicting contents; sequence not stale.
4. Rate limit: action-specific token bucket and overall per-player budget.
5. Payload: exact allowed fields, correct types, canonical IDs, finite numbers, bounded strings and arrays.
6. Authorization: the player owns or is eligible for the requested action.
7. World state: position, combat state, quest stage, party membership, and relevant cooldowns verified on the server.
8. Mutation: service executes the authorized transition, with persistence guarantees where required.
9. Response: send the outcome and authoritative revision; do not expose hidden quest or security state.

Default policy: unknown actions are rejected, never forwarded to gameplay services.

### 3.3 Complete launch request registry

This is the allowed client-to-server gameplay request surface. New actions require a registered schema, secure adapter, tests, and a backlog task.

| Request                                                    | Server-side validation                                                                           | Owning task |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ----------- |
| `ClientHello`                                              | Protocol version, live connection, session bootstrap state                                       | BM-017      |
| `CombatInput`                                              | Legal action enum, attack cadence, equipped weapon, stamina, combat state, server hit validation | BM-061      |
| `CantEquip`                                                | Owned Cant, allowed slot, current restrictions                                                   | BM-064      |
| `VerseCast`                                                | Unlocked Verse, compatible Cant, resources, cooldown, target and range                           | BM-067      |
| `DissonanceAction`                                         | Valid Dissonance state, legal transition, cooldown                                               | BM-068      |
| `BurdenChoice`                                             | Offered Burden, valid choice window, eligibility, no duplicate claim                             | BM-070      |
| `QuestChoice`                                              | Current quest node, server-issued offer, permitted choice, revision                              | BM-074      |
| `WaymarkActivate`                                          | Registered Waymark, proximity, prerequisites, progression                                        | BM-076      |
| `RespawnRequest` / `ReviveRequest`                         | Death state, checkpoint, ally eligibility, range, revive window                                  | BM-079      |
| `InventoryEquip`                                           | Item ownership, valid slot, equipment restrictions                                               | BM-080      |
| `NPCInteract`                                              | Registered NPC, server distance, dialogue state                                                  | BM-086      |
| `CollectibleClaim`                                         | Registered collectible, eligibility, proximity, durable receipt                                  | BM-088      |
| `TravelReady`                                              | Valid travel ticket, party membership, ready-state revision                                      | BM-090      |
| `TravelPropose`                                            | Leader authority, unlocked destination, valid roster                                             | BM-091      |
| `DescentEnter`                                             | Entry unlock, location, party/run state                                                          | BM-093      |
| `StarterCantSelect`                                        | Server-offered canonical starter, eligibility, one-time choice rules                             | BM-106      |
| `CraftRequest`                                             | Recipe, materials, capacity, atomic spend/grant                                                  | BM-109      |
| `VendorPurchase`                                           | Vendor proximity, price, currency, stock, atomic purchase                                        | BM-110      |
| `DescentQueue` / `DescentCancel`                           | Eligibility, tier, roster, queue ownership                                                       | BM-115      |
| `PartyInvite` / `PartyAccept` / `PartyLeave` / `PartyKick` | Membership, leadership, invite expiry, party limits                                              | BM-116      |
| `SettingsUpdate`                                           | Whitelisted cross-device settings only, bounded values                                           | BM-128      |

Requests not in this registry must remain unavailable. For example, a client may not call `GrantReward`, `CompleteQuest`, `SetWaymark`, `ApplyDamage`, or `FinishDescent`.

Server-to-client messages are not requests and do not grant authority.

### 3.4 Exact QuestChoice contract

```
export type QuestChoicePayload = {
    questId: string,
    nodeId: string,
    choiceId: string,
    offerId: string,
    revision: number,
}
```

Validation requirements:

- `questId`, `nodeId`, `choiceId`: canonical ASCII IDs, maximum 48 bytes each.
- `offerId`: server-issued opaque ID, maximum 64 bytes, bound to the player, quest instance, node, and permitted choices.
- `revision`: nonnegative integer matching the authoritative quest revision.
- Player must currently be at the specified quest node.
- Choice must be present in the current server-side offer.
- The offer must not be expired, consumed, or superseded.
- The resulting quest transition must be legal in the canonical quest graph.
- Permanent consequences must use durable reward/choice receipts.
- A duplicate request with the same request ID and payload returns the original result, not a second transition.

Successful response:

```
{
    requestId = "...",
    status = "OK",
    action = "QuestChoice",
    stateRevision = 8,
    data = {
        questId = "canonical-quest-id",
        nextNodeId = "canonical-next-node"
    }
}
```

The response must not reveal unreached quest branches.

### 3.5 Exact TravelReady contract

```
export type TravelReadyPayload = {
    ticketId: string,
    ready: boolean,
    revision: number,
}
```

Validation requirements:

- `ticketId`: server-issued, maximum 64 bytes.
- `ready`: strict boolean.
- `revision`: integer matching the current travel roster revision.
- Ticket must belong to the player's current party and be unexpired.
- The player must still be a member of that party.
- Destination and travel route must be unlocked.
- Party must not be in a conflicting Descent or teleport state.
- The ready-state change must be idempotent.
- A stale roster revision must return `STALE_STATE`.
- Teleportation is initiated only by the server after a final eligibility and roster check.

Important distinction: `TravelReady` only changes readiness. It cannot directly select a destination, override party leadership, or execute `TeleportAsync`.

### 3.6 Replay protection

BM-016 must implement:

- Per-session epoch and monotonic sequence tracking.
- Request-ID deduplication with payload fingerprinting.
- A bounded, approximately 10-minute response cache.
- Rejection of stale sequences not found in the duplicate-response cache.
- Detection of reused request IDs with changed payloads.
- Independent, persistent idempotency for rewards and permanent progression.

Sequence numbers prevent stale gameplay requests within a session. They are not sufficient for durable reward deduplication across server crashes or reconnects.

Requests that complete after the client disconnects must still resolve safely under the server's session and persistence rules.

### 3.7 Rate and payload limits

Initial engineering budgets, subject to load testing:

| Action class                    | Initial limit             | Maximum payload |
| ------------------------------- | ------------------------- | --------------- |
| Combat input                    | 15 requests/sec, burst 20 | 256 bytes       |
| Verse and Cant actions          | 5/sec, burst 8            | 512 bytes       |
| Quest and Burden choices        | 2/sec, burst 4            | 512 bytes       |
| Waymark and collectible actions | 2/sec, burst 4            | 512 bytes       |
| Party and travel actions        | 3/sec, burst 6            | 512 bytes       |
| Crafting and purchases          | 2/sec, burst 4            | 512 bytes       |
| General gameplay envelope       | 30/sec, burst 40          | 1 KiB           |

These are design limits, not measured Roblox platform guarantees. Serialized payload limits must be enforced with a bounded validator, and nested depth and field counts must be checked before expensive processing.

## 4. Typed and bounded persistence schemas

### 4.1 Core Luau types

The following replaces unrestricted definitions such as `quests: {[string]: any}`.

```luau
--!strict

export type QuestStatus =
    "Locked" | "Active" | "Completed" | "Failed"

export type QuestProgress = {
    questId: string,
    nodeId: string,
    status: QuestStatus,
    revision: number,
    flags: {[string]: boolean},
    choices: {[string]: string},
}

export type QuestJournal = {
    active: {[string]: QuestProgress},
    completed: {[string]: boolean},
}

export type CantProgress = {
    unlocked: {[string]: boolean},
    equipped: string?,
    verses: {[string]: {[string]: boolean}},
}

export type BurdenProgress = {
    discovered: {[string]: boolean},
    active: {string},
    dissonance: number,
}

export type WaymarkProgress = {
    activated: boolean,
    rank: number,
}

export type InventoryStack = {
    itemId: string,
    quantity: number,
    instanceId: string?,
}

export type DescentProgress = {
    unlockedTiers: {[string]: number},
    bestClears: {[string]: number},
}

export type RewardIntent = {
    grantId: string,
    sourceId: string,
    createdAt: number,
    rewardCatalogId: string,
}

export type ReceiptState = {
    permanent: {[string]: boolean},
    seasonal: {[string]: number},
    pending: {[string]: RewardIntent},
}

export type SessionLease = {
    sessionId: string,
    jobId: string,
    fence: number,
    expiresAt: number,
}

export type PlayerProfile = {
    schemaVersion: number,
    revision: number,
    lease: SessionLease?,
    chapterId: string,
    quests: QuestJournal,
    cants: CantProgress,
    burdens: BurdenProgress,
    waymarks: {[string]: WaymarkProgress},
    inventory: {InventoryStack},
    balances: {[string]: number},
    descents: DescentProgress,
    receipts: ReceiptState,
}
```

These are structural types. They do not, by themselves, enforce array sizes, identifier validity, or numeric limits. Runtime validation is mandatory before a profile is accepted or saved.

### 4.2 Explicit schema bounds

| Structure                         | Required limit                                 |
| --------------------------------- | ---------------------------------------------- |
| Active quests                     | Maximum 12                                     |
| Completed quest IDs               | Maximum 512                                    |
| Flags per quest                   | Maximum 16                                     |
| Recorded choices per quest        | Maximum 8                                      |
| Canonical ID length               | Maximum 48 ASCII bytes                         |
| Unlocked Cants                    | Maximum 32                                     |
| Verse unlock entries              | Maximum 128 total                              |
| Discovered Burdens                | Maximum 64                                     |
| Active Burdens                    | Maximum 8, further limited by game rules       |
| Waymarks                          | Maximum 128                                    |
| Inventory stacks                  | Maximum 200                                    |
| Balance types                     | Maximum 16                                     |
| Descent progress entries          | Maximum 64                                     |
| Permanent reward receipts         | Maximum 1,024 before compact-storage migration |
| Active-season repeatable receipts | Maximum 512                                    |
| Pending reward intents            | Maximum 32                                     |
| Profile soft size                 | 128 KiB encoded                                |
| Profile hard size                 | 192 KiB encoded                                |

These are conservative launch budgets, not Roblox's maximum DataStore object size. Roblox's documented per-key DataStore limit is substantially higher; the lower game-specific cap creates room for migrations and unexpected growth.

The canonical registry must reject content exceeding these bounds before deployment. If the actual established Black Meridian content requires higher limits, the limits must be revised with measured storage evidence rather than silently truncating data.

No permanent receipts or quest consequences may be silently discarded to make a profile fit.

### 4.3 Example strict payload validator

```luau
--!strict

export type QuestChoicePayload = {
    questId: string,
    nodeId: string,
    choiceId: string,
    offerId: string,
    revision: number,
}

local function validId(value: unknown, maxLen: number): boolean
    return type(value) == "string"
        and #value >= 1
        and #value <= maxLen
        and string.match(value, "^[%w_%-]+$") ~= nil
end

local ALLOWED = {
    questId = true,
    nodeId = true,
    choiceId = true,
    offerId = true,
    revision = true,
}

local function parseQuestChoice(
    raw: unknown
): QuestChoicePayload?

    if type(raw) ~= "table" then
        return nil
    end

    local p = raw :: {[string]: unknown}
    local count = 0

    for key in pairs(p) do
        if type(key) ~= "string" or not ALLOWED[key] then
            return nil
        end
        count += 1
        if count > 5 then
            return nil
        end
    end

    local questId = p.questId
    local nodeId = p.nodeId
    local choiceId = p.choiceId
    local offerId = p.offerId
    local revision = p.revision

    if not validId(questId, 48)
        or not validId(nodeId, 48)
        or not validId(choiceId, 48)
        or not validId(offerId, 64) then
        return nil
    end

    if type(revision) ~= "number"
        or revision ~= revision
        or revision < 0
        or revision > 2147483647
        or revision % 1 ~= 0 then
        return nil
    end

    return {
        questId = questId :: string,
        nodeId = nodeId :: string,
        choiceId = choiceId :: string,
        offerId = offerId :: string,
        revision = revision,
    }
end

return parseQuestChoice
```

This validator checks shape only. The QuestService adapter must additionally verify quest ownership, offered choices, current node, offer expiration, and revision before mutation.

## 5. Persistence, leases, and reward integrity

### 5.1 Session lease specification

Profile ownership must be enforced using an authoritative lease stored with the player profile, not only an in-memory lock.

Recommended initial parameters:

| Property            | Requirement                                    |
| ------------------- | ---------------------------------------------- |
| Lease owner         | Server `JobId` plus unique session ID          |
| Lease lifetime      | 90 seconds                                     |
| Renewal interval    | 30 seconds                                     |
| Fencing token       | Monotonically increasing integer               |
| Acquisition         | Atomic `UpdateAsync`                           |
| Renewal             | Atomic `UpdateAsync`, owner and fence verified |
| Release             | Conditional update by current owner only       |
| Expired takeover    | New owner receives a higher fence              |
| Stale server writes | Rejected by fence mismatch                     |
| Lease loss          | Immediately disable profile mutations          |

Every durable profile mutation must check the current session ID and fencing token inside its `UpdateAsync` callback.

A server that loses its lease must not continue writing simply because it still has an in-memory copy of the player's profile.

Teleport handoff must follow the same rule. The departing server cannot assume the arriving server has acquired ownership.

### 5.2 Permanent reward receipts

Permanent progression grants need stable receipt IDs derived from authoritative content and player identity.

Examples of receipt categories:

- First completion of a particular canonical quest.
- A one-time Waymark progression unlock.
- A unique Cant or Verse unlock.
- A one-time boss or chapter milestone reward.

The server must record the receipt and apply the corresponding profile change in the same atomic profile `UpdateAsync`.

If the same receipt appears again, the operation returns the already-committed outcome without applying the reward twice.

Permanent receipts must never expire or be pruned merely because they are old. When the receipt catalog approaches its size budget, migrate to a compact, versioned representation that preserves every claim.

### 5.3 Repeatable Descent rewards

Repeatable rewards require a different policy from permanent one-time unlocks.

Each completed Descent reward should have a server-created identifier based on the run, eligible player, and reward slot. The corresponding grant must be committed idempotently within the profile.

Use bounded seasonal receipts, durable pending intents, and a documented reconciliation window. Closed seasons must reject old reward requests; legitimate unresolved grants must enter an explicit recovery process.

A finite rolling receipt cache cannot guarantee unlimited historical exactly-once delivery. The implementation must not claim that it does.

For launch, the required guarantees are:

- Permanent one-time rewards: durable, non-pruned idempotency.
- Active-season repeatable rewards: idempotency within the retained season ledger.
- Unknown write outcomes: retry the same grant ID.
- Expired or archived repeatable grants: controlled reconciliation or operator recovery, never a fresh automatic grant ID.
- Receipt capacity exhaustion: stop new commits safely and preserve pending recovery information.

### 5.4 Uncertain-write reconciliation

A failed or timed-out `UpdateAsync` does not prove the write was rejected. It may have committed before the server received an error.

Therefore:

1. Mark the operation `PENDING`, not `FAILED`.
2. Preserve its original deterministic grant ID.
3. Retry idempotently with bounded exponential backoff.
4. Inspect the authoritative committed receipt/state.
5. Return `COMMITTED` when confirmed.
6. If the session lease is lost, stop local writes and hand recovery to the next valid session.
7. Escalate unresolved intents after the configured retry window.

Never compensate an uncertain grant by blindly issuing a second reward.

### 5.5 Atomic grant pattern

This example demonstrates the critical single-profile-key behavior. The full implementation must use the schema validators and reward catalog from BM-021 through BM-045.

```luau
--!strict

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

local store = DataStoreService:GetDataStore("BMProfilesV3")
local MAX_BYTES = 192 * 1024

type Lease = {
    sessionId: string,
    fence: number,
    expiresAt: number,
}

type Profile = {
    schemaVersion: number,
    revision: number,
    lease: Lease?,
    receipts: {
        permanent: {[string]: boolean},
    },
    balances: {[string]: number},
}

local function grantOnce(
    key: string,
    sessionId: string,
    fence: number,
    receiptId: string,
    currencyId: string,
    amount: number
): (boolean, string)

    -- The caller must have validated these IDs
    -- against the authoritative reward catalog.
    if amount <= 0 or amount > 100000
        or amount % 1 ~= 0 then
        return false, "BAD_GRANT"
    end

    local now = os.time()

    local ok, result = pcall(function()
        return store:UpdateAsync(key, function(old)
            if type(old) ~= "table" then
                return nil
            end

            -- Production code validates the full
            -- stored profile before this cast.
            local p = old :: Profile
            local lease = p.lease

            if p.schemaVersion ~= 3
                or lease == nil
                or lease.sessionId ~= sessionId
                or lease.fence ~= fence
                or lease.expiresAt <= now then
                return nil
            end

            if p.receipts.permanent[receiptId] then
                return p
            end

            local nextProfile = table.clone(p)
            local nextReceipts = table.clone(p.receipts)
            local nextPermanent =
                table.clone(p.receipts.permanent)
            local nextBalances = table.clone(p.balances)

            nextPermanent[receiptId] = true
            nextReceipts.permanent = nextPermanent

            nextBalances[currencyId] =
                (nextBalances[currencyId] or 0) + amount

            nextProfile.receipts = nextReceipts
            nextProfile.balances = nextBalances
            nextProfile.revision = p.revision + 1

            if #HttpService:JSONEncode(nextProfile)
                > MAX_BYTES then
                return nil
            end

            return nextProfile
        end)
    end)

    if not ok or result == nil then
        return false, "PENDING"
    end

    return true, "COMMITTED"
end

return grantOnce
```

This is an atomic grant pattern, not a complete persistence service. In particular, production code must validate all nested stored fields, enforce balance caps, handle profile migrations, track pending intents, and distinguish capacity/lease errors internally.

No yielding, remote calls, random ID generation, or external side effects may occur inside the `UpdateAsync` transform.

### 5.6 Failure-mode requirements

| Failure                                | Required behavior                                          |
| -------------------------------------- | ---------------------------------------------------------- |
| Two servers load one player            | Only valid fenced lease owner may mutate                   |
| Server crashes after reward commit     | Same receipt produces no duplicate                         |
| Server crashes before reward commit    | Pending intent remains recoverable if durably recorded     |
| DataStore request times out            | Outcome remains uncertain until reconciled                 |
| Profile exceeds hard size              | Reject mutation, retain existing profile                   |
| Receipt catalog fills                  | Fail closed; migrate or recover, never prune silently      |
| Malformed saved profile                | Quarantine mutation, preserve original data for recovery   |
| Player teleports during save           | New session waits for valid lease handoff                  |
| DataStore budget exhausted             | Queue bounded writes, apply backoff, prevent unsafe grants |
| Client retries quest or travel request | Return original outcome or safe stale-state rejection      |

## 6. Starting Cant decision

**Vertical slice: Nearness only.** Implementing one Cant first is the correct engineering decision. It reduces combat permutations, tutorial branching, Verse combinations, and persistence complexity while the fundamental systems are being validated.

**Full launch: data-driven starter policy.** The engine should not permanently hardcode Nearness as the only possible first Cant. Support an eligible-starter catalog so other already-established Cants can become starting choices without rewriting onboarding or progression.

Recommendation: keep Nearness as the guaranteed first-playthrough baseline unless additional starting Cants can pass equivalent onboarding, narrative, balance, and progression tests before launch. Alternate starters could then be available through a subsequent character or replay cycle, using the existing canon rather than inventing new Cants.

If the additional starters pass those gates early, launch may offer multiple first-playthrough choices. Otherwise, ship the Nearness baseline and retain the extensible implementation.

Required tests include first-Cant selection, tutorial completion, all starter-specific Verse unlocks, early Burden interactions, Waymark I progression, save/load behavior, and multiplayer parties containing different starters.

This decision is represented by BM-106 and BM-107 below.

## 7. Corrected development backlog

The following register contains 136 numbered engineering tasks. Each task includes:

- P: Priority — P0 foundational or blocking, P1 launch-required, P2 lower-risk supporting work.
- D: Hard prerequisite task IDs. A dependent task must not begin until its prerequisites pass.
- Build: Precise implementation scope.
- Security: Required trust boundary or protection.
- Test: Minimum required automated or reproducible verification.
- Done: Observable completion criterion.

A task is not complete merely because its code compiles. Its security checks, tests, and acceptance conditions must also pass.

### Phase A — Repository, contracts, and secure networking

BM-001 through BM-020 | Foundation gate: BM-020

BM-001 · P0 · D: None
Build: Initialize the Rojo-compatible repository, `src/shared`, `src/server`, `src/client`, `tests`, project configuration, and minimal server/client bootstraps. Security: Server code must remain outside replicated client containers. Test: Project builds and starts without errors. Done: Reproducible clean build with no gameplay logic or privileged remotes.

BM-002 · P0 · D: 001
Build: Pin Rojo, Luau analysis, StyLua, Selene, and test-runner versions; document installation and commands. Security: Pin dependency versions and prohibit unreviewed executable packages. Test: Clean environment installs and runs tools. Done: Toolchain reproducible in CI.

BM-003 · P0 · D: 001
Build: Define service ownership, module boundaries, dependency injection, and server-authority rules. Security: Document every trust boundary. Test: Architecture review and module dependency checks. Done: Approved architecture specification with no circular service dependencies.

BM-004 · P0 · D: 003
Build: Define immutable canonical content IDs for Orthea regions, quests, Cants, Verses, Burdens, Waymarks, bosses, and Descents. Security: IDs are server-validated, not client-created. Test: Duplicate, invalid, and missing-reference fixtures. Done: Registry schema rejects inconsistent content.

BM-005 · P0 · D: 003, 004
Build: Implement shared typed contracts for requests, responses, player state, and content definitions. Security: No unrestricted persistent `any` fields. Test: Strict Luau type checking. Done: All public contracts type-check.

BM-006 · P0 · D: 001, 003
Build: Add environment configuration and server-owned feature flags. Security: Clients cannot modify rollout flags. Test: Invalid configuration and disabled-feature cases. Done: Every experimental feature defaults to disabled.

BM-007 · P0 · D: 002
Build: Provide deterministic simulation clocks, seeded test RNG, and time abstraction. Security: Client timestamps never establish gameplay authority. Test: Repeat identical simulations with fixed seeds. Done: Deterministic test outcomes.

BM-008 · P0 · D: 002, 003
Build: Add structured server logs, correlation IDs, error categories, and telemetry hooks. Security: Exclude secrets, sensitive player data, and full profile dumps. Test: Redaction and event-schema tests. Done: Security and persistence failures are traceable.

BM-009 · P0 · D: 002, 005
Build: Create unit, integration, security, and fault-injection test harnesses. Security: Tests cannot write to production DataStores. Test: Intentional failure must fail CI. Done: Isolated test environments and fixtures work.

BM-010 · P0 · D: 002, 009
Build: Configure CI for build, formatting, linting, type checking, and tests. Security: No production credentials in CI logs. Test: Passing and failing pull-request fixtures. Done: Merge blocked on required check failures.

BM-011 · P0 · D: 005, 006
Build: Create `ActionRequest`, `ActionResult`, and approved server-to-client remotes. Security: No client-facing reward or state mutation remotes. Test: Remote inventory audit. Done: Only allowlisted remotes exist.

BM-012 · P0 · D: 005, 011
Build: Define versioned request envelopes, correlation IDs, sequence fields, and response codes. Security: Reject unsupported versions and malformed envelopes. Test: Contract serialization fixtures. Done: Every request has a typed envelope.

BM-013 · P0 · D: 004, 012
Build: Implement strict payload validators with field, size, depth, ID, and number limits. Security: Reject extra fields and malformed nested tables. Test: Fuzzed payloads and boundary values. Done: No malformed request reaches a gameplay service.

BM-014 · P0 · D: 003, 013
Build: Implement server authorization contexts using actual Player identity, session state, and service-owned permissions. Security: Ignore client-claimed ownership. Test: Forged IDs and unauthorized actions. Done: Authorization is enforced independently of payload validity.

BM-015 · P0 · D: 011, 014
Build: Add per-action and aggregate token-bucket rate limiting. Security: Limit spam and computational amplification. Test: Burst, sustained flood, and fairness scenarios. Done: Requests beyond budget are rejected without executing actions.

BM-016 · P0 · D: 012, 014, 015
Build: Implement replay protection, session sequence tracking, request fingerprints, and bounded duplicate-result caching. Security: Reject stale or conflicting replays. Test: Duplicate, reordered, modified, and cross-session requests. Done: No replay can repeat a gameplay mutation within its protected session.

BM-017 · P0 · D: 011, 016
Build: Implement `ClientHello`, session epochs, and connection readiness. Security: Epochs bound to server sessions, never accepted as authorization alone. Test: Reconnect and expired-epoch requests. Done: Old-session requests are rejected.

BM-018 · P0 · D: 013, 014, 015, 016, 017
Build: Implement centralized request dispatcher and secure adapter registration. Security: Default-deny unknown actions; require validation before dispatch. Test: Unregistered actions and bypass attempts. Done: Every gameplay action has one enforced ingress path.

BM-019 · P0 · D: 008, 018
Build: Standardize rejection codes, safe client errors, and abuse telemetry. Security: Do not reveal hidden progression or anti-cheat thresholds. Test: Invalid-action response matrix. Done: Rejections are consistent and logged.

BM-020 · P0 · D: 010, 018, 019
Build: Secure-networking milestone gate. Security: Audit all ingress paths and deny unauthorized mutation. Test: Run full malformed-request, replay, and rate-limit suites. Done: Networking gate passes and blocks downstream gameplay adapters until approved.

### Phase B — Persistence and reward integrity

BM-021 through BM-050 | Reward gate: BM-050

BM-021 · P0 · D: 005
Build: Define typed versioned `PlayerProfile` and nested progression structures. Security: No unrestricted stored objects. Test: Valid/invalid profile fixtures. Done: All persistent fields have explicit types.

BM-022 · P0 · D: 004, 021
Build: Define catalog-backed limits for IDs, quests, inventory, Cants, Burdens, and progression. Security: Reject unknown IDs and excessive counts. Test: Every maximum and overflow case. Done: Schema bounds are enforced.

BM-023 · P0 · D: 021, 022
Build: Implement explicit profile migrations and version dispatch. Security: Reject unsupported future schemas without destructive overwrite. Test: Upgrade fixtures and repeated migrations. Done: Migrations are idempotent.

BM-024 · P0 · D: 021, 022
Build: Implement encoded-size measurement and 128/192 KiB soft/hard limits. Security: Never truncate progression or receipts. Test: Large and malformed profiles. Done: Oversized mutations are rejected before saving.

BM-025 · P0 · D: 021, 023
Build: Implement atomic profile lease acquisition. Security: Enforce owner, expiration, and fencing generation. Test: Two-server simultaneous acquisition. Done: Only one active owner can commit.

BM-026 · P0 · D: 025
Build: Implement lease renewal and stale-owner fencing. Security: Reject writes after ownership loss. Test: Delayed renewal and expired takeover. Done: Stale server cannot commit.

BM-027 · P0 · D: 026
Build: Implement conditional release, disconnect handling, and teleport lease handoff. Security: Previous server cannot release another server's lease. Test: Disconnect/teleport races. Done: Handoff preserves single-writer ownership.

BM-028 · P0 · D: 025, 026
Build: Add safe loading, retry, read-only failure state, and profile-load timeout behavior. Security: Never replace a failed load with default data. Test: DataStore outage and corrupt profile. Done: No destructive fallback.

BM-029 · P0 · D: 024, 026, 028
Build: Implement bounded save queues, write coalescing, and backoff. Security: Preserve ordering of irreversible mutations. Test: Budget exhaustion and queue saturation. Done: No silent dropped committed changes.

BM-030 · P0 · D: 026, 029
Build: Centralize atomic `UpdateAsync` profile mutations and revision checks. Security: Every mutation verifies lease fence and schema. Test: Concurrent update conflicts. Done: No direct unguarded profile writes.

BM-031 · P0 · D: 030
Build: Implement uncertain-write classification and retry using original operation IDs. Security: Never assume timeout means rollback. Test: Simulated success-with-lost-response. Done: Ambiguous writes resolve idempotently.

BM-032 · P0 · D: 023, 024, 030
Build: Validate loaded profiles, reject corruption, and provide non-destructive repair procedures. Security: Quarantine invalid state. Test: Corrupt nested fields and schema drift. Done: Invalid profiles cannot enter gameplay.

BM-033 · P0 · D: 021, 022, 032
Build: Implement bounded inventory storage, item instances, and stack validation. Security: Prevent negative quantities and duplicate instance IDs. Test: Capacity and malformed-stack cases. Done: Inventory invariants hold after reload.

BM-034 · P0 · D: 021, 032
Build: Define currency balances, caps, and legal arithmetic. Security: No negative balances, overflow, or client-authored amounts. Test: Overflow and insufficient-funds cases. Done: Balance transitions remain valid.

BM-035 · P0 · D: 004, 022, 034
Build: Create authoritative reward catalog and deterministic receipt ID rules. Security: Reject arbitrary reward definitions. Test: Receipt collision and invalid source fixtures. Done: Every grant maps to an approved source.

BM-036 · P0 · D: 030, 035
Build: Implement permanent receipt storage and one-time claim checks. Security: Receipt and grant commit atomically; no receipt pruning. Test: Duplicate permanent grant across sessions. Done: One-time rewards cannot duplicate.

BM-037 · P0 · D: 030, 035
Build: Implement bounded seasonal repeatable-reward receipts and season closure policy. Security: Reject expired or previously committed run grants. Test: Duplicate, late, and cross-season claims. Done: Retention and recovery behavior is explicit.

BM-038 · P0 · D: 030, 035, 036, 037
Build: Implement durable pending reward intents and maximum pending count. Security: Intent IDs are server-generated and immutable. Test: Crash after intent creation. Done: Recoverable intents survive restart.

BM-039 · P0 · D: 034, 036, 037, 038
Build: Implement atomic reward application with receipt updates. Security: Grant amounts come only from the reward catalog. Test: Duplicate commit and simultaneous requests. Done: One receipt produces at most one committed grant.

BM-040 · P0 · D: 039
Build: Define controlled compensation for incorrect or disputed grants. Security: No unrestricted admin balance editing; all corrections audited. Test: Duplicate compensation request. Done: Corrections are idempotent and attributable.

BM-041 · P0 · D: 027, 031, 038, 039
Build: Recover pending grants after crash, disconnect, or lease takeover. Security: New lease owner verifies original grant identity. Test: Kill server at each commit boundary. Done: Recoverable grants resolve without duplication.

BM-042 · P0 · D: 038, 039, 041
Build: Implement durable Descent run reward records and recovery references. Security: Only server-certified run results can generate intents. Test: Crash between run completion and grant. Done: Completed eligible runs have traceable grant outcomes.

BM-043 · P0 · D: 008, 039
Build: Add reward telemetry and grant correlation records. Security: No client-generated audit events accepted as proof. Test: Correlate grant, receipt, and player session. Done: Every grant is traceable without logging entire profiles.

BM-044 · P0 · D: 031, 032, 039, 042
Build: Create persistence and reward corruption/fault-injection suite. Security: Test stale leases, malformed receipts, and conflicting commits. Test: Automated fault matrix. Done: All defined failure cases pass.

BM-045 · P0 · D: 039, 040, 041, 042, 043
Build: Expose a single `RewardService` API for quests, bosses, Waymarks, and Descents. Security: Gameplay systems cannot bypass receipt handling. Test: Mock every grant source. Done: All reward paths use the same facade.

BM-046 · P0 · D: 031, 041, 042, 045
Build: Implement reward reconciliation worker and pending-operation resolution. Security: Retry original grant IDs only; verify current lease. Test: Lost response, delayed commit, restart, and repeated recovery. Done: All recoverable ambiguous grants converge without duplicate rewards.

BM-047 · P0 · D: 024, 036, 037, 046
Build: Add receipt-capacity monitoring, compact migration, and overflow handling. Security: Never delete permanent receipts. Test: Full receipt catalog and hard-size overflow. Done: Capacity exhaustion fails safely and has a migration path.

BM-048 · P0 · D: 009, 044, 046, 047
Build: Run adversarial reward and persistence stress tests. Security: Include replay, forged grant IDs, and stale owners. Test: Thousands of repeated grants and injected failures. Done: No duplicate committed rewards or unaccounted mutations in the test suite.

BM-049 · P0 · D: 028, 046, 047
Build: Implement restricted operator recovery workflow. Security: Role-controlled, logged, idempotent corrections. Test: Unauthorized recovery and repeated operator actions. Done: Support can recover a stuck grant without arbitrary profile edits.

BM-050 · P0 · D: 032, 045, 046, 047, 048, 049
Build: Reward-integrity milestone gate. Security: Verify durable receipts, fencing, bounded storage, and reconciliation. Test: Full reward and persistence acceptance suite. Done: Permanent progression and reward-bearing gameplay cannot ship without approval.

### Phase C — Combat, Cants, Verses, and Burdens

BM-051 through BM-072 | Combat acceptance prerequisite: BM-072

BM-051 · P0 · D: 020, 021
Build: Implement server-owned character lifecycle, movement state, and gameplay position sampling. Security: Never trust client-supplied positions for interaction authorization. Test: Respawn, teleport, and movement-state transitions. Done: Server maintains valid character state.

BM-052 · P0 · D: 051
Build: Define typed combat attributes and derived statistics. Security: Client cannot assign attribute values. Test: Stat caps and invalid modifiers. Done: Derived values are deterministic.

BM-053 · P0 · D: 052
Build: Implement stamina, posture, regeneration, and resource consumption. Security: Server checks costs before actions. Test: Exhaustion, regeneration, and simultaneous spending. Done: Resources cannot become negative or exceed caps.

BM-054 · P0 · D: 007, 020, 051, 053
Build: Implement fixed-step authoritative combat simulation and action state machine. Security: Reject impossible transitions and manipulated timing. Test: Deterministic combat sequences. Done: Server resolves all gameplay outcomes.

BM-055 · P0 · D: 054
Build: Implement server hitboxes, hit windows, collision filtering, and target eligibility. Security: Client hit claims are not authoritative. Test: Range spoofing, duplicate hits, and obstructed attacks. Done: Invalid hits deal no damage.

BM-056 · P0 · D: 054, 055
Build: Implement damage, defenses, invulnerability windows, and death conditions. Security: Clamp damage and enforce server-owned health. Test: Damage boundaries and repeated-hit exploits. Done: Damage resolves consistently.

BM-057 · P0 · D: 053, 056
Build: Implement dodge, guard, parry, recovery, and action interruption. Security: Server validates timing and resource availability. Test: Perfect-window boundaries and animation desynchronization. Done: Defensive outcomes are server-determined.

BM-058 · P0 · D: 054, 056
Build: Implement enemy AI states, aggro, navigation, and attack scheduling. Security: AI and loot ownership remain server-side. Test: Target loss, path failure, and AI reset. Done: Enemies operate without client control.

BM-059 · P0 · D: 054, 058
Build: Implement target acquisition, target switching, and combat engagement rules. Security: Validate range and line of sight server-side. Test: Invalid targets and distant targeting. Done: Target state remains authoritative.

BM-060 · P0 · D: 054, 059
Build: Implement combat state replication, prediction correction, and visual event cues. Security: Replicate only necessary public state. Test: Packet delay and state correction. Done: Clients display consistent combat outcomes.

BM-061 · P0 · D: 020, 054, 055, 057
Build: Implement secure `CombatInput` adapter for attacks, dodges, blocks, and parries. Security: Validate action enum, cadence, resources, state, and server hit windows. Test: Input spam, forged targets, and stale sequences. Done: No combat input bypasses the dispatcher.

BM-062 · P0 · D: 004, 022
Build: Define the full canonical Cant registry, unlock rules, slots, and compatible Verse references. Security: Reject unknown or fabricated Cant IDs. Test: Catalog integrity and invalid references. Done: Every established Cant has a typed definition.

BM-063 · P0 · D: 054, 062
Build: Implement Nearness as the first playable Cant using its established mechanics. Security: All mechanical effects are server-resolved. Test: Activation, cooldown, resource, and combat-state cases. Done: Nearness functions throughout the vertical slice.

BM-064 · P0 · D: 020, 062, 063
Build: Implement `CantEquip` adapter and server-owned equipment state. Security: Verify ownership, legal slots, and restrictions. Test: Forged Cant, duplicate equip, and invalid slot. Done: Only eligible Cants can be equipped.

BM-065 · P0 · D: 004, 062
Build: Define typed Verse catalog, Cant compatibility, resource costs, and unlock prerequisites. Security: Reject undefined or incompatible Verses. Test: Missing references and invalid cost data. Done: Every canonical Verse definition validates.

BM-066 · P0 · D: 063, 065
Build: Implement the canonical Nearness Verses required by the vertical slice. Security: Effects and targets remain server-owned. Test: Cast timing, cooldown, and damage/resource outcomes. Done: Slice Verses are playable and balanced to initial targets.

BM-067 · P0 · D: 020, 054, 065, 066
Build: Implement `VerseCast` adapter and execution pipeline. Security: Verify unlock, equipped Cant, target, cooldown, and resources. Test: Cast spam, forged targets, and incompatible Cant. Done: Invalid casts produce no effects.

BM-068 · P0 · D: 052, 054, 067
Build: Implement Dissonance accumulation, thresholds, and canonical Dissonance actions. Security: `DissonanceAction` uses a validated adapter; clients cannot set meter values. Test: Threshold crossings and repeated actions. Done: Dissonance transitions remain deterministic.

BM-069 · P0 · D: 004, 062
Build: Define Burden registry, acquisition conditions, compatibility, and gameplay modifiers. Security: Only canonical Burden IDs and effect definitions are accepted. Test: Invalid combinations and modifier bounds. Done: All established Burdens are represented.

BM-070 · P0 · D: 020, 069
Build: Implement `BurdenChoice` adapter with server-issued offers. Security: Validate offered choices, expiry, eligibility, and duplicate selection. Test: Forged and replayed offers. Done: Each offer resolves at most once.

BM-071 · P0 · D: 053, 069, 070
Build: Implement Burden effect application, stacking, removal rules, and interactions with combat resources. Security: Clamp modifiers and prevent illegal stacking. Test: Conflicting Burdens and reconnects. Done: Burden state produces consistent server-authoritative effects.

BM-072 · P0 · D: 057, 058, 063, 066, 068, 071
Build: Create combat balance and interaction test harness. Security: Include exploit-resistant timing and resource cases. Test: Nearness, Verses, Burdens, Dissonance, enemy encounters, and defensive mechanics. Done: Vertical-slice combat meets documented functional and balance acceptance thresholds.

### Phase D — Quests, Waymarks, world, travel, and first Descent

BM-073 through BM-096 | Waymark gate: BM-078 | Vertical-slice gate: BM-096

BM-073 · P0 · D: 021, 022, 050
Build: Implement typed quest graph engine, prerequisites, objectives, branching, and completion transitions. Security: Only server-certified events advance quests. Test: Invalid graph edges, cycles where prohibited, and repeated completion. Done: Quest progression is deterministic and persistable.

BM-074 · P0 · D: 020, 073
Build: Implement `QuestChoice` adapter with offer IDs and revision checks. Security: Validate current node, eligibility, choice membership, expiry, and replay. Test: Forged, stale, repeated, and out-of-order choices. Done: No unauthorized quest branch transition is possible.

BM-075 · P0 · D: 050, 063, 066, 073, 074
Build: Implement Waymark I's established progression requirements, unlock sequence, and permanent rewards. Security: Server-only prerequisites and durable one-time receipts. Test: Normal progression, skipped objectives, duplicate rewards, and reconnect. Done: Waymark I cannot unlock early or reward twice.

BM-076 · P0 · D: 020, 075
Build: Implement `WaymarkActivate` adapter and activation state. Security: Verify proximity, canonical Waymark ID, prerequisites, and lease. Test: Remote activation, replay, and locked Waymark attempts. Done: Only eligible Waymarks activate.

BM-077 · P0 · D: 023, 032, 075, 076
Build: Implement Waymark save/load, recovery, and migration tests. Security: Preserve irreversible unlocks and receipts. Test: Crash and reconnect at each Waymark I transition. Done: Waymark I state survives all tested failures.

BM-078 · P0 · D: 050, 075, 076, 077
Build: Waymark I progression milestone gate. Security: Audit quest, reward, and activation authority. Test: Full Waymark I progression and persistence suite. Done: Later progression cannot be enabled until the gate passes.

BM-079 · P0 · D: 020, 051, 078
Build: Implement death, checkpoint respawn, and supported ally revive flow. Security: Validate checkpoint, ally distance, revive eligibility, and cooldowns. Test: Forged revive, repeated respawn, and checkpoint abuse. Done: Death/recovery respects Waymark progression.

BM-080 · P0 · D: 020, 033
Build: Implement `InventoryEquip` adapter, equipment slots, and stat application. Security: Verify ownership, item instance, slot compatibility, and revision. Test: Duplicate equipment and forged item IDs. Done: Inventory equipment cannot be spoofed.

BM-081 · P0 · D: 033, 034, 050
Build: Implement first-slice item rewards, inventory capacity behavior, and server economy interfaces. Security: All items originate from approved reward sources. Test: Full inventory, duplicate grant, and invalid stack. Done: Slice rewards remain consistent across saves.

BM-082 · P0 · D: 006, 051
Build: Implement region streaming boundaries, spawn management, and world-loading transitions. Security: Streaming state does not determine server authorization. Test: Late-loaded objects and missing streamed geometry. Done: Gameplay remains functional under partial client streaming.

BM-083 · P0 · D: 004, 022, 082
Build: Create canonical Orthea region registry with entrances, Waymarks, quests, encounters, and travel links. Security: Server validates region IDs and unlocks. Test: Referential integrity and disconnected routes. Done: All intended launch regions have registry records.

BM-084 · P0 · D: 078, 082, 083
Build: Implement the established first playable region with traversal, encounters, Waymark I placement, and environmental interactions. Security: Server validates interactions and region progression. Test: Complete region traversal on desktop and mobile. Done: Region is playable from entry to exit.

BM-085 · P0 · D: 073, 074, 084
Build: Implement the first campaign chapter's canonical quests, objectives, and branches. Security: Quest events originate from trusted services. Test: Every intended branch and objective order. Done: First chapter can be completed without skipped progression.

BM-086 · P0 · D: 020, 073, 085
Build: Implement NPC dialogue, interaction offers, and `NPCInteract` adapter. Security: Verify NPC existence, range, quest state, and offer validity. Test: Remote NPC interaction and stale dialogue. Done: Dialogue advances only through legal interactions.

BM-087 · P0 · D: 073, 085
Build: Implement quest journal UI state replication and objective indicators. Security: Send only discovered and authorized quest information. Test: Hidden-branch disclosure and stale state. Done: UI reflects authoritative quest progress.

BM-088 · P0 · D: 020, 035, 050, 084
Build: Implement first-region lore collectibles and `CollectibleClaim` adapter. Security: Verify registered collectible, proximity, and durable claim receipt. Test: Duplicate and distant claims. Done: Collectibles cannot be farmed unintentionally.

BM-089 · P0 · D: 022, 083, 084
Build: Implement travel-route catalog, unlock conditions, and destination eligibility. Security: Server controls available routes. Test: Locked destinations and invalid route references. Done: Only registered unlocked routes are available.

BM-090 · P0 · D: 020, 089
Build: Implement `TravelReady` adapter and revisioned readiness state. Security: Validate ticket, party membership, expiry, and current roster revision. Test: Forged ticket, stale roster, duplicate readiness, and party removal. Done: Readiness cannot initiate unauthorized travel.

BM-091 · P0 · D: 020, 089, 090
Build: Implement `TravelPropose`, party travel votes, and final travel authorization. Security: Verify leader authority, party roster, destination unlock, and current state. Test: Leadership change and concurrent proposals. Done: One valid proposal produces at most one authorized travel transition.

BM-092 · P0 · D: 027, 089, 091
Build: Implement server-controlled teleport initiation and arrival recovery. Security: Revalidate roster and destination; never trust client teleport parameters. Test: Partial party failure, disconnect, and handoff. Done: Travel failures recover without corrupting player state.

BM-093 · P0 · D: 020, 078, 089
Build: Implement first Descent entrance, eligibility, and `DescentEnter` adapter. Security: Verify unlock, entry location, party state, and unique run assignment. Test: Unauthorized and repeated entry. Done: Only eligible players enter the first Descent.

BM-094 · P0 · D: 050, 058, 093
Build: Implement first Descent encounter flow, enemy waves, objectives, and server-certified completion. Security: Clients cannot assert encounter completion or rewards. Test: Failed, abandoned, and successful runs. Done: Run state transitions are deterministic.

BM-095 · P0 · D: 054, 072, 094
Build: Implement the first canonical boss, telegraphs, phases, defeat conditions, and rewards. Security: Boss state and reward eligibility remain server-owned. Test: Phase skipping, damage exploits, and party defeat. Done: Boss is fully playable and cannot be completed through client claims.

BM-096 · P0 · D: 020, 050, 061, 072, 078, 079–081, 084–088, 090–095
Build: Full vertical-slice milestone gate covering Nearness, first region, chapter, Waymark I, travel, first Descent, and boss. Security: Run networking, reward, and progression audits. Test: Complete solo and multiplayer playthroughs, reconnects, and exploit cases. Done: Slice is playable end-to-end with no critical progression, security, or persistence defects.

### Phase E — Full campaign, canonical content, and multiplayer

BM-097 through BM-120 | Full campaign gate: BM-120

BM-097 · P1 · D: 083, 096
Build: Implement every remaining launch region defined in the Orthea registry, with terrain, landmarks, encounters, and Waymarks. Security: Server-owned access conditions. Test: Per-region traversal and content completeness. Done: Every launch-required region passes its individual content acceptance task.

BM-098 · P1 · D: 051, 097
Build: Implement region-specific traversal, hazards, and environmental mechanics. Security: Hazard damage and progression checks are server-owned. Test: Movement exploits and hazard boundary cases. Done: All registered region mechanics function consistently.

BM-099 · P1 · D: 073, 074, 097, 098
Build: Implement every remaining launch quest, objective, and canonical branch. Security: No client-authored quest completion. Test: Every quest path, failure condition, and reward receipt. Done: All launch-required quest IDs have passing completion tests.

BM-100 · P1 · D: 075, 078, 099
Build: Implement chapter ordering, prerequisite gates, and campaign completion conditions. Security: Reject chapter skipping and forged progression. Test: Early unlock, alternate branch, and replay scenarios. Done: Campaign order follows established canon.

BM-101 · P1 · D: 086, 099, 100
Build: Implement later NPC dialogue, consequential choices, and branch-specific presentation. Security: Quest consequences are server-committed. Test: Branch persistence and contradictory-choice prevention. Done: All canonical narrative choices resolve correctly.

BM-102 · P1 · D: 062, 064, 072, 096
Build: Implement every remaining launch Cant with its established mechanics and unlock conditions. Security: Server-controlled Cant effects and ownership. Test: Each Cant's action, unlock, cooldown, and invalid-use cases. Done: All launch Cant registry entries are playable and tested.

BM-103 · P1 · D: 065, 067, 102
Build: Implement every remaining launch Verse and its Cant compatibility. Security: Validate targets, resource costs, and effects server-side. Test: Per-Verse functional and exploit tests. Done: Every launch Verse has a passing test fixture.

BM-104 · P1 · D: 069, 070, 071, 102
Build: Implement every remaining launch Burden, including acquisition and consequences. Security: Server controls modifier stacking and persistence. Test: Each Burden alone and in supported combinations. Done: All launch Burdens behave as specified.

BM-105 · P1 · D: 068, 071, 102, 103, 104
Build: Implement and balance Cant, Verse, Burden, and Dissonance interactions. Security: Reject invalid effect combinations and resource amplification. Test: Pairwise coverage plus high-risk combination tests. Done: No known infinite-resource or uncontrolled-damage combinations.

BM-106 · P1 · D: 063, 064, 096
Build: Implement data-driven starting-Cant eligibility and `StarterCantSelect` policy. Security: Server-issued choices; one-time or replay-cycle rules enforced. Test: Forged starter and repeated selection. Done: Nearness works by default without hardcoded exclusivity.

BM-107 · P1 · D: 106, 102, 103
Build: Implement alternate-starter onboarding support and rollout flag for existing canonical Cants. Security: Reject unapproved starter IDs and progression shortcuts. Test: Alternate starter tutorial, first Verse, Burden, and Waymark I compatibility. Done: Feature can be enabled only for starters that pass all required tests; otherwise it remains safely disabled.

BM-108 · P1 · D: 033, 034, 050, 081, 096
Build: Implement complete launch equipment, materials, item progression, and approved crafting recipes. Security: Enforce inventory bounds and catalog rules. Test: Every item and recipe definition. Done: All launch equipment progression paths work.

BM-109 · P1 · D: 020, 050, 108
Build: Implement `CraftRequest` adapter and atomic crafting transactions. Security: Verify recipe, ingredients, capacity, and receipt/revision; prevent double spend. Test: Concurrent crafting and insufficient materials. Done: Each valid request produces exactly its approved inventory transition.

BM-110 · P1 · D: 020, 050, 108
Build: Implement vendors, prices, stock rules, and `VendorPurchase` adapter. Security: Server validates vendor access, balances, and stock. Test: Price spoofing, duplicate purchase, and full inventory. Done: Purchases cannot create items or currency illegitimately.

BM-111 · P1 · D: 078, 100, 102
Build: Implement all later canonical Waymarks and their progression dependencies. Security: Durable one-time receipts and server-only unlocks. Test: Each Waymark's prerequisites, replay, and save/load. Done: All launch Waymarks pass their individual progression tests.

BM-112 · P1 · D: 072, 097, 100, 105
Build: Implement all remaining midgame bosses and encounter-specific mechanics. Security: Server validates phases, defeat, and rewards. Test: Every boss phase and exploit case. Done: All registered midgame bosses are playable.

BM-113 · P1 · D: 112, 111
Build: Implement final campaign bosses and their established narrative/progression consequences. Security: Completion requires server-certified encounter results. Test: Phase skipping, wipes, and reward persistence. Done: Canonical campaign boss progression is complete.

BM-114 · P1 · D: 094, 097, 105
Build: Implement the remaining launch Descents, encounter layouts, objectives, and completion rules. Security: Server owns run seeds, encounter state, and completion. Test: Every Descent success/failure path. Done: All launch Descent definitions have passing tests.

BM-115 · P1 · D: 020, 093, 114
Build: Implement `DescentQueue` and `DescentCancel` adapters, tier eligibility, and queue lifecycle. Security: Validate party membership, unlocks, and duplicate queue attempts. Test: Queue spam, disconnect, and concurrent entry. Done: Players cannot enter unauthorized runs.

BM-116 · P1 · D: 020, 091
Build: Implement secure party invite, accept, leave, and kick adapters. Security: Verify leadership, membership, invite expiry, and size caps. Test: Forged invite, race conditions, and stale party state. Done: Party membership remains server-authoritative.

BM-117 · P1 · D: 116
Build: Implement authoritative party roster, leadership transfer, and party lifecycle. Security: Prevent multiple leaders and inconsistent membership. Test: Leader disconnect, simultaneous join/leave, and dissolution. Done: Party invariants hold under concurrency.

BM-118 · P1 · D: 054, 072, 117
Build: Implement multiplayer enemy scaling, combat participation, and revive balancing. Security: Rewards derive from server-observed eligibility, not client claims. Test: Solo versus party balance and contribution abuse. Done: Supported party sizes complete encounters consistently.

BM-119 · P1 · D: 027, 092, 114, 115, 117, 118
Build: Implement party matchmaking, reserved-instance travel, Descent instance ownership, and recovery. Security: Server controls instance admission and party/run binding. Test: Split party, failed teleport, and reconnect. Done: Multiplayer runs preserve valid party and progression state.

BM-120 · P1 · D: 096, 097–119
Build: Full campaign and launch-content milestone gate. Security: Audit all content adapters, reward sources, and progression prerequisites. Test: Automated registry coverage, complete campaign playthroughs, and multiplayer regression. Done: Every launch-required region, quest, Cant, Verse, Burden, Waymark, boss, and Descent has a passing implementation record.

### Phase F — Endgame, repeatable systems, and player experience

BM-121 through BM-130 | Endgame gate: BM-130

BM-121 · P1 · D: 050, 111, 120
Build: Implement canonical endgame unlocks and post-campaign progression. Security: Verify campaign and Waymark prerequisites server-side. Test: Premature endgame access and legitimate unlocks. Done: Endgame opens only through intended progression.

BM-122 · P1 · D: 114, 119, 121
Build: Implement repeatable Descent tiers, difficulty scaling, and run reset rules. Security: Run eligibility and tier state are server-owned. Test: Tier skipping, abandoned runs, and repeated clears. Done: All launch endgame tiers function correctly.

BM-123 · P1 · D: 050, 046, 122
Build: Implement endgame reward tables, tier eligibility, and repeatable grant reconciliation. Security: Stable run receipts and seasonal limits required. Test: Duplicate completion, disconnect, and repeated reward recovery. Done: Endgame rewards are bounded and idempotent.

BM-124 · P1 · D: 097, 100, 120
Build: Implement established post-campaign world events and regional state changes. Security: Event activation and completion are server-owned. Test: Concurrent participation and event reset. Done: Every launch world event has a verified lifecycle.

BM-125 · P1 · D: 050, 121, 123
Build: Implement approved recurring endgame objectives and reward cycles. Security: Server-defined reset periods, durable claims, and eligibility. Test: Time-boundary replay and duplicate claims. Done: Recurring objectives cannot be repeatedly claimed within one cycle.

BM-126 · P1 · D: 020, 050, 123
Build: Implement eligible endgame records and leaderboards where required by the established design. Security: Scores originate from certified server results. Test: Forged score, duplicate submission, and invalid runs. Done: Only valid results appear in rankings.

BM-127 · P1 · D: 008, 050, 120
Build: Implement launch analytics for progression funnels, Cant usage, Burden combinations, Descent outcomes, and economy health. Security: Minimize collected player data and restrict telemetry writes. Test: Event accuracy and privacy checks. Done: Critical game-health metrics are measurable.

BM-128 · P1 · D: 020, 073, 120
Build: Implement final quest journal, map, Waymark, party, inventory, and settings UI. Security: `SettingsUpdate` accepts only whitelisted bounded preferences; hidden progression is not replicated. Test: UI state consistency and invalid settings. Done: Every launch system has usable interface coverage.

BM-129 · P1 · D: 051, 060, 128
Build: Implement mobile/controller support, accessibility options, readable combat cues, and input remapping. Security: Alternate input methods use the same validated adapters. Test: Supported device classes and accessibility cases. Done: All core actions are usable without mouse/keyboard assumptions.

BM-130 · P1 · D: 120, 121–129
Build: Endgame and player-experience milestone gate. Security: Audit repeatable rewards, unlocks, leaderboards, and all remaining adapters. Test: Full endgame cycle, device coverage, and multiplayer regression. Done: All launch endgame features meet acceptance criteria.

### Phase G — Performance, security review, and launch

BM-131 through BM-136 | Final launch gate: BM-136

BM-131 · P1 · D: 060, 082, 119, 130
Build: Profile server frame time, memory, streaming, AI cost, and replication bandwidth; implement interest management and optimization. Security: Optimization must not move authority to clients. Test: Worst-case region, combat, and party load. Done: Measured budgets pass on target devices and server sizes.

BM-132 · P0 · D: 020, 050, 090, 109, 110, 115, 116, 130
Build: Conduct full adversarial security review across remotes, combat, quests, travel, crafting, parties, rewards, and progression. Security: Fuzz all adapters and test replay, authorization, and race attacks. Test: Documented exploit regression suite. Done: No unresolved critical or high-severity exploit findings.

BM-133 · P1 · D: 025, 026, 030, 119, 131
Build: Run persistence, multiplayer, and performance soak tests with simulated disconnects and outages. Security: Verify lease fencing and recovery under load. Test: Sustained sessions and injected DataStore failures. Done: No unreconciled critical data-loss or duplication failures.

BM-134 · P1 · D: 096, 120, 130, 132, 133
Build: Perform full release regression, content coverage audit, device QA, and progression certification. Security: Re-run exploit and persistence suites. Test: Complete launch test matrix. Done: All P0/P1 acceptance tests pass and release blockers are closed.

BM-135 · P1 · D: 008, 028, 049, 127, 134
Build: Implement deployment controls, feature rollback, incident response, player recovery procedures, and monitoring alerts. Security: Restricted release and recovery permissions. Test: Simulated bad rollout and data incident. Done: Operators can disable unsafe features and recover without destructive data changes.

BM-136 · P0 · D: 020, 050, 078, 096, 120, 130, 131–135
Build: Final launch readiness gate. Security: Require signed-off networking, reward, progression, exploit, and persistence reviews. Test: Full CI, content inventory, soak, regression, and launch checklist. Done: No open release blockers; deployment and rollback procedures verified.

## 8. Mandatory content coverage enforcement

The 136 parent tasks establish engineering ownership. However, a parent task such as BM-102, which covers the complete Cant roster, is not sufficient evidence that every Cant has actually been implemented.

The correction is to require individual, registry-generated content subtasks for every launch-required canonical entry.

These are child acceptance tasks under the 136-task baseline. Their final count depends on the established content inventory and must not be guessed.

### 8.1 Required content manifest

Every canonical content entry must declare:

```
export type ContentManifestEntry = {
    id: string,
    category: string,
    launchRequired: boolean,
    implementationTaskId: string,
    prerequisiteIds: {string},
    validationSuiteId: string,
    testFixtureId: string,
}
```

The build must reject duplicate IDs, missing references, absent test fixtures, and launch-required content without implementation ownership.

### 8.2 Required individual content tasks

In the table below, `<id>` means the actual canonical ID from the existing Black Meridian design, not a new invented name.

| Child task          | Priority and dependencies | Scope, security, tests, and done                                                                                                                                                              |
| ------------------- | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BM-097/R:<id>`     | P1; 083, 096              | Build one region with traversal, encounters, landmarks, and connections. Security: server-validated access. Test: full traversal and region objectives. Done: region acceptance suite passes. |
| `BM-099/Q:<id>`     | P1; 073, 074, 097, 098    | Build one complete quest graph. Security: authorized transitions and receipts. Test: all branches, failure states, and rewards. Done: every reachable path verified.                          |
| `BM-102/C:<id>`     | P1; 062, 064, 072, 096    | Build one canonical Cant. Security: server-owned effects and unlocks. Test: actions, cooldowns, invalid usage, persistence. Done: Cant playable and verified.                                 |
| `BM-103/V:<id>`     | P1; 065, 067, 102         | Build one Verse. Security: validated compatibility, resources, and targets. Test: casts, cooldowns, exploits. Done: Verse passes functional and security tests.                               |
| `BM-104/B:<id>`     | P1; 069, 070, 071, 102    | Build one Burden. Security: controlled acquisition and modifiers. Test: stacking, persistence, interactions. Done: all specified effects verified.                                            |
| `BM-111/W:<id>`     | P1; 078, 100, 102         | Build one later Waymark. Security: authoritative prerequisites and permanent receipts. Test: unlock, replay, reconnect. Done: Waymark progression certified.                                  |
| `BM-112/BOSS:<id>`  | P1; 072, 097, 100, 105    | Build one midgame boss. Security: authoritative phases and defeat. Test: complete encounter and exploit cases. Done: boss passes encounter certification.                                     |
| `BM-113/BOSS:<id>`  | P1; 111, 112              | Build one final campaign boss. Security: authoritative completion and rewards. Test: phase progression and campaign consequences. Done: boss and associated progression certified.            |
| `BM-114/D:<id>`     | P1; 094, 097, 105         | Build one Descent. Security: server-owned run state and completion. Test: entry, objectives, failure, rewards. Done: Descent fully playable.                                                  |
| `BM-121/E:<id>`     | P1; 050, 111, 120         | Build one endgame unlock. Security: validated prerequisites. Test: premature and legitimate access. Done: unlock conditions verified.                                                         |
| `BM-122/T:<id>`     | P1; 114, 119, 121         | Build one repeatable Descent tier. Security: validated tier and run eligibility. Test: completion, reset, rewards. Done: tier passes endgame tests.                                           |
| `BM-124/EVENT:<id>` | P1; 097, 100, 120         | Build one established world event. Security: server-owned lifecycle. Test: activation, participation, completion, reset. Done: event lifecycle certified.                                     |

First-slice content receives the same individual acceptance treatment under BM-063, BM-066, BM-075, BM-084, BM-085, BM-094, and BM-095.

The same rule applies to any established launch system not explicitly enumerated above. No canonical feature may be silently dropped because it was consolidated into a broader parent task.

### 8.3 Automated content coverage rule

BM-120 must enforce:

```
For every launchRequired content entry:

1. Canonical ID exists.
2. Implementation owner exists.
3. Dependencies are satisfied.
4. Secure service/adapter exists where applicable.
5. Automated test fixture exists.
6. Acceptance tests pass.
7. Required assets and references resolve.
8. Content is reachable through valid progression.
9. Rewards use approved receipt mechanisms.
10. Content is enabled in the approved launch configuration.

Otherwise: FAIL CONTENT GATE.
```

The same principle applies to BM-130 for endgame content.

This prevents a situation where the full campaign is marked complete despite missing quests, regions, Verses, Burdens, or Descents.

## 9. Final dependency audit

Static audit of the proposed 136-task parent graph, with shorthand dependency ranges expanded: 136 numbered tasks, 0 missing task IDs, 0 invalid or forward dependencies, 0 orphaned tasks. This does not certify compatibility with the unseen original backlog or completeness of the canonical content inventory.

The graph contains no dependency cycles because every parent-task dependency points to an earlier numbered task. BM-136 is the only terminal task: all other parent tasks have a downstream path to launch readiness.

### 9.1 Corrected milestone gates

| Gate   | Name              | Includes                                             |
| ------ | ----------------- | ---------------------------------------------------- |
| BM-020 | Secure networking | BM-016 replay protection                             |
| BM-050 | Reward integrity  | BM-046 reconciliation                                |
| BM-078 | Waymark I         | BM-075 progression                                   |
| BM-096 | Vertical slice    | Nearness, first region, quest, Descent, boss         |
| BM-120 | Full campaign     | All launch-required canonical content                |
| BM-130 | Endgame           | Repeatable systems, rewards, multiplayer, UI         |
| BM-136 | Launch approval   | Security, performance, QA, recovery, release         |

Combat, persistence, world infrastructure, and other work can proceed in parallel where their individual dependencies permit.

### 9.2 Previously missing dependencies

| Critical task                | Corrected direct downstream tasks      | Result                                                                                   |
| ---------------------------- | -------------------------------------- | ---------------------------------------------------------------------------------------- |
| BM-016 Replay protection     | BM-017, BM-018                         | Secure dispatcher and networking gate cannot complete without replay protection          |
| BM-046 Reward reconciliation | BM-047, BM-048, BM-049, BM-050, BM-123 | Reward-bearing progression and endgame are blocked until reconciliation passes           |
| BM-075 Waymark I progression | BM-076, BM-077, BM-078, BM-100         | Waymark activation, persistence, later progression, and campaign sequencing depend on it |

All three also have verified downstream paths to BM-136.

### 9.3 Additional enforcement rules

- A task cannot be marked complete while any hard dependency is incomplete.
- A task cannot be marked complete with failing security tests.
- A milestone gate requires recorded evidence from every prerequisite.
- New client requests cannot be added without validators and abuse tests.
- New permanent rewards cannot be added without stable receipt definitions.
- New quests cannot be added without graph validation and branch tests.
- New Cants, Verses, and Burdens cannot be added without compatibility and exploit tests.
- Launch-required content cannot be marked complete through a parent task alone.

Important: The parent graph passes its static audit. The dynamically generated content children still require a populated canonical manifest and a separate automated audit before the full game can be declared dependency-complete.

## 10. Final technical acceptance requirements

### 10.1 Networking and security

Before BM-020 can pass, every registered request must be tested against malformed types, oversized payloads, stale session epochs, duplicate IDs, replayed sequences, rate-limit violations, unauthorized ownership, and illegal state transitions.

For `QuestChoice`, test concurrent choices from the same offer and crash recovery after a permanent consequence.

For `TravelReady`, test party membership changes during readiness, leader disconnects, ticket expiry, stale roster revisions, and teleport cancellation.

### 10.2 Persistence and reward safety

Before BM-050 can pass, the test suite must demonstrate:

- Stale lease owners cannot write.
- Simultaneous servers cannot both acquire valid ownership.
- Repeated permanent grants do not duplicate.
- A lost write response does not cause a second grant.
- Pending reward intents recover correctly after restart.
- Profile size overflow does not delete existing state.
- Permanent receipts survive migrations.
- Corrupt profiles are not overwritten with empty defaults.

### 10.3 Performance acceptance targets

The following are initial engineering targets, not claims about measured Black Meridian performance.

| Area                     | Initial target                                                   |
| ------------------------ | ---------------------------------------------------------------- |
| Desktop client           | Aim for 60 FPS in representative gameplay                        |
| Supported mobile devices | Maintain a playable 30 FPS baseline                              |
| Server simulation        | Keep critical simulation within the selected server frame budget |
| Enemy AI                 | Use lower-frequency updates outside active combat                |
| Combat replication       | Replicate meaningful state changes, not every animation frame    |
| World streaming          | Load regional content according to player interest               |
| VFX                      | Pool frequently spawned effects and cap simultaneous instances   |
| Persistence              | No per-frame DataStore writes; bounded queues and coalescing     |
| Network                  | Enforce action-specific rate and payload budgets                 |
| Load testing             | Measure worst-case party encounters and populated regions        |

Final numerical budgets for memory, bandwidth, and server frame time must be established from actual Roblox profiling during BM-131, not invented before measurement.

## 11. Open reconciliation items

Two reconciliation steps remain before treating the entire backlog as authoritative: map the proposed IDs against the original 96-task register, and populate the content manifest with every established canonical launch item. Neither requires redesigning Orthea or restarting the research.

Until the canonical content inventory is supplied, tasks that need real content IDs (BM-004 onward) implement the schema, validation, and the known first-slice items only, and record the missing inventory as a blocker in `docs/task-log.md`.
