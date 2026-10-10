# Message delivery

Delivery is at least once. The identity is `(authenticated sender_id, client message_id)`.
The mocked sender records its immutable receiver and payload in an in-memory outbox before sending.
Each transmission uses a fresh request UUID. Until a matching `ok`, that outbox owns recovery.
`ok` means an authenticated receiver accepted the message in memory or PostgreSQL committed a pending row.
A failure or missing response can still have delivered a copy; retry preserves the identity.

See [wire frames and precise limits](MESSAGE_DELIVERY_CONTRACT.md),
[the architecture goal](MESSAGE_DELIVERY_GOAL.md), and [verification backlog](MESSAGE_DELIVERY_TASKS.md).
The live protocol reference is `/admin/tcp-protocol`.

## Direct receipt and fallback

Authenticated TCP handlers validate IDs, types, encoded sizes, and sender identity before
admitting payload work. Redis supplies only an expiring node/session route. Local Registry
entries and session-aware atomic Redis operations enforce one active connection per user.
Only local or connected BEAM nodes can be resolved from route strings.

The sender coordinator checks existing PostgreSQL identity/content, then requests a bounded
receiver permit before forwarding a payload. Local and cross-node deliveries share receipt
tracking. The direct window is two seconds, with at most two transmissions. An ACK binds the
authenticated receiver, its session, message identity, receipt UUID, and originating attempt.
Confirmed direct receipt produces `ok` without a PostgreSQL message write or Redis payload write.

Offline, stale, unavailable, or unconfirmed routes fall back to PostgreSQL. Composite identity
uniqueness serializes concurrent inserts; locked content checks reject conflicting reuse and
preserve the winning timestamp. Success is reported only after commit. Every confirmed insert
wakes the receiver's current route. A receipt racing with an insert can leave a pending row;
normal inbox delivery and receiver deduplication safely handle that extra copy.

The result deadline is eight seconds including queue time. Routing, insertion, and deletion
share 32 workers. A running write keeps its reservation even if the sender disconnects or
receives a failure; confirmed late commits still trigger inbox recovery.

## Stored inbox recovery

Presence registration precedes the first inbox wake. The scheduler coalesces hints, starts at
most 64 workers, and reserves page bytes before querying. Each page contains at most 16 rows;
composite cursors wrap and revisit unacknowledged rows after ten seconds. Authorized stored
ACKs delete by receiver and composite identity. Failed/deferred deletion leaves the row recoverable.

A staggered local reconciliation pass visits connected receivers in batches of 128 roughly
every 30 seconds. Lost hints, commit-before-notification crashes, and worker failures therefore
leave PostgreSQL ownership intact. No Redis keyspace scan is needed.

## Per-client behavior

Each client owns in-memory outbox, inbox deduplication, and suspension state. `Store` is a
pure helper, not a GenServer. Outbox insertion precedes network send. Inbox content and
composite deduplication are recorded before ACK; duplicates ACK again and conflicts never ACK.
Interleaved messages/results update that same client state during ping and online queries,
including when the query subsequently fails. No shared store admission or storage retry exists.

Matching `ok` removes an outbox entry. Failure, disconnect, and a ten-second unknown-outcome
timeout schedule bounded backoff (one to thirty seconds plus jitter). Disconnect/reconnect
preserves identity; client-process restart clears all state. Mocked receipt has no disk
durability. Permanent rejections remain available through `ChatchatClient.outbox/1`, while
uncorrelated protocol errors suspend automatic sends until `ChatchatClient.resume/1`.
There is no retry cutoff, ordering guarantee, history synchronization, or automatic
inbox deduplication expiry.

## Resource and crash bounds

Each node admits at most 409 sender attempts at 20 KiB each and 682 receiver reservations at
12 KiB each, within separate 8 MiB budgets. Each connection admits at most 16 sender attempts
and 16 outstanding receiver frames. Queued frames retain permits until consumed/discarded or
the handler dies, even after receipt expiry. Origin accounting also waits for transport consumption
or receiver coordinator death. Socket sends time out after one second.

Inbox loaded pages have an 8 MiB aggregate budget. Wake ingress, coalesced pending receivers,
retry timers, and cursor metadata each cap at 4,096. Full hint queues rely on reconciliation.
Each client caps its outbox at 128 entries and inflight attempts at 16; full outbox submissions
return capacity errors. Indexed inbox and outbox pages cap at 128. At most 16 simulations
run per application. Retained inbox deduplication grows in memory until its client stops.

A one-for-all delivery supervision group restarts coordinators, workers, scheduler, and TCP
connection producers together so old payload producers cannot outlive replacement budgets.
Redis owns only presence. PostgreSQL owns pending messages until authorized receipt cleanup;
each client owns sender recovery and receiver deduplication while its process lives.

## Deployment and monitoring

TCP releases use unique container-IP node names, DNSPoll discovery, a shared required cookie,
and private ports 4369/9100. See [deployment setup](README.md#tcp-load-balancing)
for trusted-network and distribution TLS requirements. Single-node development needs no discovery.

PromEx reports sender results by status/reason, stored inbox receipts, active attempts and workers,
receiver receipts, waiting work, reserved inbox bytes, and pending PostgreSQL rows. Admin events
are node-local telemetry forwarded through Phoenix PubSub; Redis has no message Pub/Sub path.
