# Stress-test bottleneck tasks

Evidence: [STRESS_TEST_FINDINGS.md](STRESS_TEST_FINDINGS.md).
Task numbers are stable references, not execution order. Keep HAProxy for this
work. Execution order is **finish 2 → 3 baseline → 8 → 6 → 4 → 5 → 7**.
Task 2 is complete: the bounded attribution report separates measured queue/churn
mechanisms from unresolved causal questions. Task 3 provides the controlled baseline required before applying
fixes and attributing improvements. Tasks 8 and 6 can then be implemented
independently. Do not stop, restart, patch, or
reconfigure the running simulation. Load runs and failure injection below belong in a separately authorized, isolated run.

## 1. Fix stale runtime metrics — priority P0

- [x] In `apps/chatchat_tcp/lib/chatchat_tcp/prom_ex/message_plugin.ex`, collect
  local connection metrics independently of delivery coordinators and PostgreSQL.
- [x] Bound slow collections, prevent overlapping collection work, and report
  collection freshness/failure. Preserve existing metric names.
- [x] Update `observability/grafana/dashboards/chatchat.json` to distinguish stale
  values from zero and aggregate shared PostgreSQL counts without double counting.
- [x] Add a focused regression test: slow/failed dependency collection cannot
  prevent fresh local connection values; normal snapshots remain compatible.

Done when connection values update during dependency stalls and the dashboard
clearly identifies stale delivery/database values.

Implemented and verified: independent local polling, three bounded background
sources, freshness/failure metrics, dashboard filtering, and synthetic PromQL
checks. Focused collector/storage tests, the full Mix suite, format, high-priority
Credo, and warnings-as-errors compilation passed. The subsequent running TCP deployment now includes the collector (verified by
release RPC and live metrics). Grafana also identifies legacy exporters, keeps
unverified legacy readings per node, and displays live HAProxy socket counts.
Collector presence does not imply every source is currently fresh.

## 2. Identify where capacity is spent — priority P0

Depends on task 1.

- [x] Extend existing telemetry at its owning layers to distinguish worker queue
  delay, task scheduling delay, route lookup, direct receipt wait, database pool
  wait/transaction, and post-commit wakeup. Reuse existing Ecto timing metrics.
- [x] Count connection closure/reconnect reasons at the TCP and client layers;
  distinguish ping failure, presence lease failure, idle timeout, socket error,
  and intentional simulated disconnect.
- [x] Capture available HAProxy health/error metrics, CPU, scheduler queues,
  delivery reservations, disconnect reasons, and client attempt counters together.
- [x] Close missing client connection diagnostics and per-listener/source-port
  attribution; distinguish absent event series from proven zero events.
- [x] Inspect proxy source-port/TIME_WAIT pressure, descriptor limits, listen
  backlog, and database/Redis latency before changing resource limits.
- [x] Keep labels bounded: no user IDs, message IDs, payloads, or tokens.

Done when a report attributes the dominant queue delay and connection churn to
measured mechanisms. A shared CPU bottleneck remains a hypothesis until isolated.

Instrumentation and capture workflow implemented and an existing instrumented run
observed read-only. The 18:04–18:05 UTC report in `STRESS_TEST_FINDINGS.md` found
4–5-second queue p95, 409 active attempts/377 waiting/32 workers per node,
21k–56k shared Redix mailbox messages, and about 1,819 presence-failure
closures/second. Redis server execution was fast on average; client script
round-trip p95 was 4.6–6.5 seconds. HAProxy namespace listen drops increased by
1,058,995 in the sample window. These support client/runtime queueing and a
reconnect feedback loop; they do not prove a single exclusive root cause.

Completed task 2 measurement work:

- [x] Improve bounded capture of listener occupancy and per-destination source-port
  usage; record truncation explicitly. Correlate snapshots with kernel counter deltas
  so namespace listen drops are not assumed to identify a particular listener.
- [x] Capture Redis connection mailboxes and scheduler pressure repeatedly alongside
  lease failures, queue latency, and reconnect activity. Separate sustained queueing
  from transient spikes and identify unavailable observations.
- [x] Capture existing client retry state read-only where possible. Updated client
  images were measured in the separately authorized isolated run; the original
  workload was not restarted.
