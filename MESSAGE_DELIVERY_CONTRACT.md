# Delivery implementation contract

Implemented contract for [the delivery goal](MESSAGE_DELIVERY_GOAL.md) and
[implementation backlog](MESSAGE_DELIVERY_TASKS.md). Backend and client use this protocol together.

## Wire frames

Keep newline-delimited UTF-8 JSON, authentication first, `ping`/`pong`, and presence queries.
Authentication returns `{"type":"authenticated","user_id":10}`. A send is:

```json
{"type":"send_message","request_id":"7a724ef9-c670-49e2-b992-bd8ceff94d24","message_id":"c3945190-a81c-4c80-912f-9bfc788d0651","user_id":11,"message":"Hello"}
```

`user_id` means receiver. The authenticated connection supplies sender identity; reject a
client-supplied `sender_id` or `from_user_id`. Both IDs are canonical lowercase UUID strings
validated with `Ecto.UUID` before database, routing, or tracking use. `message_id` is generated
once by the client before outbox commit. `request_id` is a fresh UUID for each transmission,
including retries. User IDs are positive signed 64-bit integers. `message` is a UTF-8 string
of at most 4,096 bytes; empty strings are allowed. Receiver and exact decoded payload bytes
are immutable for a message identity. Reject malformed field types; do not coerce them.
Send and delivery frames must fit the 4,096-byte encoded-frame limit, excluding newline.
Envelope fields and JSON escaping count toward this limit, so the usable payload is smaller
than 4,096 bytes. Use compact UTF-8 JSON with standard required escaping for these frames.
Before outbox commit, clients check both the send frame and the resulting delivery envelope,
reserving 36-character UUIDs, a 19-digit sender ID, and a 27-character UTC microsecond timestamp.
Servers perform the same delivery-size check before admission, routing, or storage; an oversized
delivery envelope receives correlated `rejected` with reason `invalid_request`. Servers also
check outgoing delivery frames before send. Extra fields or whitespace do not enlarge the
frame allowance; an oversized incoming frame follows the uncorrelated error/close rule below.

```json
{"type":"message_result","request_id":"7a724ef9-c670-49e2-b992-bd8ceff94d24","message_id":"c3945190-a81c-4c80-912f-9bfc788d0651","status":"ok"}
{"type":"message_result","request_id":"7a724ef9-c670-49e2-b992-bd8ceff94d24","message_id":"c3945190-a81c-4c80-912f-9bfc788d0651","status":"failed","reason":"unavailable"}
{"type":"message_result","request_id":"7a724ef9-c670-49e2-b992-bd8ceff94d24","message_id":"c3945190-a81c-4c80-912f-9bfc788d0651","status":"rejected","reason":"identity_conflict"}
```

`ok` means receiver durable receipt or committed PostgreSQL ownership. `failed` is retryable:
`capacity` or `unavailable`. `rejected` is permanent: `invalid_request`, `invalid_receiver`, or
`identity_conflict`. Neither failure proves non-delivery. Missing responses are unknown outcomes.
Results match both IDs on the sending authenticated connection; ignore late/unmatched results.
Valid correlation IDs with invalid other fields receive `rejected`. Invalid correlation IDs,
invalid JSON, oversized frames, or unknown frame types receive an uncorrelated
`{"type":"error","error":"invalid_request"}` (or `frame_too_large`) and close the socket.
A client reports this error and durably suspends automatic sends for that authenticated user
in its run namespace, retaining all outbox entries. Because the error is uncorrelated, do not
guess which entry caused it. Suspension survives reconnect and process restart and excludes
that user's entries from automatic retry queries. Resume only after explicit operator action
following correction of the protocol error; reconnect alone never resumes sends. Failure to
persist suspension keeps the client stopped with a storage error. Never silently discard the
outbox or spin on a permanently malformed request.

```json
{"type":"message","message_id":"c3945190-a81c-4c80-912f-9bfc788d0651","from_user_id":10,"message":"Hello","inserted_at":"2026-10-09T10:00:00.000000Z","receipt_id":"26df9a61-b860-4aa7-a982-fac892087538"}
{"type":"message_delivered_ack","message_id":"c3945190-a81c-4c80-912f-9bfc788d0651","from_user_id":10,"receipt_id":"26df9a61-b860-4aa7-a982-fac892087538"}
```

Every transmission, direct or stored, gets a server-generated UUID `receipt_id`. ACK only
after durable receive commit, including duplicates. ACKs have no success response. Ignore
unknown, duplicate, expired, wrong-user, wrong-identity, and stale-session ACKs without deleting
rows or confirming an attempt. Validate ACK fields before lookup. Identity is
`(from_user_id, message_id)`, never message ID alone. Deduplication ignores timestamp changes;
a duplicate identity with different content is a local conflict and must not be ACKed.

Remove `message_admitted` and `message_accepted_ack` during the coordinated protocol switch.
No server-generated message identity or sender acceptance handshake remains.

