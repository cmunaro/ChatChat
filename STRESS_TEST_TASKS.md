# Stress-test bottleneck tasks

Evidence: [STRESS_TEST_FINDINGS.md](STRESS_TEST_FINDINGS.md).
Task numbers are stable references, not execution order. **Tasks 1–10 are complete
at the tested scope.** Keep HAProxy. The task 10 build sustained 80,000
authenticated sockets and 803.9 sender confirmations/s, with steady-state p95
≤50 ms. After a 30-second single-backend pause, all 263,619 admitted identities
reconciled with confirmations and receiver inboxes; pending work was zero.
Continuous 80k socket observations returned about 100.05 seconds after resume.

This establishes a tested operating point, not a capacity ceiling or recovery SLA.
Higher throughput, longer soak duration, and storage/multi-node failures remain
unvalidated. Next priorities are **11 → 12**; task 9 supports reliable
measurement for the other follow-ups. These are planning tasks, not authorization
to launch new load runs or failure injection. Use separately authorized isolated
deployments; never reset shared data.

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
unproven for this historical run. Task 7 subsequently completed full receiver
reconciliation and outage/recovery testing on the corrected build.

## 4. Correct delivery deadline handling — priority P1

Depends on task 2; coordinate with task 8. Owners:
`apps/chatchat_tcp/lib/chatchat_tcp/message_delivery.ex` and
`apps/chatchat_broker/lib/chatchat_broker/storage/messages_store.ex`.

Evidence from the earlier message-producing run: queue p95 rose from 4–5 seconds
toward the 10-second histogram boundary while initial scheduling delay was about
4 ms. Final persistence p95 was 94–121 ms. Database logs include checkout/connection
timeouts. The historical task 2 setup-only run submitted zero messages, so its elevated Ecto
latencies are not delivery-transaction measurements. Trace budget handling before
editing; do not attribute all failures to PostgreSQL or infer the tail above the
histogram boundary.

- [x] Recompute remaining deadline inside the worker when it begins; do not start
  a new database write after the sender attempt deadline has expired.
- [x] Verify installed Ecto/DBConnection timeout semantics across checkout,
  transaction, and commit; correct budget propagation where evidence shows an error.
- [x] Verify successful commit acknowledgement remains independent of a slow
  post-commit Redis wakeup. Preserve bounded worker ownership and late-commit recovery.
- [x] Add focused coverage for delayed scheduling, pool timeout, ambiguous commit,
  confirmed late commit, and failed wakeup, reusing existing recovery tests.

Done when expired queued work avoids new writes, committed rows remain recoverable,
and `ok` still requires a valid receiver receipt or confirmed PostgreSQL commit.
Keep stable identities, deduplication, receiver-scoped ACKs, and admission accounting.
Do not fix this by merely lengthening timeouts or expanding queues.

Implementation and focused coverage for task 4 are complete. One absolute deadline
now reaches the persistence worker, checkout, queries and transaction. Busy pool
checkout refuses rather than queuing beyond the budget. A committed row remains
recoverable after a late sender failure or failed Redis wakeup.

## 5. Stabilize proxy health checks and accept capacity — priority P1

Depends on task 3 baseline and tasks 8/6 reducing reconnect pressure. Owner: `observability/haproxy.cfg`, with TCP HTTP health
handling only if the current endpoint is demonstrably expensive or unsuitable.

- [x] Obtain initial bounded, per-listener accept-queue and source-port samples.
  The task 2 follow-up measured TCP 4040 queues at 4097/4095 against backlogs of
  4096, with 2,982,927 namespace listen drops. Sampled FDs and destination port
  counts remained below their limits; this does not exclude brief unsampled pressure.
- [x] Repeat these measurements in task 3's stable connection-only and traffic
  steps, then after tasks 8/6. Use the existing native socket capture; correlate
  probe timestamps and kernel deltas without assigning every namespace drop to
  one listener. Do not raise FD/port limits without evidence of exhaustion.
- [x] After reducing reconnect pressure, compare proxy thread/backlog settings at
  equal offered load and CPU budget. The historical overloaded run reached about 175% proxy CPU and
  sharply increasing namespace listen drops; larger backlogs alone do not add capacity.
- [x] Measure healthy check latency under the intended resource allocation.
- [x] Set explicit check timeout and failure/recovery hysteresis from that evidence;
  document the resulting bounded outage-detection window.
- [x] Keep checks lightweight and meaningful for accepting traffic. Add a dedicated
  endpoint only if needed; preserve `/metrics` for observability.
