# Message delivery architecture goal

Status: implemented; acceptance evidence is recorded in [the backlog](MESSAGE_DELIVERY_TASKS.md).

Implementation backlog: [Message delivery tasks](MESSAGE_DELIVERY_TASKS.md).

Frozen implementation contract: [Wire frames, limits, and storage](MESSAGE_DELIVERY_CONTRACT.md).

Implement this architecture across the backend and mocked clients. There is no production protocol
compatibility requirement. Read `AGENTS.md` and the affected implementation before editing.
`MESSAGE_DELIVERY.md` describes the implemented receipt-or-commit lifecycle.

## Ownership and results

Delivery is at least once, with durable client deduplication. Until `ok`, the sender owns recovery
through its durable outbox. After `ok`, either the receiver has saved the message locally or
PostgreSQL has committed a pending message.

| Result | Meaning |
| --- | --- |
| `ok` | An authenticated receiver confirmed durable receipt, or PostgreSQL committed the message. |
| `failed` | This attempt could not confirm either outcome; the sender may retry. |
| No response | Outcome is unknown; the sender retries after timeout. |

`ok` does not imply that an offline message has reached the receiver or been read. `failed` does
not prove that no copy reached the receiver. Timeouts, disconnects, and node failures can leave
the outcome unknown.

## Scope and fixed decisions

- Support one active connection per authenticated user. Correct delivery across multiple simultaneous
  client connections is outside this implementation's scope.
- Use direct Erlang messaging between TCP nodes in a BEAM cluster.
- Redis stores presence and routing information only, never message payloads or delivery ownership.
- PostgreSQL stores pending offline and unconfirmed messages, not permanent conversation history.
- Assign message timestamps in the backend when handling the message. Timestamps are metadata,
  not identity or a strict ordering guarantee. Preserve the existing timestamp on idempotent stored
  retries. After row deletion, a retry may acquire a new timestamp.
- Update `chatchat_client` as a backend test tool. Implement durability and retry behavior there;
  do not build client-side ordering, history synchronization, or a real chat UI.
- Do not promise strict ordering. Live messages and stored messages may overlap or arrive together.

## Identity and protocol

The sender creates a stable `message_id` before sending. The message identity is
`(authenticated_sender_id, message_id)`. Derive sender identity from the authenticated connection,
never from a client-supplied identity field.

A message identity binds an immutable receiver and payload. A repeated PostgreSQL insert is
idempotent while its row exists only if these fields match. Reject conflicting reuse; do not
silently accept a different payload or receiver through `on_conflict: :nothing`.

Receipt ACKs must be scoped to the authenticated receiver and exact message identity. Direct
attempts also need bounded correlation tracking so late ACKs cannot complete unrelated attempts.
Include enough identity in wire messages and ACKs to distinguish equal IDs from different senders.
Preserve input validation, frame limits, authorization, and socket timeouts.

## Mocked client contract

Before sending, atomically commit the message to a durable local outbox. Retain it until `ok`.
On `failed`, timeout, or connection loss, retry with the same identity, receiver, and payload,
using bounded backoff. Retry frequency is capped; attempts are not silently discarded after a
fixed count. Process restart must recover pending outbox entries.

The receiver atomically saves the incoming message and its deduplication identity locally before
ACKing. Deduplicate by sender identity and message ID. ACK duplicates too. Deduplication must
survive reconnects and process restart. Keep deduplication records indefinitely for this baseline;
expiration would require a separately defined maximum retry lifetime.

Use the simplest durable local storage fitting the existing client tool. Keep storage bounded in
memory even when the durable dataset grows. Test isolation must prevent different simulated users
or test runs from sharing client state accidentally.

## Online delivery

1. The sender's TCP node validates the request and obtains the authenticated sender identity.
2. It resolves the receiver's node and session through Redis presence.
3. It forwards the message directly to the receiver's node, or uses the local path on the same node.
4. The receiver's node resolves the authenticated local connection and sends the message.
5. The receiver commits the message locally and returns a receipt ACK.
6. Confirmation returns to the sender's node, which replies `ok`.

Successful direct delivery requires no PostgreSQL message write and no Redis payload write.
Nodes retain only bounded, temporary in-flight state. A node crash leaves recovery with the
sender's outbox until `ok`. Cross-node delivery must be asynchronous; do not block socket handlers
on remote calls or receipt waits.

## Offline fallback and races

If the receiver has no connection, insert the pending message directly into PostgreSQL. Reply
`ok` only after commit. A stale route, unavailable node, or missing receipt ACK triggers a short,
bounded direct attempt/retry window followed by PostgreSQL fallback. If neither receipt nor
storage can be confirmed, reply `failed` when the sender connection remains available.

Choose a finite direct-delivery deadline during implementation; roughly two seconds is a starting
point, not a guarantee. Keep retries bounded within that window.

