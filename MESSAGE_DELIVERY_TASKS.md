# Message delivery implementation tasks

Implement [MESSAGE_DELIVERY_GOAL.md](MESSAGE_DELIVERY_GOAL.md). This is the task backlog, not
authorization to run large simulations or reset data. Completion and acceptance evidence are recorded below.

Follow `AGENTS.md`. Preserve unrelated changes. Add migrations, do not rewrite applied migrations.
Update consumers together when switching the protocol. Do not introduce a permanent dual delivery
mode. Each task includes focused regression tests; task 9 verifies the complete system.

## Dependencies and execution

Complete task 1 first. Tasks 2, 3, and 4 can then proceed independently against its contract.
Task 5 combines their backend work. Task 6 extends that path for stored delivery. Task 7 integrates
the client store and new protocol. Task 8 removes obsolete behavior and updates affected surfaces.
Task 9 closes the implementation after all preceding tasks pass.

Keep foundational changes runnable. Switch backend entry points and mocked-client protocol consumers
together when tasks 5–7 are integrated. Shared files such as TCP supervision and configuration need
one integration owner if different agents implement separate tasks.

## 1. Freeze the wire and internal delivery contract

- [x] Define the new protocol and internal outcomes.

Contract: [MESSAGE_DELIVERY_CONTRACT.md](MESSAGE_DELIVERY_CONTRACT.md). The backend, mocked clients, and admin protocol reference now use the implemented contract.

Primary files: `apps/chatchat_tcp/lib/chatchat_tcp/request_handler.ex`,
`apps/chatchat_tcp/lib/chatchat_tcp/handler.ex`, `apps/chatchat_client/lib/chatchat_client/socket.ex`,
and the TCP protocol documentation exposed by `chatchat_web`.

Deliverables:

- Specify send, receive, receipt ACK, and sender result frames. Use client-created UUID message IDs
  and authenticated sender identity; include sender ID in received identity and ACK correlation.
- Specify `ok`, retryable `failed`, validation/conflict errors, and unknown outcomes. Permanent invalid
  requests must not cause an endless automatic retry loop; retain/report rejected outbox entries.
- Define immutable receiver/payload matching, backend timestamps, attempt correlation, and late ACK
  handling. IDs must be validated before use.
- Select concrete finite deadlines and capacity limits for the initial implementation, including
  bytes and pending work. Define where each limit is enforced.
- Define registration behavior for the supported single active connection. Reject a second connection
  or replace it coherently; do not accidentally implement multi-device delivery.
- Define the durable local storage approach for mocked clients after checking installed facilities.
  Require atomic inbox/deduplication writes, crash recovery, and bounded memory/file handles.

Acceptance: the protocol contract covers every goal outcome and is concrete enough for backend and
client work to proceed without inventing incompatible frames or storage assumptions.

## 2. Implement PostgreSQL pending-message ownership

Depends on: 1.

- [x] Add composite identity and safe pending-message operations.

Implemented: additive composite-primary-key migration, committed immutable-content insert checks,
bounded composite inbox pages, receiver-scoped deletes, and broker regression coverage.
Temporary old-protocol adapters were removed with the coordinated switch.
Verification on 2026-10-09: formatting, high-priority Credo, and test-environment compilation
with warnings as errors passed. After starting dedicated disposable services from
`docker-compose.test.yml`, all test migrations and five broker regression tests passed,
including independent concurrent transactions, immutable conflicts, composite identity,
timestamps, page bounds/wrap, and receiver-scoped deletion.

Primary files: `apps/chatchat_broker/lib/chatchat_broker/storage/messages_store.ex`,
`apps/chatchat_broker/lib/chatchat_broker/storage/schemas/message.ex`, and a new migration under
`apps/chatchat_broker/priv/repo/migrations/`.

Deliverables:

- Enforce uniqueness on `(sender_id, message_id)` rather than message ID alone.
- Insert pending messages with backend timestamps. Concurrent identical inserts return confirmed
  storage only after commit; conflicting receiver/payload reuse returns an explicit error.
- Preserve the existing row timestamp for identical retries.
- Provide bounded receiver-specific inbox reads and receiver-scoped composite-identity deletes.
  Remove unbounded reads from the delivery path.
- Support fair revisiting of unacknowledged rows without a permanent advancing cursor.

Acceptance: focused database tests cover concurrent inserts, content conflicts, identical IDs from
different senders, timestamps, page bounds, and deletion authorization. Migration runs on the
dedicated test database without rewriting migration history.

## 3. Implement session-aware routing and BEAM deployment

Depends on: 1.

- [x] Make presence a safe routing hint and connect TCP nodes.

Primary files: `apps/chatchat_tcp/lib/chatchat_tcp/presence.ex`, `presence_routing.ex`,
`redis_keys.ex`, `application.ex`, `config/runtime.exs`, `Dockerfile`, and `docker-compose.yml`.

Deliverables:

- Maintain local authenticated connection registration and Redis owner-node/session routes.
- Keep heartbeats and expiry; make updates/removal session-aware so stale cleanup cannot erase a
  newer route. Handle Redis failure without claiming confirmed receipt.
- Translate routes only to trusted/discovered BEAM nodes; do not create arbitrary atoms from Redis
  or client input.
- Configure unique node names, discovery, cluster authentication, and reachable private distribution
  ports. Preserve single-node development and scalable Compose TCP replicas.
- Document trusted-network requirements and any TLS setup without printing cookies/secrets.

Acceptance: tests cover registration, route expiry, stale-session cleanup, second-connection policy,
and unavailable routes. A small two-node check demonstrates discovery and direct process messaging.

## 4. Add durable storage to the mocked clients

Depends on: 1.

- [x] Persist outbox, inbox, and deduplication before network actions.

Primary files: `apps/chatchat_client/lib/chatchat_client.ex`,
`apps/chatchat_client/lib/chatchat_client/application.ex`, and the smallest needed local storage
module under `apps/chatchat_client/lib/chatchat_client/`.

Deliverables:

- Persist a stable message identity, immutable receiver, and payload before the first send.
- Atomically persist receiver content plus `(sender_id, message_id)` deduplication before allowing ACK.
- Preserve deduplication indefinitely and recover outbox entries after process restart.
- Define isolated state paths/namespaces for users, simulations, and tests. Normal disconnect/restart
  must not clear durable state. Make cleanup explicit.
- Keep loaded records, open storage resources, and concurrent writes bounded.

Acceptance: storage tests demonstrate save-before-send, atomic receive/deduplication, duplicate receipt,
restart recovery, write failure handling, and isolation between simulated users/runs.

## 5. Implement bounded direct delivery and PostgreSQL fallback

Depends on: 1, 2, 3. Integrate the protocol switch with task 7.

- [x] Replace Redis admission with receipt-or-commit delivery.

Primary files: `apps/chatchat_tcp/lib/chatchat_tcp/request_handler.ex`, `handler.ex`,
`message_admission.ex`, `message_delivery.ex`, and owning supervised delivery processes.

Deliverables:

- Validate sends and derive sender identity from authenticated state.
- Admit bounded work before forwarding; deliver locally or asynchronously across the cluster.
- Track exact attempt/message/session correlation and receiver-scoped receipt ACKs.
- Return `ok` after confirmed receipt without any PostgreSQL message write.
- On offline/stale routes or finite receipt deadline, use task 2's committed fallback. Return `failed`
  if neither outcome is confirmed. Wake the current receiver node after every successful insert.
- Handle sender disconnect, worker failure, late/duplicate ACKs, and ACK/insert races. A row committed
  during a receipt race stays eligible for normal inbox recovery.
- Enforce bounds on active attempts, queued bytes, receiver pressure, remote work, and mailbox ingress;
  release reservations/tracking on every completion or crash path.

Acceptance: focused TCP tests cover local/cross-node receipt, offline commit, storage failure, stale
route, timeout, unauthorized ACK, late correlation, capacity rejection, and crash cleanup. Assert no
Redis payload write and no PostgreSQL message write for confirmed direct delivery.

## 6. Implement bounded inbox delivery and reconciliation

Depends on: 2, 3, 5.

- [x] Recover stored messages on reconnect and lost wakeups.

Primary files: `apps/chatchat_tcp/lib/chatchat_tcp/delivery.ex`, `delivery_queue.ex`,
`message_delivery.ex`, and connection authentication in `handler.ex`.

Deliverables:

- Register receiver presence before scheduling the first PostgreSQL inbox read.
- Reuse the delivery scheduler where appropriate; bound workers, pending receivers, bytes, reads,
  outstanding receipts, and retries. Coalesce repeated wakeups.
- Delete stored messages only after authorized receipt ACK, using task 2's receiver-scoped operations.
- Add staggered reconciliation for locally connected receivers; avoid Redis keyspace scans.
- Revisit unacknowledged rows and rotate fairly. Recover after task failure, disconnect, lost wakeup,
  concurrent insertion, and node restart.

Acceptance: tests cover insert/reconnect races, commit without notification, repeated reconciliation,
unacknowledged rows, fair progress past stuck messages, worker crashes, and bounded queue saturation.

## 7. Integrate durable retrying mocked clients

Depends on: 1, 4, 5; stored-delivery proof also requires 6.

- [x] Switch socket/client/simulator behavior to the new delivery contract.

Primary files: `apps/chatchat_client/lib/chatchat_client.ex`, `socket.ex`, `simulated_client.ex`,
`simulator.ex`, `load_generator.ex`, and existing socket/simulator tests.

Deliverables:

- Send only committed outbox entries; clear them only on matching `ok`.
- Retry `failed`, timeout, and disconnect using the same identity and bounded backoff/concurrency.
  Recover pending work on reconnect and process restart.