- [x] Validate healthy-but-busy, unavailable, and recovered backends independently.

Done when representative healthy load avoids false removal while a failed backend
is removed and restored within the documented bounds. Longer checks alone do not
establish improved delivery capacity.


Completed with an explicit two-second check response timeout and existing
five-second connect timeout, two-second interval, fall 3/rise 2. `/metrics` remains
the health endpoint. Same-image, fixed-resource one-/two-thread trials each
reconciled their complete populations. Retain two threads: one thread increased
recovery listen-drop pressure and recovered sockets later in that paired trial;
its lower stable mean latency does not establish an overall improvement.

At 1k clients, DNS removal produced MAINT rather than testing failure hysteresis;
a DNS-preserving pause reached DOWN within 15 seconds and UP within five seconds.
Stable 80k traffic stayed healthy. The final 80k pause reached DOWN by the
20-second sample, but 11 exporter samples failed during recovery. Exact health
transition bounds under reconnect bursts remain unresolved in task 9. Accept
queues still saturate during recovery; no FD, port, backlog or admission limits
were increased.

## 6. Bound reconnect amplification — priority P0

Depends on completed task 2 attribution and task 3 baseline.

Historical task 2 evidence quantified amplification before message traffic: about 2,259/s
presence closures at peak, 105,004 client ping failures, 62,467 peer closes,
879,881 reconnect attempts and 714,121 connect/authenticate failures in the final
successful shard observations. Counts include asynchronous/in-flight attempts.
Initialized intentional-disconnect counters were zero; missing TCP event series
remain unknown. Retry spacing was unmeasured then; implementation and population verification
are recorded below. Owner:
`apps/chatchat_client/lib/chatchat_client.ex` and the existing simulator/socket flow.

- [x] Extend the existing reconnect timer with bounded exponential backoff and
  jitter; reset on successful authentication. Keep one pending reconnect timer.
- [x] Preserve outbox message identities, inbox deduplication, existing pings,
  and eventual reconnection. Reuse existing retry patterns where appropriate.
- [x] Test repeated failures, jitter bounds, recovery/reset, and retained messages.

- [x] Identify the existing fixed one-second client reconnect and wrapper restart
  owners; rebuilt client diagnostics were captured in task 2.
- [x] Trace their interaction on startup failure, socket loss and client-process
  death before editing. Ensure wrapper restart and client reconnect cannot create
  concurrent duplicate attempts; bound startup/recreation retries as well as
  reconnects if the audit shows they amplify pressure.
- [x] Measure retry intervals and aggregate attempts in bounded outage/recovery
  tests. Convenience samples of 16 client states are not proof of population-wide
  retry spacing. Rebuild changed client images for the comparison run.

Done when an outage produces bounded, spread retries, no concurrent duplicate
connection attempts per client, and recovery with pending messages intact. Compare
presence closures, ping failures, connect/authenticate failures and listen-drop
deltas at equal connection ramp, traffic and CPU allocation.


Completed with one tagged reconnect timer and jittered exponential backoff:
0.8–1 second initially, capped at 24–30 seconds, reset after authentication.
Socket reconnect preserves existing message stores; wrapper recreation occurs
only after client-process death. Focused timer/store tests and a 200-client outage
test verify retry bounds and aggregate attempts. Client-process death does not
provide durable simulator-store recovery; task 12 records that separate scope.

Pause testing exposed a transient safety hold: `presence_unavailable` now triggers
reconnect without suspending retries. Malformed/uncorrelated response holds remain
intact, and existing holds are never automatically cleared. The corrected final
run reported zero protocol suspensions/rejections and fully drained. Recovery
still takes about 191 seconds at 80k; reducing aggregate pressure belongs to task 10.

## 7. Validate recovery and sustainable capacity — priority P1

Depends on completed applicable fixes above.

- [x] Run focused tests first; use dedicated PostgreSQL and isolated Redis for
  integration tests and migrate the test database before database tests.
- [x] For cross-app changes run `mix test`; complete repository gates:
  `mix format --check-formatted`, `mix credo --min-priority high`,
  `MIX_ENV=test mix compile --warnings-as-errors`.
- [x] In the isolated load run, compare identical load/resource steps before and
  after changes. Validate connection-only setup first, then traffic, backend
  outage/recovery and a drain phase. Stop failed setup at its declared deadline;
  a failed all-ready barrier cannot establish message throughput or recovery.