## Internal outcomes and ownership

The broker insert operation returns `{:ok, stored_message}` only after commit, including
identical retries; `{:error, :identity_conflict}` for immutable-content mismatches; and
`{:error, :unavailable}` for storage failure. A unique `(sender_id, message_id)` constraint
serializes concurrent inserts. Check receiver and payload of the winning row before success.
Do not use unchecked conflict-ignore as proof of ownership. The stored timestamp wins on
identical retries. A new attempt assigns backend UTC microsecond time; insertion after row
deletion may assign a new time. Timestamps imply no ordering.

Direct tracking binds receipt ID to message identity, authenticated receiver, receiver session,
sender connection/session, request ID, origin node and monotonic deadline. An internal BEAM
reference identifies the attempt; wire receipt IDs are not authority. Receiver-node confirmation
must come from the tracked connection/session and return to the tracked origin. Never resolve
an ACK by message ID alone or accept client-provided routing. Only trusted connected nodes
may receive routing; match Redis node names against known nodes without creating atoms.

Completion is a single state transition: confirmed receipt or committed storage produces `ok`;
otherwise bounded attempt failure produces `failed`. Disconnect removes sender response work
but does not cancel a database write already running. Monitor workers and release reservations
on every exit. Late receipts cannot complete a newer request. A fallback row committed during
a receipt race remains pending for ordinary inbox delivery and authorized cleanup.

After every insert success (including identical retries), resolve the current receiver route
and wake its inbox worker. ACK deletion uses authenticated receiver plus composite identity
from bounded receipt tracking; never fields alone. Missing rows on authorized repeated deletion
are harmless. PostgreSQL reads return at most 128 rows ordered by composite identity for one
receiver. Each worker rotates a transient cursor and wraps, revisiting unacknowledged rows;
reconciliation must reset/wrap cursors rather than permanently excluding earlier inserts.

## Single connection and presence

Reject a second live connection with `already_connected`; leave the first route intact. Use a
unique local Registry and atomic Redis session acquisition. A route contains owner node and
random session UUID. Its lease lasts 30 seconds and renews every 10 seconds. Acquisition of
an occupied lease rejects even if its owner is unreachable; expiry permits recovery. If Redis
cannot confirm acquisition, reject authentication as `presence_unavailable` and release local
registration. Registration and route acquisition precede initial inbox scheduling.

Renewal and removal compare session and owner. On renewal failure, stop accepting sends and
close the connection before its last confirmed lease expires; never renew an expired/replaced
session. Old handlers cannot remove new routes. Node heartbeat uses the same 10/30-second
intervals. Presence and heartbeats are hints, not receipt confirmation.

## Initial bounds and enforcement

Limits below are per node unless stated otherwise. Test configuration may lower them.
Byte reservations count payload plus encoded frame sizes retained for work; account for each
retained copy. Keep tracking metadata fixed-size and bounded by item counts.

| Limit | Initial value | Owning enforcement point |
| --- | --- | --- |
| Frame, excluding newline | 4,096 bytes | Handler incremental parser before JSON decode; client/server encoders before send |
| Authentication / idle socket timeout | 5 / 60 seconds | TCP transport and handler |
| Direct window | 2 seconds total | Sender coordinator monotonic timer; never extended by retries |
| Direct transmissions | At most 2, second after 500 ms | Coordinator, only with a live reservation |
| Database operation timeout | 5 seconds | Broker query/transaction and monitored fallback worker |
| Sender result deadline | 8 seconds | Coordinator; client waits 10 seconds |
| Active sender attempts / retained bytes | 409 / 8 MiB | Atomic admission before payload enqueue |
| Attempts per sender connection | 16 | Handler admission before coordinator submission |
| Fallback workers / waiting fallbacks | 32 / 409 | Coordinator; waiting work shares attempt/byte budget |
| Receiver outstanding frames / bytes | 16 / 192 KiB per connection | Shared direct/inbox connection reservation before enqueue |
| Receiver-node aggregate delivery reservations | 682 / 8 MiB | Receiver node, before remote or local payload transfer |
| Inbox workers / pending receivers | 64 / 4,096 | Delivery scheduler, coalesced wakeups |
| Inbox page / aggregate loaded inbox bytes | 16 rows / 8 MiB | Broker bounded query and scheduler reservation |
| Stored receipt lifetime / resend interval | 10 / 10 seconds | Inbox scheduler; release permits and revisit rows |
| Reconciliation | Every 30 seconds, staggered | Local registered users in bounded batches of 128 |
| Client outstanding sends / loaded page | 16 / 128 entries per user | Client scheduler and durable-store page queries |
| Client retry delay | 1, 2, 4, 8, 16, then 30 seconds; 0–20% added jitter | Per-entry scheduler, also after reconnect |

Offline routes go straight to fallback. Route loss, refused receiver admission, or an exhausted
direct window trigger fallback within the same result deadline. Admission exhaustion returns
retryable `failed` before allocating payload work. Timed-out writes can have committed; sender
retries safely. Do not report success just because a task was started.

