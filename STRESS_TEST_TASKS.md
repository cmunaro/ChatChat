# Stress-test bottleneck tasks

Evidence: [STRESS_TEST_FINDINGS.md](STRESS_TEST_FINDINGS.md).
Tasks are ordered by dependency, not assumed root cause. Keep HAProxy for this
work. Do not stop, restart, patch, or reconfigure the running simulation. Load
runs and failure injection below belong in a separately authorized, isolated run.

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
Credo, and warnings-as-errors compilation passed. Changes are not deployed to the
running services.

## 2. Identify where capacity is spent — priority P0

Depends on task 1.

- [ ] Extend existing telemetry at its owning layers to distinguish worker queue
  delay, task scheduling delay, route lookup, direct receipt wait, database pool
  wait/transaction, and post-commit wakeup. Reuse existing Ecto timing metrics.
- [ ] Count connection closure/reconnect reasons at the TCP and client layers;
  distinguish ping failure, presence lease failure, idle timeout, socket error,
  and intentional simulated disconnect.
- [ ] Correlate these with HAProxy health transitions, connection errors/aborts,
  CPU, scheduler queues, delivery reservations, and retry rates.
- [ ] Inspect proxy source-port/TIME_WAIT pressure, descriptor limits, listen
  backlog, and database/Redis latency before changing resource limits.
- [ ] Keep labels bounded: no user IDs, message IDs, payloads, or tokens.

Done when a report attributes the dominant queue delay and connection churn to
measured mechanisms. A shared CPU bottleneck remains a hypothesis until isolated.

## 3. Remove load-generator CPU contention from the baseline — priority P1

Depends on tasks 1–2. Owns test deployment and load-generator setup.

- [ ] Document a repeatable run using separate generator compute, or measured CPU
  allocations with backend headroom. Capture effective options, not just Compose
  defaults, plus versions, replica counts, and resource limits.
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

Depends on task 2. Owners:
`apps/chatchat_tcp/lib/chatchat_tcp/message_delivery.ex` and
`apps/chatchat_broker/lib/chatchat_broker/storage/messages_store.ex`.

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

## 5. Stabilize backend health checks — priority P1

Depends on tasks 2–3. Owner: `observability/haproxy.cfg`, with TCP HTTP health
handling only if the current endpoint is demonstrably expensive or unsuitable.

- [ ] Measure healthy check latency under the intended resource allocation.
- [ ] Set explicit check timeout and failure/recovery hysteresis from that evidence;
  document the resulting bounded outage-detection window.
- [ ] Keep checks lightweight and meaningful for accepting traffic. Add a dedicated
  endpoint only if needed; preserve `/metrics` for observability.
- [ ] Validate healthy-but-busy, unavailable, and recovered backends independently.

Done when representative healthy load avoids false removal while a failed backend
is removed and restored within the documented bounds. Longer checks alone do not
establish improved delivery capacity.

## 6. Bound reconnect amplification — priority P1, evidence-gated

Depends on task 2 showing clustered reconnects. Owner:
`apps/chatchat_client/lib/chatchat_client.ex`.

- [ ] Extend the existing reconnect timer with bounded exponential backoff and
  jitter; reset on successful authentication. Keep one pending reconnect timer.
- [ ] Preserve outbox message identities, inbox deduplication, existing pings,
  and eventual reconnection. Reuse existing retry patterns where appropriate.
- [ ] Test repeated failures, jitter bounds, recovery/reset, and retained messages.

Done when an outage produces bounded, spread retries and clients recover with
pending messages intact. If measurements show no retry clustering, record that
result and skip the behavior change.

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
a measured bottleneck after CPU isolation and health-check correction.