- [x] Save final counters and recovery/drain evidence before stopping writers.
  Flush application tables in the dedicated stress PostgreSQL database, verify
  empty counts, and remove temporary deployment resources. Never flush shared data.
- [x] Confirm bounded queues and memory, fresh metrics, stable sockets, recovery
  of pending messages, and no unexplained missing unique messages after drain.
- [x] Report sustainable capacity and any unmet latency/throughput target. Expand
  worker/pool/admission capacity only if measured downstream headroom justifies it,
  with bounded budgets and focused regression coverage.

Done when a reproducible report proves improvement without weakening delivery
invariants. Proxy replacement is a separate optional benchmark if HAProxy remains
a measured bottleneck after presence/reconnect fixes, CPU isolation, and accept/health-check correction.


Final corrected-build validation: 80k stable sockets over a 120-second hold,
797.1 confirmations/s, steady-state p95 ≤50 ms and mean 6.9 ms. A 30-second
single-node pause, 180-second recovery phase and 120-second drain reconciled
**240,695 admissions = confirmations = receiver inbox identities**. All 80k
receivers were scanned; unavailable/unscanned, outbox, inflight and PostgreSQL
pending counts were zero. Continuous exact 80k socket observations returned
190.5 seconds after resume, during early drain; recovery latency exceeded the
10-second histogram ceiling. Temporary socket counts above 80k include overlapping
old/new handlers, not additional unique-user capacity.

Recovery listen-drop delta was 423,774, proxy queue occupancy reached 4097 against
a 4096 backlog, and some exporter samples were unavailable. Largest sampled TCP
memory was 6.10 GiB of 8 GiB, with zero OOM events. These observations establish
successful eventual recovery, not fast recovery or freedom from saturation.
147 umbrella tests, format, high-priority Credo, warnings-as-errors compilation,
and 17 Python capture/baseline tests passed. Dedicated application data cleanup
was verified empty and temporary resources removed. See the final controlled
validation in [the findings](STRESS_TEST_FINDINGS.md) and
[the baseline procedure](observability/BASELINE.md). Tasks 9–12 own remaining scope.

## 8. Remove shared Redis client queueing from presence — priority P0

Depends on completed task 2 attribution and task 3 baseline; implement before
tuning admission capacity. Owners:
`apps/chatchat_tcp/lib/chatchat_tcp/application.ex`, `presence.ex`,
`presence_routing.ex`, and the existing Redis script/telemetry helpers.

Historical evidence: a single named Redix connection per TCP node handled node heartbeat,
session acquisition/renewal/release, and route lookup. Its mailbox reached
21k–56k messages in the message-producing run. The task 2 connection-only run
repeatedly observed mailbox growth, peaking at about 51k/node, with presence
closures near 2,259/s before any messages were submitted. Some snapshots returned
zero and others timed out; pressure recurs rather than remaining continuously high.
Redis average command execution was microseconds, unlike multi-second client
round trips. Treat shared client queueing and CPU scheduling as measured suspects,
not proof that Redis server capacity is unlimited.

- [x] Give node heartbeats a dedicated supervised Redix connection so session
  traffic cannot queue ahead of liveness refreshes. Preserve startup failure,
  expiry, owner identity, and recovery behavior.
- [x] Use a small bounded set of supervised Redix connections for session/route
  work, consistently selected by user. Reuse installed Redix and OTP supervision;
  avoid a new dependency or unbounded task/connection creation. Bound queued
  session work with explicit overload handling; keep renewals from being starved
  by acquisitions and retries. Preserve atomic
  Lua ownership checks, script-cache recovery, and owner-scoped renewal/release.
- [x] Spread per-session renewal timers with bounded jitter, leaving enough margin
  for command timeout before lease expiry. Compute conservative deadlines and
  reject expired ownership; never relax authorization to hide disconnects.
- [x] Extend existing diagnostics to expose bounded connection-role mailbox lengths
  and round-trip/failure metrics. The task 2 capture already matches registered
  names beginning with `ChatchatTcp.Redis`; retain that naming or update the filter,
  and verify every new role is observed within its 32-process bound. Keep labels
  fixed; no user/session/node IDs.
- [x] Add focused tests for delayed session traffic with independent heartbeat,
  renew/release racing replacement ownership, Redis disconnect/recovery, script
  reload, timer bounds, and stable route/session behavior across TCP nodes.
- [x] In the authorized isolated baseline, compare connection-only acquisition
  and renewal pressure first, then message traffic. Measure Redis mailbox growth,
  heartbeat freshness, session renewal tails, presence closures, authenticated
  sockets and delivery queue p95 at equal load and effective CPU allocation. Increase connections only with measured CPU
  and Redis headroom; do not merely move the backlog to another process.

