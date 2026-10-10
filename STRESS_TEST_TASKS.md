# Stress-test bottleneck tasks

Evidence: [STRESS_TEST_FINDINGS.md](STRESS_TEST_FINDINGS.md).
Task numbers are stable references, not execution order. Keep HAProxy for this
work. Execution order is **finish 2 → 3 baseline → 8 → 6 → 4 → 5 → 7**.
Task 2's current evidence supports proposed fixes, but does not close its remaining
measurement gaps. Task 3 provides the controlled baseline required before applying
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
- [ ] Close missing client connection diagnostics and per-listener/source-port
  attribution; distinguish absent event series from proven zero events.
- [ ] Inspect proxy source-port/TIME_WAIT pressure, descriptor limits, listen
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

Remaining task 2 work, before applying bottleneck fixes:

- [ ] Improve bounded capture of listener occupancy and per-destination source-port
  usage; record truncation explicitly. Correlate snapshots with kernel counter deltas
  so namespace listen drops are not assumed to identify a particular listener.
- [ ] Capture Redis connection mailboxes and scheduler pressure repeatedly alongside
  lease failures, queue latency, and reconnect activity. Separate sustained queueing
  from transient spikes and identify unavailable observations.
- [ ] Capture existing client retry state read-only where possible. New client
  diagnostics require updated images in a separately authorized run; leave this gap
  explicit rather than restarting the current simulation.
- [ ] Produce a bounded attribution report distinguishing measured mechanisms,
  competing explanations, and unresolved limits. If a gap requires a fresh run,
  prepare capture support first and obtain the required run authorization.

Both TCP nodes had two schedulers and substantial run queues on a shared 12-CPU
host. PostgreSQL timeouts and a metrics flusher timeout were also observed.
The six client images still lack new connection diagnostics; rebuild them for the
next authorized run. Listener samples were truncated and kernel counters are
namespace-wide. Resource-limit inspection is partial; source-port exhaustion and
per-listener occupancy remain unresolved. No simulation was launched or modified
for this capture. Previous instrumentation tests and repository gates passed.

## 3. Remove load-generator CPU contention from the baseline — priority P1

Depends on tasks 1–2. Owns test deployment and load-generator setup.

- [ ] Document a repeatable run using separate generator compute, or measured CPU
  allocations with backend headroom. Capture effective options, not just Compose
  defaults, plus versions, replica counts, and resource limits.
- [ ] Record effective BEAM schedulers, normal run queues, CPU allocations, and
  HAProxy threads. Compare measured TCP scheduler settings with CPU available after
  reserving generator/proxy capacity; do not increase every service's CPU demand.
- [ ] Establish all connections first, then ramp traffic in bounded steps using
  the existing simulator. Keep receiver selection and cross-node traffic comparable.
- [ ] Record actual authenticated sockets separately from ready wrappers; measure
  unique messages queued/confirmed, confirmation latency, outstanding outbox work,
  and retries. Do not interpret attempt counters as unique-message success rates.
- [ ] Establish the largest sustainable load before raising admission limits.

Done when the baseline separates generator saturation from backend saturation and
reports throughput, latency, connection stability, and backlog slope per step.
More TCP replicas on an already saturated host do not count as added capacity.

## 4. Correct delivery deadline handling — priority P1

Depends on task 2; coordinate with task 8. Owners:
`apps/chatchat_tcp/lib/chatchat_tcp/message_delivery.ex` and
`apps/chatchat_broker/lib/chatchat_broker/storage/messages_store.ex`.

Evidence: queued work waits 4–5 seconds at p95 while scheduling delay is only
about 4 ms; database logs include checkout/connection timeouts. Trace existing
budget handling before editing; do not attribute all failures to PostgreSQL.

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

- [ ] Obtain bounded, per-listener accept-queue samples without dumping all
  established sockets. Record namespace listen-drop deltas, proxy CPU/thread use,
  backend sessions, connection failures, FDs, and source-port/TIME_WAIT pressure.
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

Evidence supports investigating the change: rapid presence disconnects,
falling authenticated sockets, high failed-attempt rates, and rising listen drops.
Use client diagnostics in the next run to quantify retry spacing. Owner:
`apps/chatchat_client/lib/chatchat_client.ex` and the existing simulator/socket flow.

- [ ] Extend the existing reconnect timer with bounded exponential backoff and
  jitter; reset on successful authentication. Keep one pending reconnect timer.
- [ ] Preserve outbox message identities, inbox deduplication, existing pings,
  and eventual reconnection. Reuse existing retry patterns where appropriate.
- [ ] Test repeated failures, jitter bounds, recovery/reset, and retained messages.

- [ ] Audit actual reconnect owners before changing behavior so simulator and
  socket retry loops do not multiply each other's attempts. Use existing connection
  diagnostics to measure reconnect rates; rebuild client images for the next run.

Done when an outage produces bounded, spread retries, no concurrent duplicate
connection attempts per client, and recovery with pending messages intact. Compare
presence closures and listen-drop deltas at the same offered traffic.

## 7. Validate recovery and sustainable capacity — priority P1

Depends on completed applicable fixes above.

- [ ] Run focused tests first; use dedicated PostgreSQL and isolated Redis for
  integration tests and migrate the test database before database tests.
- [ ] For cross-app changes run `mix test`; complete repository gates:
  `mix format --check-formatted`, `mix credo --min-priority high`,
  `MIX_ENV=test mix compile --warnings-as-errors`.
- [ ] In the isolated load run, compare identical load/resource steps before and
  after changes; include backend outage/recovery and a drain phase after traffic ends.
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
21k–56k messages while presence failures drove approximately 1,819 closures/s.
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
  and round-trip/failure metrics. Update task 2's connection-name filter so new
  Redis connections are observed. Keep labels fixed; no user/session/node IDs.
- [ ] Add focused tests for delayed session traffic with independent heartbeat,
  renew/release racing replacement ownership, Redis disconnect/recovery, script
  reload, timer bounds, and stable route/session behavior across TCP nodes.
- [ ] In the authorized isolated baseline, compare Redis mailbox growth, heartbeat
  freshness, session renewal tails, presence closures, authenticated sockets, and
  delivery queue p95 at equal load. Increase connections only with measured CPU
  and Redis headroom; do not merely move the backlog to another process.

Done when session traffic cannot starve node heartbeats, bounded connection queues
remain stable at the declared sustainable load, and lease-related disconnects fall
without weakening expiry, authentication, delivery deduplication, or recovery.
Do not patch or restart the current simulation to apply this task.