The eight-second result deadline starts at sender admission and includes direct delivery and
fallback queue time; queueing never resets it. Remove expired waiting fallbacks without starting
a write and return `failed` with reason `capacity`. Start a queued write only while its deadline
is live. Its database timeout is the smaller of five seconds and the remaining result time.
At the result deadline, an unconfirmed running write produces `failed` with reason `unavailable`.
A write already running may still commit; keep its worker/count/byte reservations until it exits,
and wake the current receiver after any confirmed commit. Do not send a second result or let
late completion resolve a newer attempt. Sender disconnect removes waiting work but does not
cancel a running write. A confirmed receipt or commit before the deadline completes the attempt
once; any concurrent running write retains its reservations until exit.

Bound mailbox ingress with reservations, not casts followed by queue-length checks. Local
producers acquire atomic count/byte permits before sending payloads. Across nodes, request a
small permit asynchronously before transmitting a payload; cap pending permit requests at
409 at the origin, apply receiver admission, and expire unused permits after 2 seconds.
No blocking remote calls in handlers. Sender requests, remote permits, direct sends, and inbox
delivery share their respective budgets, including already-enqueued work. Gate socket reads
with active-once/transport flow control; a slow socket has finite send timeout (1 second) and
is disconnected rather than accumulating deliveries. Review Thousand Island transport behavior
when implementing this gate; tracking maps alone are insufficient proof.

Inbox queries reserve worst-case page bytes before starting: per row, 4,096 payload bytes plus
4,096 encoded-frame bytes and bounded metadata, accounting for any additional retained copies.
Reduce page size if the remaining byte budget is smaller. Rotate past stuck rows
once their receipt window expires. Repeated wakes coalesce to one pending pass; a full pending
queue drops the hint and relies on reconciliation. No Redis keyspace scans or payload writes.

## Mock client durable storage

The client already depends on Ecto, but `mix.lock` contains no SQLite adapter or transactional
local store. Choose SQLite through `exqlite` for task 4: one database per run namespace,
indexed by authenticated user. This small dependency provides transactions, indexed paging,
and crash recovery without loading all deduplication records or opening one file per user.
OTP DETS would impose a 2 GiB file limit and require custom transactional/index maintenance.

Use one supervised store owner and SQLite connection per namespace, with
WAL mode and `synchronous=FULL`. Commit outbox rows before any network send. An inbox row
with primary key `(user_id, sender_id, message_id)` holds payload and deduplication together;
one transaction inserts or verifies the existing immutable content before permitting ACK.
Retain inbox identities indefinitely. Delete outbox only on a matching `ok`; permanent
rejections remain stored with their reason and are excluded from automatic retry queries.
Store the per-user automatic-send suspension and its error durably in the same namespace;
recovery checks it before scheduling outbox entries.
Recover pending rows using indexed pages, not a full-table load. Retry has no attempt cutoff.

State path is an explicitly selected writable root plus run UUID; persist the run UUID for
restart reuse. Ordinary interactive use has a stable namespace. Each simulation/test chooses
a fresh namespace; shards use distinct namespaces. The authenticated user is part of every
key/query. Disconnect and normal shutdown never clear state. Cleanup is an explicit stopped-run
operation. Refuse opening a namespace already owned by another application instance.

Bound store submissions with 256 operations and 2 MiB of reserved bytes before enqueue, using
backpressure/errors rather than an unbounded GenServer mailbox. SQLITE_BUSY, disk-full, I/O,
or corruption errors surface as storage failures: no send before outbox commit, no ACK before
inbox commit, no destructive recovery. Database growth is on disk; loaded pages, connection
count, and writes remain bounded. Validate SQLite durability and restart behavior with focused
tests. The interactive namespace plus at most 16 simulations bounds each application to 17
store connections; each simulation owns a separate namespace to preserve concurrent runs.

## Contract review

Goal acceptance 1–2 maps to receipt/commit results; 3–4 to durable client transactions and retry;
5 to exact receipt/session tracking; 6 to broker uniqueness and immutable checks; 7 to bounded
attempts and retained fallback rows; 8–9 to post-commit wakeups and wrapping reconciliation;
10 to admission before enqueue and shared byte/count budgets. Tasks 2–9 supply executable
proof. The runtime and regression tests implement this contract.

Sender permits reserve 20 KiB per attempt; receiver permits reserve 12 KiB per frame,
including retained copies and metadata. Inbox pages reserve 20 KiB per row. Queued frames
retain permits after expiry until consumed/discarded or the handler dies. Origin permits
remain until receiver transport consumption is confirmed or its coordinator dies. The
one-for-all delivery supervision group restarts coordinators, workers, scheduler, and
connection producers together. Wake ingress, pending receivers, retry timers, and cursor
metadata each have a separate 4,096-item bound.