Done when session traffic cannot starve node heartbeats, bounded connection queues
remain stable at the declared sustainable load, and lease-related disconnects fall
without weakening expiry, authentication, delivery deduplication, or recovery.
Apply changes only in a separate test deployment; task 2's temporary run has ended.


Implemented with nine Redis connections per TCP node: one heartbeat, four
session/route lanes and four renewal lanes. Each lane reserves at most 512
operations under a shared five-second budget; timeout/abandonment discards its
socket. Renewal jitter is 8–12 seconds with conservative expiry unchanged.
Fixed-role telemetry and focused ownership/recovery tests cover the new lanes.
In the final stable traffic phase, mailbox peak was 9 and reservation peaks were
2 session/17 renewal. Recovery peaks were 491/300 mailbox messages and 498/445
session/renewal reservations; heartbeat mailbox stayed zero. Queues are bounded,
but recovery approaches lane capacity. Higher throughput remains task 11.

## 9. Preserve health visibility during reconnect bursts — priority P1

Depends on task 5. Owners: existing HAProxy capture/exporter workflow in
`observability/` and affected dashboards.

- [x] Identify why 11 final-run exporter samples failed; distinguish scrape timeout,
  exporter/proxy availability and missing capture data using bounded observations.
- [x] Capture backend UP/DOWN/MAINT transitions and check duration alongside accept
  queues and kernel deltas during an isolated repeat. Retain timestamps and explicit
  unavailable samples; never interpret absence as healthy or down.
- [x] Improve the existing capture path where measured failures justify it. Keep
  probes bounded and avoid adding a health endpoint without demonstrated need.

Done when the report can measure outage detection/restoration during reconnect
pressure, or explicitly bound the remaining observation gap. No exact transition
SLA is claimed from sparse samples.

Historical evidence reviewed: all 11 gaps had successful capture queries with
HAProxy `up=0`, identifying failed exporter scrapes rather than capture failure.
The saved run lacks scrape errors, so timeout versus exporter availability remains
unresolved. Capture now saves bounded scrape duration/source timestamps and
sanitized target failure categories. Fifteen capture and four baseline tests pass.
The subsequently authorized isolated repeat completed task 9: seven recovery
observations recorded five-second HAProxy scrape timeouts, with successful target
API capture. DOWN was observed by 20 seconds after pause; the first restored UP
observation was 50 seconds after resume, following missing samples. Exact restoration
time remains bounded by the observation gap, not a demonstrated transition SLA.
All 238,234 identities reconciled across admissions, confirmations and receiver
inboxes; final pending work was zero. Dedicated data cleanup was verified empty
and temporary resources removed. Task 10 proceeds with rebuilt-client timing
instrumentation and an initial 120-second socket-recovery target.

## 10. Reduce reconnect pressure and recovery time — priority P1

Depends on task 9. Owners: existing client retry/startup flow, TCP
presence/admission, and HAProxy configuration where measurements justify changes.

- [x] Attribute the approximately 191-second recovery tail to attempt scheduling,
  connect/authentication, accept queues, presence operations and lease replacement.
  Measure first/repeated attempt distributions and operation latency, not just
  configured retry delays or aggregate socket counts.
- [x] Record the recovery target before judging a change. Compare a bounded ramp,
  retry or admission adjustment only where attribution supports it, with identical
  images/resources, 80k population, traffic and pause duration.
- [x] Preserve one attempt per client, bounded queues, authenticated ownership,
  conservative leases and retained message identities. Do not raise FD, port,
  backlog, worker or pool limits without measured exhaustion/downstream headroom.
- [x] Reconcile all admissions, confirmations and inbox identities after drain;
  report recovery time, latency tail, listen-drop deltas and observation gaps.

Done when a repeatable comparison meets the recorded recovery target and reduces
measured pressure without weakening delivery invariants. The current result is
successful eventual recovery, not an established recovery SLA.

Completed at the declared scope: first-wait widening and exponential local
admission deferral failed and were replaced. Simulator reconnects now share the
existing creation-concurrency limit through a bounded local ETS slot pool,
borrow idle slots, and retry capacity deferral after 1.6–2 seconds without changing
network failure backoff. No waiting socket operations or coordinator mailbox are
introduced; exception/killed-owner recovery and identity retention are covered.