A receipt ACK can race with fallback insertion. Either confirmed outcome permits `ok`. If a row
also commits, retain it for normal inbox delivery and authenticated ACK cleanup; receiver
deduplication handles the extra copy. A database commit followed by a sender-node crash must also
be safe when the sender retries.

Pending rows contain message identity, sender, receiver, payload, and backend insertion timestamp.
Use a database uniqueness constraint on the composite message identity and receiver-specific
indexes for bounded inbox reads. Retries after deletion can recreate a row; persistent receiver
deduplication handles this. Do not expire undelivered rows silently.

## Reconnect and inbox recovery

Register the authenticated receiver connection before reading its PostgreSQL inbox. A bounded
worker sends pending messages and deletes rows only after authenticated receiver ACK. Deletes
may be batched, but must remain receiver-scoped and safe under duplicate or late ACKs.

After every offline insert commits, the writer resolves the receiver's current node and wakes its
inbox worker. This covers inserts racing with connection registration and the initial inbox read.

A bounded, staggered reconciliation pass covers lost wakeups and crashes between commit and
notification. Revisit unacknowledged rows. Never use a permanently advancing cursor that can miss
concurrent inserts or abandon rows already sent without ACK. Schedule fairly so stuck messages
do not permanently starve newer rows. A restart or worker crash must leave pending rows recoverable.

## Presence and cluster deployment

Each node maintains a local Registry mapping authenticated users to connection processes. Redis
maps users to owner nodes and session identifiers, with node heartbeats and expiry. Session-aware
updates and cleanup must prevent an old connection from deleting a newer connection's route.
Presence is a hint; only receiver ACK confirms direct delivery.

Configure unique BEAM node names, discovery, shared cluster authentication, and reachable
distribution ports for the existing deployment. Keep distribution on a trusted private network;
document any required TLS configuration. Local single-node development must still work.
Cluster partitions and node loss must lead to bounded fallback rather than indefinite waits.

## Capacity and obsolete components

Bound in-flight attempts, worker concurrency, pending work, queued bytes, per-connection pressure,
database batches, and retries. Enforce admission before allocating/forwarding payload work;
bounded tracking maps alone do not bound BEAM mailboxes or transport queues. Return retryable
failure when capacity is exhausted. Coalesce inbox wakeups rather than accumulating them.

Remove the old Redis admission reservations, payload queues, delivery deadlines, outstanding
message ownership, and persistence-claim workers. Replace their relevant overload protections
with the bounded direct-delivery and inbox paths. PostgreSQL message writes should become
proportional to offline and unconfirmed delivery rather than all traffic.

## Implementation ownership

- `chatchat_tcp`: wire protocol, authenticated connections, local routing, presence, direct attempt
  tracking, receipt processing, bounded inbox scheduling, and cross-node delivery.
- `chatchat_broker`: pending-message schema, migrations, immutable identity checks, bounded inbox
  queries, and receiver-scoped deletion.
- `chatchat_client`: durable outbox/inbox, deduplication, reconnect recovery, and retry simulation.
- Deployment/configuration: BEAM clustering and existing service startup.
- Documentation, protocol consumers, admin views, and metrics: update affected surfaces to describe
  the new lifecycle and remove references to retired behavior.

Extend existing owning modules and supervision patterns where they fit. Add migrations rather
than rewriting applied migrations. No production compatibility rollout is needed, but keep the
repository runnable with all affected consumers updated together.

## Acceptance and focused proof

Add regression coverage at the owning layer and exercise these outcomes:

1. Local and cross-node online receipt return `ok` without PostgreSQL message writes or Redis
   payload writes.
2. Offline fallback returns `ok` only after commit; unavailable storage without confirmed receipt
   returns `failed`.
3. Lost responses, reconnects, and mocked-client restarts reuse the same durable outbox identity.
4. Receiver persistence precedes ACK; duplicate delivery produces one local message and another ACK,
   including after receiver restart.
5. ACKs from the wrong receiver, wrong identity, stale session, or unrelated attempt cannot confirm
   or delete a message.
6. Concurrent identical inserts are idempotent; conflicting content for an existing identity fails.
7. Late ACK/fallback races, commit-before-notification crashes, stale routes, and node failure preserve
   the ownership rule and recover pending messages.
8. Inserts racing with reconnect/inbox reads are eventually delivered despite a lost wakeup.
9. Unacknowledged rows remain eligible for retry without permanently starving newer rows.
10. Capacity exhaustion and slow receivers keep queues, workers, bytes, and in-flight state bounded.

Use dedicated test PostgreSQL and isolated Redis as required by `AGENTS.md`. Run focused tests
first, then the cross-app checks required by the implemented scope. Do not run load provisioning
or large simulations without explicit authorization. Report unavailable services and unrun checks.

Completion means the coherent backend/client path works, retired Redis message machinery is removed,
deployment supports the chosen node communication, and current docs describe the implemented system.