- Route every incoming-message path through durable receive storage before ACK, including frames
  arriving while another request awaits its result. ACK saved duplicates too.
- Surface durable write failures and permanent protocol errors without falsely reporting success.
- Keep the simulator usable with the new asynchronous lifecycle; update result accounting and small
  fixtures. Do not add client-side ordering or history synchronization.

Acceptance: socket tests prove lost-response retry, disconnect recovery, matching-result handling,
save-before-ACK, duplicate ACK, interleaved frames, and restart persistence. Small integration fixtures
exercise direct and stored delivery through the mocked client.

## 8. Retire Redis message machinery and update surfaces

Depends on: 5, 6, 7.

- [x] Remove the old lifecycle and make documentation/metrics match the new one.

Primary files: TCP `message_admission.ex`, `message_persistence.ex`, `persistence.ex`,
`redis_keys.ex`, `application.ex`, `priv/redis/`, configuration, TCP telemetry/PromEx,
affected `chatchat_web` admin/protocol consumers, monitoring assets, and READMEs.

Deliverables:

- Remove obsolete reservation, payload, deadline, outstanding, persistence-claim, and message Pub/Sub
  paths, their workers, unused Redis connections, and obsolete tests/configuration.
- Keep presence-related Redis operations and any helpers still needed for atomic session routing.
- Update admin views and metrics to reflect direct receipt, fallback, failure, capacity, inbox work,
  and pending PostgreSQL rows. Remove misleading old lifecycle counters/panels.
- Replace `MESSAGE_DELIVERY.md` with implemented behavior and update protocol/app/deployment docs.
  Keep goal/backlog links accurate.
- Do not flush Redis or reset existing data as part of code cleanup.

Acceptance: targeted searches find no live Redis message ownership/payload path or old protocol consumer.
Affected web/metrics checks pass; documentation agrees with actual implemented behavior.

## 9. Prove end-to-end ownership and close the backlog

Depends on: 2–8.

- [x] Run focused failure acceptance and required cross-app checks.

Deliverables:

- Exercise every acceptance condition in `MESSAGE_DELIVERY_GOAL.md` using focused tests and small
  local/two-node fixtures, including sender-node death after commit and receiver restart after save.
- Verify direct online delivery makes no PostgreSQL message writes and Redis retains no payloads.
- Verify storage failure without receipt produces retryable failure; uncertain outcomes remain safe
  under duplicate delivery and sender retry.
- Verify slow receivers, unavailable nodes, and lost wakeups preserve bounded resources and eventual
  recovery when connectivity/services return.
- Use a dedicated `TEST_DATABASE_URL`, isolated `TEST_REDIS_URL`, and test migrations. Run affected
  tests first, then `mix format --check-formatted`, `mix credo --min-priority high`,
  `MIX_ENV=test mix compile --warnings-as-errors`, and `mix test` for the cross-app change.
- Record verification and material limitations. Mark tasks complete only after their acceptance passes;
  explicitly report unavailable services or unrun checks. No large load simulation is required.

Acceptance: all goal conditions have evidence, all required checks pass or have an explicit unresolved
blocker, and repository docs describe the final system. Unresolved required checks prevent claiming
the architecture implementation complete.

## Completed verification — 2026-10-10

All nine tasks are implemented. Dedicated PostgreSQL and Redis services from
`docker-compose.test.yml` were used; the additive migration ran successfully.

- Required checks passed: formatting, high-priority Credo, test compilation with warnings
  as errors, and the full umbrella suite (103 tests: broker 18, auth 2, web 30, TCP 35,
  client 18). `git diff --check` also passed.
- Broker coverage proves independent concurrent inserts, immutable conflicts, timestamps,
  composite identities, bounded pages and scoped deletion.
- TCP coverage proves direct local/cross-node receipt without message writes, committed
  fallback, database outage, stale routing/session ACK rejection, sender-node death after
  commit, ACK/insert races, lost wakeups, receiver restart/deduplication, wrapping fairness,
  slow queued-frame accounting, saturated wake ingress, and real inbox-worker crash recovery.
- Presence coverage proves lease replacement/expiry, second-connection rejection, trusted
  route mapping and Redis outage acquisition/renewal failure. Client tests prove durable
  ownership, write failure, isolated/exclusive namespaces, bounded store ingress, actual
  response-timeout retry, disconnect/restart recovery, matching results, duplicate/interleaved
  receipt ACKs, durable protocol suspension, and simulator result accounting.
- The named-node `scripts/check_tcp_cluster.exs` fixture passed DNSPoll discovery and direct
  two-node messaging. Both Compose files passed `config --quiet`. Targeted live-source,
  configuration and dashboard searches found no retired Redis message ownership or protocol.

Material validation limits: the discovery fixture uses a localhost resolver; actual container
DNS/replica discovery and a Docker image build were not exercised. No large simulation,
production deployment, Redis flush, or shared-data reset was run. The isolated test services
remain available. These limits do not replace the passing small two-node and failure fixtures.