The paired 80k/0.01/30-second pause comparison retained every resource limit and
all non-client images. Stable traffic measured 803.9 confirmations/s, mean 5.4 ms,
p95 ≤50 ms. Continuous exact 80k sockets returned at 100.05 seconds, meeting the
120-second experimental target versus 120.05 seconds in the instrumented control.
Recorded network failures fell from 21,966 to zero, recovery proxy namespace
listen-drop delta from 379,264 to zero, and exporter failure observations from
seven to one. **263,619 admissions = confirmations = receiver inbox identities**
reconciled across all 80k clients, with zero final pending/unavailable/unscanned
work. Dedicated data cleanup and resource removal passed. One paired run does
not establish statistical confidence or a production SLA; outage confirmation
p95 still exceeds ten seconds. Task 11 owns longer duration and throughput scope.

## 11. Locate sustainable throughput and validate duration — priority P1 — complete

Depends on task 9; use task 10's final configuration if it changes behavior.
Owners: `observability/run_baseline.py`, baseline procedure and findings.

- [x] Test intermediate offered rates between the proven approximately 800/s and
  historical unsafe 4,000/s using current corrected images and fixed resources.
  Keep the 80k/0.01 baseline as the comparison anchor; record actual confirmations.
- [x] Declare bounded steps, hold durations, safety-stop thresholds and drain
  deadlines before running. Measure backlog slope, latency, CPU, lane reservations
  and memory; a short successful burst does not establish sustainable throughput.
- [x] Fully reconcile accepted runs after drain; record failed-run unavailable
  scans and pending work as unresolved limitations, without a no-loss claim.
- [x] Validate five minutes at the chosen 1,200/s operating point. If connection capacity
  is investigated, use separate bounded population steps with an all-ready deadline;
  80k remains the largest tested stable population, not the exact ceiling.

Done when the report brackets sustainable throughput at declared resources and
latency/duration criteria, with complete reconciliation. The corrected build has
not established 4,000/s capacity; increase limits only with measured headroom.

Task 11 is **complete for 1,200/s at 80k users for five minutes** at the
recorded fixed resources. The user revised the acceptance duration from 15 minutes
to five minutes; reconciliation acceptance applies to accepted runs. Existing
300-second holds measured 797.3/s and 1,201.1/s, p95 ≤50 ms, with complete 80k
receiver scans and 600,374 cumulative identities reconciled after the 1,200/s run.
No additional load run was needed.

Unresolved limitations remain: the second drain briefly lost sockets; the failed
1,600/s attempt hit shared presence Redis timeouts and did not reconcile within
120 seconds. No no-loss claim applies to that failed population. A fresh same-image
1,200/s duration trial stopped at about 13 minutes at generator memory 90.38% of
4 GiB, before its original 15-minute target; all 937,565 identities reconciled.
Neither result establishes operation beyond five minutes or an exact capacity
ceiling. Higher rates were skipped and both dedicated deployments were cleaned up.
See task 11 findings for failed-drain counts and observation limits.

Runner gates and seven focused baseline plus 15 capture tests are complete;
no application behavior or resource limits changed. Task 12 remains separate.

## 12. Extend bounded failure coverage — priority P2

Depends on tasks 9–11 for a declared operating point. Owners: responsible client,
TCP and broker layers plus the isolated baseline runner.

- [x] Define separate bounded scenarios for client-process death, Redis outage,
  PostgreSQL outage and simultaneous multi-node failure, including expected
  guarantees, safety stops and recovery/drain deadlines before execution.
- [x] Distinguish in-memory simulator-store loss on client-process death from
  production delivery guarantees. Document the boundary; add durable client storage
  only if a requirement calls for it.
- [x] At responsible layers add focused regression coverage for any discovered
  defect; preserve atomic transitions, recoverable persistence claims, receiver
  ACK scope and cleanup only after PostgreSQL commit.
- [ ] Run authorized scenarios in dedicated services and reconcile identities,
  retries and pending work, recording unavailable evidence and limitations.

Done when each selected failure scenario has a reproducible outcome and explicit
recovery/data guarantees. The completed single-backend pause kept Redis and
PostgreSQL alive and does not validate these scenarios.


Task 12 is **partially complete**: bounded contracts, focused recovery tests and
mocked runner orchestration are implemented. Infrastructure trials remain deferred;
no users were provisioned and no 80k simulation ran in this iteration. See the
[task 12 procedure](observability/BASELINE.md#task-12-bounded-failure-scenarios)
and findings. Focused tests and mocks do not establish multi-node recovery.