- [x] Produce a bounded attribution report distinguishing measured mechanisms,
  competing explanations, and unresolved limits. The user authorized
  the isolated follow-up run and database cleanup; shared CPU isolation remains task 3.

Completed with the authorized isolated run reported in `STRESS_TEST_FINDINGS.md`
(18:26–18:32 UTC). Repeated runtime/client probes and untruncated native socket
samples measured shared Redix queue growth, lease/ping failures, reconnects and
full TCP listeners before message traffic began. Sampled FD/source-port limits
were not exhausted. The fresh deployment had 12 schedulers/node, so it is not an
identical-resource performance comparison. The all-ready barrier failed; no new
message-throughput or recovery claim is made. The previous message-producing run
still provides delivery-stage attribution. PostgreSQL application tables were
flushed and verified empty before removing the temporary project/volumes.
Capture regression coverage passed (13 tests); no application behavior changed.

## 3. Establish stable connection capacity with isolated compute — priority P0

Depends on tasks 1–2. Owns test deployment and load-generator setup.

Completed controlled baseline (2026-10-10 UTC): **80,000 authenticated sockets**
held for 120 seconds with zero observed disconnects/reconnects. At that population,
about **794 unique sender confirmations/s** stayed bounded; nominal 4,000/s built
backlog and was stopped early. The interval between these traffic steps is untested;
80k is the largest tested stable connection step, not an exact capacity ceiling.
See [task 3 findings](STRESS_TEST_FINDINGS.md#task-3-controlled-compute-baseline-2026-10-10-utc)
and [repeatable baseline procedure](observability/BASELINE.md).

- [x] Document a repeatable run using separate generator compute, or measured CPU
  allocations with backend headroom. Capture effective options, not just Compose
  defaults, plus versions, replica counts, and resource limits.
- [x] Record effective BEAM schedulers, normal run queues, CPU allocations, and
  HAProxy threads. Compare measured TCP scheduler settings with CPU available after
  reserving generator/proxy capacity; do not increase every service's CPU demand.
- [x] Ramp requested connection counts in bounded steps below the observed failure
  point; hold each step long enough to observe repeated lease renewals, pings,
  reconnects and backlog slope. Record a bounded wall-clock setup deadline so an
  unmet all-ready barrier cannot leave the test running indefinitely.
- [x] After a connection step stabilizes, establish the all-ready barrier and ramp
  message traffic using the existing simulator. Keep receiver selection and
  cross-node traffic comparable; zero queued messages during setup is not a
  delivery-throughput result.
- [x] Record actual authenticated sockets separately from ready wrappers; measure
  unique messages queued/confirmed, confirmation latency, outstanding outbox work,
  and retries. Do not interpret attempt counters as unique-message success rates.
- [x] Establish the largest sustainable load before raising admission limits.


Fixed Docker CPU sets separate generator, TCP, proxy and storage capacity. Effective
schedulers, quotas, runtime queues and actual sockets were captured. At the unsafe
traffic step HAProxy reached its CPU quota while generators retained CPU headroom;
backend runtime/client queues also grew. Admission limits remain unchanged.
All 233,719 sender submissions confirmed during drain. Receiver scans covered
79,999/80,000 clients (one timed out), so full receiver/no-loss reconciliation is
unproven; task 7 retains that scope and outage/recovery testing.

## 4. Correct delivery deadline handling — priority P1

Depends on task 2; coordinate with task 8. Owners:
`apps/chatchat_tcp/lib/chatchat_tcp/message_delivery.ex` and
`apps/chatchat_broker/lib/chatchat_broker/storage/messages_store.ex`.

Evidence from the earlier message-producing run: queue p95 rose from 4–5 seconds
toward the 10-second histogram boundary while initial scheduling delay was about
4 ms. Final persistence p95 was 94–121 ms. Database logs include checkout/connection
timeouts. The latest setup-only run submitted zero messages, so its elevated Ecto
latencies are not delivery-transaction measurements. Trace budget handling before
editing; do not attribute all failures to PostgreSQL or infer the tail above the
histogram boundary.

- [ ] Recompute remaining deadline inside the worker when it begins; do not start
  a new database write after the sender attempt deadline has expired.
- [ ] Verify installed Ecto/DBConnection timeout semantics across checkout,
  transaction, and commit; correct budget propagation where evidence shows an error.
- [ ] Verify successful commit acknowledgement remains independent of a slow
  post-commit Redis wakeup. Preserve bounded worker ownership and late-commit recovery.
- [ ] Add focused coverage for delayed scheduling, pool timeout, ambiguous commit,
  confirmed late commit, and failed wakeup, reusing existing recovery tests.

Done when expired queued work avoids new writes, committed rows remain recoverable,
and `ok` still requires a valid receiver receipt or confirmed PostgreSQL commit.
Keep stable identities, deduplication, receiver-scoped ACKs, and admission accounting.
Do not fix this by merely lengthening timeouts or expanding queues.

## 5. Stabilize proxy health checks and accept capacity — priority P1

Depends on task 3 baseline and tasks 8/6 reducing reconnect pressure. Owner: `observability/haproxy.cfg`, with TCP HTTP health
handling only if the current endpoint is demonstrably expensive or unsuitable.

- [x] Obtain initial bounded, per-listener accept-queue and source-port samples.
  The task 2 follow-up measured TCP 4040 queues at 4097/4095 against backlogs of
  4096, with 2,982,927 namespace listen drops. Sampled FDs and destination port
  counts remained below their limits; this does not exclude brief unsampled pressure.
- [ ] Repeat these measurements in task 3's stable connection-only and traffic
  steps, then after tasks 8/6. Use the existing native socket capture; correlate
  probe timestamps and kernel deltas without assigning every namespace drop to
  one listener. Do not raise FD/port limits without evidence of exhaustion.
- [ ] After reducing reconnect pressure, compare proxy thread/backlog settings at
  equal offered load and CPU budget. Two proxy threads were near 175% CPU and
  namespace listen drops increased sharply; larger backlogs alone do not add capacity.
- [ ] Measure healthy check latency under the intended resource allocation.
- [ ] Set explicit check timeout and failure/recovery hysteresis from that evidence;
  document the resulting bounded outage-detection window.
- [ ] Keep checks lightweight and meaningful for accepting traffic. Add a dedicated
  endpoint only if needed; preserve `/metrics` for observability.
- [ ] Validate healthy-but-busy, unavailable, and recovered backends independently.

Done when representative healthy load avoids false removal while a failed backend
is removed and restored within the documented bounds. Longer checks alone do not
establish improved delivery capacity.

## 6. Bound reconnect amplification — priority P0

Depends on completed task 2 attribution and task 3 baseline.

Latest evidence quantifies amplification before message traffic: about 2,259/s
presence closures at peak, 105,004 client ping failures, 62,467 peer closes,
879,881 reconnect attempts and 714,121 connect/authenticate failures in the final
successful shard observations. Counts include asynchronous/in-flight attempts.
Initialized intentional-disconnect counters were zero; missing TCP event series
remain unknown. Retry spacing per client is still unmeasured. Owner:
`apps/chatchat_client/lib/chatchat_client.ex` and the existing simulator/socket flow.

- [ ] Extend the existing reconnect timer with bounded exponential backoff and
  jitter; reset on successful authentication. Keep one pending reconnect timer.
- [ ] Preserve outbox message identities, inbox deduplication, existing pings,
  and eventual reconnection. Reuse existing retry patterns where appropriate.
- [ ] Test repeated failures, jitter bounds, recovery/reset, and retained messages.

- [x] Identify the existing fixed one-second client reconnect and wrapper restart
  owners; rebuilt client diagnostics were captured in task 2.
- [ ] Trace their interaction on startup failure, socket loss and client-process
  death before editing. Ensure wrapper restart and client reconnect cannot create
  concurrent duplicate attempts; bound startup/recreation retries as well as
  reconnects if the audit shows they amplify pressure.
- [ ] Measure retry intervals and aggregate attempts in bounded outage/recovery
  tests. Convenience samples of 16 client states are not proof of population-wide
  retry spacing. Rebuild changed client images for the comparison run.

Done when an outage produces bounded, spread retries, no concurrent duplicate
connection attempts per client, and recovery with pending messages intact. Compare
presence closures, ping failures, connect/authenticate failures and listen-drop
deltas at equal connection ramp, traffic and CPU allocation.

## 7. Validate recovery and sustainable capacity — priority P1

Depends on completed applicable fixes above.

- [ ] Run focused tests first; use dedicated PostgreSQL and isolated Redis for
  integration tests and migrate the test database before database tests.
- [ ] For cross-app changes run `mix test`; complete repository gates:
  `mix format --check-formatted`, `mix credo --min-priority high`,
  `MIX_ENV=test mix compile --warnings-as-errors`.
- [ ] In the isolated load run, compare identical load/resource steps before and
  after changes. Validate connection-only setup first, then traffic, backend
  outage/recovery and a drain phase. Stop failed setup at its declared deadline;
  a failed all-ready barrier cannot establish message throughput or recovery.
- [ ] Save final counters and recovery/drain evidence before stopping writers.
  Flush application tables in the dedicated stress PostgreSQL database, verify
  empty counts, and remove temporary deployment resources. Never flush shared data.
- [ ] Confirm bounded queues and memory, fresh metrics, stable sockets, recovery
  of pending messages, and no unexplained missing unique messages after drain.
- [ ] Report sustainable capacity and any unmet latency/throughput target. Expand
  worker/pool/admission capacity only if measured downstream headroom justifies it,
  with bounded budgets and focused regression coverage.

Done when a reproducible report proves improvement without weakening delivery
invariants. Proxy replacement is a separate optional benchmark if HAProxy remains
a measured bottleneck after presence/reconnect fixes, CPU isolation, and accept/health-check correction.

## 8. Remove shared Redis client queueing from presence — priority P0

Depends on completed task 2 attribution and task 3 baseline; implement before
tuning admission capacity. Owners:
`apps/chatchat_tcp/lib/chatchat_tcp/application.ex`, `presence.ex`,
`presence_routing.ex`, and the existing Redis script/telemetry helpers.

Evidence: a single named Redix connection per TCP node handles node heartbeat,
session acquisition/renewal/release, and route lookup. Its mailbox reached
21k–56k messages in the message-producing run. The latest connection-only run
repeatedly observed mailbox growth, peaking at about 51k/node, with presence
closures near 2,259/s before any messages were submitted. Some snapshots returned
zero and others timed out; pressure recurs rather than remaining continuously high.
Redis average command execution was microseconds, unlike multi-second client
round trips. Treat shared client queueing and CPU scheduling as measured suspects,
not proof that Redis server capacity is unlimited.

- [ ] Give node heartbeats a dedicated supervised Redix connection so session
  traffic cannot queue ahead of liveness refreshes. Preserve startup failure,
  expiry, owner identity, and recovery behavior.
- [ ] Use a small bounded set of supervised Redix connections for session/route
  work, consistently selected by user. Reuse installed Redix and OTP supervision;
  avoid a new dependency or unbounded task/connection creation. Bound queued
  session work with explicit overload handling; keep renewals from being starved
  by acquisitions and retries. Preserve atomic
  Lua ownership checks, script-cache recovery, and owner-scoped renewal/release.
- [ ] Spread per-session renewal timers with bounded jitter, leaving enough margin
  for command timeout before lease expiry. Compute conservative deadlines and
  reject expired ownership; never relax authorization to hide disconnects.
- [ ] Extend existing diagnostics to expose bounded connection-role mailbox lengths
  and round-trip/failure metrics. The task 2 capture already matches registered
  names beginning with `ChatchatTcp.Redis`; retain that naming or update the filter,
  and verify every new role is observed within its 32-process bound. Keep labels
  fixed; no user/session/node IDs.
- [ ] Add focused tests for delayed session traffic with independent heartbeat,
  renew/release racing replacement ownership, Redis disconnect/recovery, script
  reload, timer bounds, and stable route/session behavior across TCP nodes.
- [ ] In the authorized isolated baseline, compare connection-only acquisition
  and renewal pressure first, then message traffic. Measure Redis mailbox growth,
  heartbeat freshness, session renewal tails, presence closures, authenticated
  sockets and delivery queue p95 at equal load and effective CPU allocation. Increase connections only with measured CPU
  and Redis headroom; do not merely move the backlog to another process.

Done when session traffic cannot starve node heartbeats, bounded connection queues
remain stable at the declared sustainable load, and lease-related disconnects fall
without weakening expiry, authentication, delivery deduplication, or recovery.
Apply changes only in a separate test deployment; task 2's temporary run has ended.
