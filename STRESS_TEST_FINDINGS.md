# Running stress test: findings and proposed fixes

Observed on 2026-10-10 during a read-only investigation of the running Docker
simulation. Samples were collected at different times, not as one atomic snapshot.
The investigation did not stop, restart, reconfigure, or patch the simulation.
These findings describe that observation window, not current live values.

## Run and outcome

- Six load generators, each with 20,000 running wrappers: 120,000 simulated clients.
- Runtime options: send probability 0.01/second, disconnect probability
  0.001/second, activity duration 900 seconds. These differ from Compose defaults.
- All six simulations reported `phase: :running` and 20,000 ready clients.
  Ready clients count simulation membership, not currently connected sockets.
- Approximate combined counters: 279,630 queued messages, 26,452 confirmed
  attempts, 683,356 failed attempts, 664 submission failures, zero rejections.
  Counters include retries; they do not establish unique-message loss or a
  unique-message success percentage.
- One shard recorded 20 startup authentication failures (`:closed`) before
  reaching its requested client count.

## Evidence and interpretation

### 1. Delivery capacity is saturated

Both TCP nodes reached or approached the 409 active-attempt limit. Samples showed
354–372 waiting attempts and all 32 routing/fallback/delete workers occupied per
node. A later two-minute rate sample showed approximately 54.5 capacity failures,
7.0 unavailable failures, and 1.6 fallback successes per second across both nodes;
no direct-receipt successes appeared in that sample.

The system is rejecting or timing out work under pressure. The bounded admission
limits protect resources; raising them alone could increase latency and memory
without improving throughput.

### 2. CPU contention and connection churn reinforce overload

Docker has 12 CPUs. Each generator consumed approximately one core, HAProxy 1.8
cores, and each TCP node 1.6 cores, leaving little headroom for other services.
TCP normal scheduler queues reached 2,860 and 424 runnable processes in one sample.

HAProxy logged both backends down simultaneously after roughly two-second Layer4
health-check timeouts, followed by recovery. It explicitly reported no available
server. Cumulative backend connection errors were 146,126 and server aborts 47,134
in one sample; a later server-abort rate was approximately 248/second. Connection
errors were zero/second in that later window, so cumulative errors must not be
presented as a sustained current rate.

CPU contention is a strong contributing hypothesis, not an isolated proven root
cause. Client ping timeouts, presence renewal failures, socket/port pressure, and
backend health flapping need correlated timing before attributing all disconnects.
Clients already send pings; adding another heartbeat is not the first fix.

### 3. Connection gauges can hide the collapse

Prometheus reported approximately 119,457 authenticated connections. Later live
RPC samples found 16,431 connections on one node and 5,817 on the other. These
samples were sequential, so their sum is not an exact simultaneous count.

`ChatchatTcp.PromEx.MessagePlugin.execute_poll/0` synchronously obtains delivery
snapshots and a PostgreSQL pending-row count before emitting the entire snapshot,
including the connection gauge. A blocked or failed dependency can prevent fresh
connection values from being published. Stale polling is the leading explanation
for the discrepancy; check scrape timestamps and poll completion to confirm it.

### 4. Persistence deadlines expire under pressure

TCP logs contained `DBConnection.ConnectionError` timeouts during PostgreSQL
commit and while the task was executing `Presence.route/1` for a receiver wakeup.
Some reported transaction allowances were only 69–75 ms.

`MessageDelivery.start_job/3` derives a database timeout from the remaining
attempt deadline before launching the task. Scheduling and pool contention can
consume that budget. `MessagesStore.insert_pending/2` uses a transaction for
idempotent insert and immutable-content validation. Wakeup runs after the insert
returns; a wakeup stack trace alone does not prove Redis ran inside the transaction
or that a committed message was lost.

Pending-row gauges showed approximately 1,300 rows. Both nodes observe the same
database: do not sum those values. Their freshness and growth were not verified.

## Proposed fixes, in order

### 1. Make observability independent of delivery progress

In `apps/chatchat_tcp/lib/chatchat_tcp/prom_ex/message_plugin.ex`, publish the
local connection count independently of delivery coordinator calls and database
queries. Keep existing public metric names. Bound slower snapshot collection and
expose last successful collection time or collection failures so dashboards can
identify stale values. Avoid overlapping poll tasks or unbounded retries.

Acceptance: with a delivery coordinator or database deliberately slow in an
isolated test, connection metrics continue updating and stale dependency metrics
are identifiable. Verify normal collection still produces the existing gauges.

### 2. Separate load-generation cost from backend capacity

For the next explicitly authorized run, place generators on separate compute, or
reserve measured CPU capacity for TCP/HAProxy and reduce offered load until
scheduler queues and retries stabilize. Ramp traffic gradually after connections
are established. Measure unique-message confirmation latency, outstanding outbox
entries, connection churn, and CPU alongside attempt rates.

Acceptance: sustain the intended connection count and traffic rate with bounded
queues and stable confirmation throughput. Increase admission limits only after
showing unused downstream capacity. Do not change this running simulation.

### 3. Stabilize health checks without masking outages

Review `observability/haproxy.cfg` against observed scheduling delays. Use an
explicit, measured check timeout and hysteresis appropriate to the deployment.
Keep health handling lightweight; if a dedicated endpoint is needed, it should
verify the availability required to accept traffic without collecting expensive
metrics. Do not treat longer timeouts as a throughput fix.

Acceptance: under representative CPU pressure, healthy nodes avoid false removal;
a genuinely unavailable node is still removed within an agreed bounded interval.
Correlate health transitions with CPU queues and connection failures.

### 4. Trace and correct deadline handling at the owning layers

Instrument task scheduling delay, routing time, database pool wait, transaction
time, and post-commit wakeup time in the delivery flow. Recompute remaining budget
when the worker actually begins and avoid starting writes after the attempt has
expired. Confirm how Ecto/DBConnection apply the timeout across the transaction
before changing it. Keep late-commit recovery and post-commit wakeup intact.

Acceptance: focused tests cover worker scheduling delay, pool timeout, ambiguous
commit, confirmed late commit, and failed wakeup. A committed pending message
remains recoverable; `ok` still requires a receiver receipt or confirmed commit.
Do not simply increase the eight-second result deadline or database timeouts.

### 5. Reduce reconnect amplification only where measured

Record disconnect reasons and reconnect attempts. If correlated retries form a
storm, extend the existing reconnect policy in
`apps/chatchat_client/lib/chatchat_client.ex` with bounded exponential backoff and
jitter, resetting after successful authentication. Preserve outbox identities,
deduplication, ping behavior, and eventual reconnection.

Acceptance: focused tests show bounded retry frequency during outage, retries
spread over time, and recovery with pending messages preserved. Also inspect
HAProxy socket/source-port pressure before attributing all failures to CPU.

## Verification and limits

Evidence came from container logs, Docker CPU/memory statistics, Prometheus instant
queries and two-minute rates, live simulation status, and live node RPC queries.
Relevant delivery, presence, client ping/reconnect, storage, and metric collection
code was inspected. No behavior changes were implemented and no runtime tests were
run. This document proposes follow-up work; it does not claim the overload is fixed
or prove message loss, database corruption, or one exclusive root cause.

## Dashboard audit during the subsequent run

The TCP exporters and web/HAProxy scrapes were healthy. Both running TCP images
lacked `ChatchatTcp.PromEx.RuntimeCollector` and `ChatchatTcp.Diagnostics` (verified
with read-only release RPC). The bind-mounted dashboard was newer than the images:
its freshness filters removed legacy gauges, and task 2 diagnostic series did not
exist. Successful scrapes alone cannot establish legacy collector freshness.
Legacy connection readings on both nodes initially duplicated the cluster count;
adding them would double-count clients. Other legacy readings can freeze under
load. Sender-result and database query series had no live observations at the audit;
web observations were only unknown routes, deliberately excluded by HTTP charts.

The dashboard now labels missing collectors explicitly, provides legacy readings
per exporter with a freshness warning, and shows live HAProxy backend socket totals.
The backend chart filters out unused HAProxy server slots (100 slots were previously
shown for two active nodes). The datasource now declares the five-second scrape
interval. Dashboard and datasource provisioning were reloaded in Grafana only;
TCP nodes and load generators were not restarted. Live queries confirmed the new
panels returned values and identified all eight missing source collectors.

Freshness-protected runtime totals and new diagnostics remain unavailable until
application images containing tasks 1 and 2 are rebuilt and deployed for a future
run. Do not treat legacy values as validated measurements or missing events as
zero. Synthetic promtool coverage verifies legacy deployment detection, exclusion
of modern exporters from the legacy view, active HAProxy slots, and existing
fresh/stale/failure behavior.

## Instrumented long-running run: 18:04–18:05 UTC

Read-only capture on 2026-10-10; raw samples and capture metadata are in
`/tmp/chatchat-live-performance-20261010/`. The four scheduled samples span
45 seconds within a 60-second capture. No containers, simulation settings, or
resource limits were changed. This is a subsequent deployment: release RPC now
confirms the TCP freshness collector is loaded and task 2 metrics are emitted.
The six client images still lack connection diagnostics.

### Observed degradation

- All six shards reported running with 20,000 ready clients each. This is 120,000
  simulation members, not 120,000 authenticated sockets.
- Reported local authenticated connections fell from 55,920 to 26,369 in 45 seconds.
  Scrapes are not atomic; one intermediate sample lacked one node's connection gauge.
- Combined client counters increased by 45,695 queued messages, 1,721 confirmed
  attempts, 63,028 failed attempts, and 171 submission failures: approximately
  1,015 queued/s, 38 confirmed/s, and 1,401 failed attempts/s. Attempts include retries;
  these counters cannot establish a unique-message loss percentage.
- Both nodes reported 409 active attempts, 377 waiting attempts, and 32 workers.
  Queue p95 was approximately 4.25–4.97 seconds; scheduling p95 was 3.6–4.3 ms.
  Routing p95 was 88–95 ms and fallback persistence p95 was 55–71 ms.
- Near the last sample, presence-unavailable disconnects totaled approximately
  1,819/s across both nodes. Authentication timeouts and rejections also occurred.
- Read-only process snapshots found 21,193 queued messages in TCP2's shared Redix
  process and 56,130 in TCP1's. Delivery coordinator mailboxes contained hundreds
  to thousands of messages; both TCP1 metric snapshot calls timed out at one second.
- Redis client script round-trip p95 was approximately 4.6–6.5 seconds. Redis INFO
  showed lifetime average EVALSHA execution of 6.55 microseconds and GET execution
  of 0.59 microseconds, no evictions, and no rejected connections. These averages do
  not rule out transient Redis stalls, but strongly distinguish server execution
  from the observed client/runtime queueing.
- Each TCP BEAM had two online schedulers despite 12 available CPUs. Normal run
  queues were 31 and 81. All load generators, TCP nodes, and HAProxy share that host;
  simply increasing every process's CPU allocation would introduce more contention.
- HAProxy namespace ListenDrops/ListenOverflows increased by 1,058,995; TCP node
  increases were 65,222 and 63,340. These are cumulative kernel counters, count repeat
  attempts, and are namespace-wide rather than a proven per-listener attribution.
  Listener queue probes were truncated and cannot identify the overloaded port.
  HAProxy used roughly 175% CPU with two configured threads.
- Sampled HAProxy descriptors were below its 1,048,576 limit; a sampled client was
  below its 100,000 limit. No TCP memory-pressure events were reported in these
  samples. This does not establish absence of source-port pressure.
- Logs contained database checkout/connection timeouts and a PromEx flusher timeout.
  Sampled database queue p95 was 40–42 ms, execution p95 about 10 ms. A separate
  PostgreSQL activity snapshot had 28 idle sessions and two short idle transactions.
  Database saturation alone does not explain the multi-second queues.

### Interpretation and fix priorities

Evidence supports a feedback loop: shared Redix/client scheduling delays threaten
presence leases, sockets close, reconnect attempts amplify CPU and accept-queue
pressure, and bounded delivery attempts spend seconds waiting. Node heartbeats,
session acquisition/renewal/release, and route lookup currently share one named
Redix connection per TCP node. HAProxy accept pressure is real, but swapping proxy
software alone cannot fix this application queue.

1. Isolate node-heartbeat traffic from session/route traffic; use a bounded set of
   supervised Redix connections for session work, assigned consistently by user.
   Preserve atomic Lua ownership checks, lease expiry, and owner-scoped release.
   Measure connection mailbox lengths and round-trip tails before increasing pool size.
2. Spread lease-renewal timing and bound reconnect attempts with backoff and jitter.
   Preserve conservative lease deadlines and failure behavior; never keep an expired
   session authorized merely to reduce disconnect counts.
3. Run load generators on separate CPU capacity for the next baseline and size TCP
   schedulers explicitly. Compare queue and lease-failure rates under equal traffic.
4. Correct attempt deadline handling and measure deadline abandonment. Do not raise
   attempt/worker limits or timeouts as the first response to saturated queues.
5. After reducing reconnect amplification, measure HAProxy accept/thread pressure
   and per-listener queues, then size proxy threads/backlogs against available CPU.
   Increasing backlog alone buffers work and cannot increase sustainable throughput.

These are proposed changes for a future deployment, not fixes applied to this run.


## Task 2 completed: isolated connection-setup failure, 18:26–18:32 UTC

The user authorized a fresh stress test and PostgreSQL cleanup. A separate
`chatchat-task2` Compose project used new database, Redis, barrier and monitoring
volumes. Application images were rebuilt from the current checkout; HAProxy was
retained. No application bottleneck fixes or resource-limit changes were applied.
Six generators requested 20,000 clients each, send probability 0.01/s,
disconnect probability 0.001/s, and 300 seconds of activity after the all-ready
barrier. Effective TCP schedulers were **12 per node**, versus two in the earlier
run, on the same 12-CPU Docker host. This is attribution evidence, not an equal
resource baseline or a before/after improvement claim.

Raw evidence: `/tmp/chatchat-task2-full-attribution-20261010/` contains capture
metadata/image IDs/effective limits, 33 timestamped samples over 330 seconds,
`summary.md`, `analysis.json`, and a final Redis INFO ALL snapshot. An earlier
setup capture is in `/tmp/chatchat-task2-attribution-20261010/`. Individual probes
record start/end times; samples and scrapes are not atomic. The nominal 600-second
capture was stopped early after sustained setup failure, before cleanup.

The all-ready barrier was never reached. Last successful shard observations
reported 107,036 ready wrappers combined; every shard remained `connecting` and
all queued-message counters were explicitly zero. Fresh connection collection
reported approximately 106,976 authenticated sockets before collapse and 43,779
at the final sample. Wrapper membership survived disconnects. This run did not
exercise message throughput, delivery deadlines, or a drain/recovery acceptance test.

| Measured mechanism | Evidence |
| --- | --- |
| Shared Redis client/runtime queueing | Repeated Redix snapshots peaked at 50,687 and 51,668 mailbox messages. There were also intervening low/zero readings: recurring pressure, not a permanently full mailbox. Nine/ six runtime probes timed out and cannot be treated as zero. Script round-trip p95 approached the 10-second histogram boundary. |
| Scheduler pressure | Summed reported run-queue lengths peaked at 10,708 and 7,538. Each TCP node had 12 schedulers, sharing compute with six generators and HAProxy. |
| Lease failure and reconnect amplification | Combined one-minute presence-unavailable closure rate peaked near 2,259/s. Last successful client samples totaled 105,004 ping failures, 62,467 peer closes, 879,881 reconnect attempts, 714,121 connect/authenticate failures, and 110,453 successful reconnects. Counts are asynchronous observations; in-flight attempts prevent attempted = failed + successful. |
| Per-listener accept pressure | At the 18:29:19 tick, HAProxy's two TCP 4040 listeners held 4,097 and 4,095 queued connections against configured backlogs of 4,096. The backend listeners and metrics listeners were sampled separately. HAProxy namespace ListenDrops/ListenOverflows increased by 2,982,927; TCP namespace deltas were 360,587 and 279,741. This correlates actual TCP listener saturation with namespace drops; it does not assign every drop to one listener. |
| Proxy destination/source-port pressure | Untruncated `ss` snapshots showed a maximum 53,510 established source ports toward one backend. The maximum sum of state-specific counts per backend destination was 53,511, below the 64,512-port configured range (1024–65535). During collapse, one snapshot showed 17,249 SYN-SENT sockets toward a backend. Source-port exhaustion was not observed; brief unsampled pressure or allocation failures remain possible. |
| Descriptor limits | Sampled maxima: TCP about 53.5k and HAProxy about 214k FDs versus 1,048,576; a generator about 18k versus 100k. These samples do not support FD exhaustion. |
| Redis server latency | Final lifetime EVALSHA execution averaged 6.87 microseconds and GET 0.53 microseconds; no rejected connections or evictions. INFO ALL also recorded a maximum slow EVALSHA execution of 77.52 ms. Server stalls exist, but observed server execution does not account for multi-second client round trips by itself. These are lifetime summaries, not interval p95s. |
| PostgreSQL latency | TCP Ecto queue p95 reached about 1.44 s and execution p95 1.93 s during connection collapse. The final activity snapshot had 30 idle client sessions and only the diagnostic query active. These are background/authentication/collector queries in a run with zero submitted messages, not measured delivery transactions. CPU or pool contention can affect them; PostgreSQL alone is not established as the cause. |

The earlier **message-producing** run attributes dominant delivery delay to the
bounded worker queue: 409 active attempts, 377 waiting and 32 workers/node, with
queue p95 initially 4.25–4.97 seconds versus roughly 4 ms scheduling delay. Re-reading
its final raw sample also found queue p95 around 9.5–10 seconds, route p95
1.55–3.06 seconds, Redis script round-trip p95 9.30–9.58 seconds, and persistence
p95 94–121 ms. Values at the highest finite histogram boundary are approximate;
the tail above that boundary is unresolved. Percentiles overlap and cannot be added.

Together, the runs measure a capacity-consuming mechanism: shared presence/client
queues and scheduling pressure lead to lease-related closure and ping failures;
reconnect activity and failed backend handshakes consume accept capacity. The fresh
run reproduced this loop **before message traffic**, so delivery writes are not a
necessary trigger. The earlier run separately shows bounded delivery worker waiting
as the dominant measured message-stage delay. Redis execution averages, FD counts,
and sampled source-port headroom weaken competing exclusive explanations without
proving they can never contribute. Shared CPU causation still requires task 3's
controlled compute baseline; connection splitting/backoff require tasks 8 and 6.

All native socket snapshots completed without row/destination truncation. Slow
`/proc` scans were explicitly unavailable and replaced with a separate local
iproute2 helper sharing only the target network namespace. Missing TCP event series
are **absent observations**, not proven zero. In contrast, initialized client
counters explicitly reported zero intentional disconnects, socket errors, token
failures and activation failures. At most 16 client retry states/shard were sampled
with bounded timeouts; they are convenience samples, not population estimates or
proof of retry spacing for every client. Fixed one-second reconnect ownership was
also verified in the existing client and wrapper code; no retry policy was changed.

The workload was stopped after sustained setup collapse. With writers stopped,
`messages`, `users`, and `admin_users` were truncated with identity reset in the
isolated PostgreSQL database; all three counts were verified zero. Migration history
was retained until the temporary project and its volumes were removed. Existing
project data was untouched. Capture regression tests passed (13 tests), including
late listeners, source-port deduplication, truncation, repeated runtime polling,
missing diagnostics, and failed socket queries versus valid zero observations.
Only Python capture support, its optional probe image and documentation changed;
Mix checks were not rerun for this completion.


## Task 3: controlled compute baseline (2026-10-10 UTC)

The largest **tested** stable connection-only population is **80,000 authenticated
sockets**. At that density, approximately **794 unique sender confirmations/s**
stayed bounded, while nominal 4,000 messages/s was unsustainable under the fixed
allocation. The 800–4,000 offered-rate interval is untested. These bounded holds do
not establish an exact maximum or unlimited soak capacity. Admission was unchanged.

Primary raw evidence is `/tmp/chatchat-task3-final-20261010/`: `results.json`,
`versions.json`, `effective-shards.json`, per-step `metadata.json`, timestamped
`samples.jsonl`/summaries, final population scans, `analysis.json`, and `cleanup.txt`.
The repeatable runner and resource allocation are documented in
[observability/BASELINE.md](observability/BASELINE.md). The final invocation used
`--steps 60000 80000 --traffic 0.01 0.05 0.1`; the 0.1 step was not executed after
the 0.05 safety stop. macOS idle sleep was prevented with `caffeinate -i`.

### Effective deployment and connection holds

A fresh dedicated PostgreSQL database, Redis and volumes isolated application data.
The 12-CPU Docker guest reserved CPUs 0–3 for two TCP replicas (quota two CPUs and
8 GiB each), 4–6 for two generators (quota 1.5 CPUs and 4 GiB each), CPU 7 for
HAProxy (one CPU, 2 GiB, two threads), 8 for PostgreSQL, 9 for Redis, 10 for web/
provision and 11 for Prometheus. CPU sets isolate roles within the guest, not from
physical-host/hypervisor contention. TCP and generators each reported two normal,
one dirty CPU and one dirty I/O scheduler; web/provision used one normal scheduler.
Both TCP replicas reported one cluster peer. Versions were Docker 29.6.2,
Elixir 1.20.4, OTP 29, PostgreSQL 18.6, Redis 8.10.1, HAProxy 3.3.15 and
Prometheus 3.13.3; selected image tags/IDs and effective limits are in raw metadata.

Two actual generator shards held a three-participant barrier, preventing automatic
traffic. The runner activated them only after both were ready and fresh authenticated
TCP counts matched the request. Intentional disconnect probability was zero;
payloads were 128 bytes and receivers were selected uniformly within each shard.
HAProxy distributed connections across both TCP nodes. Creation concurrency was
20/shard with a 5-ms ramp interval, and setup had a 240-second wall-clock deadline.
A sampled 90-second cooldown cleared old connections between population steps.

| Requested sockets | Connection-only hold | Result |
| ---: | --- | --- |
| 60,000 | 120 seconds; samples 21:54:35–21:56:25 UTC | All authenticated; population scan covered all 60k with empty inbox/outbox. |
| 80,000 | 120 seconds; samples 22:02:08–22:03:58 UTC | All authenticated in every fresh sample; zero client disconnects/reconnects; no messages. Setup took 230.07 seconds. |

These holds covered repeated 10-second renewals, 30-second leases and 30-second
pings. Sample gaps stayed approximately 10 seconds. At 80k without traffic, TCP
normal run queues peaked at 14 and shared Redix mailboxes at four.

### Traffic, latency and saturation

Rates below are differences between first/last valid two-generator samples, not
nominal probabilities or attempt counts. Samples/probes are asynchronous. Latency
starts at first outbox admission and includes retries; only matching successful
results count once. Sender confirmation means receiver ACK **or PostgreSQL commit**,
not necessarily completed receiver delivery. Bucket p95s are upper bounds, and
unconfirmed work is excluded from latency statistics.

| Offered rate at 80k | Sample window | Unique queued/s | Unique confirmed/s | Confirmation latency | Outstanding / slope |
| ---: | --- | ---: | ---: | --- | --- |
| 800/s (p=0.01) | 110 seconds within a 120-second hold | 792.6 | 793.9 | Mean 5.28 ms; p95 ≤50 ms | 31 final; −1.25/s; zero retries |
| 4,000/s (p=0.05) | 30.01 seconds; safety stop at about 34 seconds | 4,014.4 | 2,923.6 | Mean 1,144.67 ms; p95 ≤10,000 ms | 33,168 final; +1,090.76/s |

All 80k authenticated sockets remained present with zero disconnects/reconnects
through both steps and drain. At the unsafe step, retry attempts reached 83,181
and matched failed responses 104,137; rejections/submission failures remained zero.
Stable sockets alone therefore do not demonstrate sustainable delivery throughput.

At the safe step, median CPU use was 74.25%/71.73% on TCP (200% quota each),
48.96%/47.19% on generators (150% each), 21.4% on HAProxy and 14.2% on Redis.
At the unsafe step, TCP medians rose to 164.44%/156.13% (peaks 176.18%/189.07%),
generators to 107.41%/110.35% (peaks 123.36%/132.56%), HAProxy to 100.3% against
its 100% quota, Redis to 23.5% and PostgreSQL to 20.8%. TCP normal queues peaked
at 460, generator queues at 999 and shared Redix mailboxes at 2,455.

This separates measured generator CPU headroom from proxy quota saturation and
backend runtime/Redis-client queue growth. It does not assign exclusive causation
to HAProxy, Redis or schedulers, nor prove a specific remediation. Tasks 8 and 6
remain the next planned work; this task implements neither.

### Drain, receiver coverage and cleanup

Shared simulator probability was set to zero while clients and stores remained
alive. During the 120-second drain, **233,719 queued identities matched 233,719
unique sender confirmations** by about 62 seconds. Final counters were 444,571
send attempts, including 210,852 retries, and 210,848 matched failed responses.
The retry-tail mean confirmation latency was 25,018.9 ms and p95 exceeded the
10,000-ms finite histogram boundary; its finite upper bound is unknown. Redix
mailboxes peaked at 3,840 during drain. PostgreSQL pending rows were zero.

The final population scan observed **79,999 of 80,000 clients**: one client-state
request timed out, with zero unscanned clients. Observed outboxes/inflight attempts
were zero and receiver inbox identities totaled **233,718**. Sender acceptance
fully reconciled, but this incomplete, non-atomic receiver snapshot does **not**
prove complete receiver delivery or no loss. Full reconciliation and outage/recovery
validation remain task 7. No failure injection was performed.

Writers were stopped, isolated `messages`, `users` and `admin_users` were truncated,
and all three counts verified zero (`cleanup.txt`: `0|0|0`). The temporary project
containers and volumes were removed; existing project data was untouched.

### Preliminary evidence and exclusions

`/tmp/chatchat-task3-controlled-v2-20261010/` separately held 20k/40k sockets and,
at 40k, measured about 3,992 queued/s and 3,992 confirmed/s with p95 ≤50 ms and
50 final outstanding identities. Nominal 8k/s collapsed to 18,874 authenticated
sockets and accumulated 536,263 outstanding identities. Its old per-wrapper
probability update timed out, so no drain proof is claimed. The final runner uses
one shared ETS probability setting per simulator and bounded population scans.
This different density/control run is not an equal-resource before/after improvement.

That preliminary run's 80k setup had a 333.1-second observation gap, invalidating
capacity attribution; it is excluded as an 80k failure point. An earlier deployment
used a 512-MiB proxy limit, then was stopped before higher populations; the final
fresh allocation used 2 GiB to avoid that memory confound. All preliminary isolated
data was cleaned up. The old approximately 107k setup collapse remains historical
evidence, not a demonstrated sustainable capacity or an exclusively proven shared
CPU explanation.

### Verification

The full umbrella suite passed 124 tests. Focused client/TCP tests, formatting,
high-priority Credo and test compilation with warnings as errors passed. Capture
regressions passed 13 tests and baseline gate regressions passed four. Coverage
includes exactly-once matched confirmations, latency across retries, shared
pause/resume with busy/dead clients, invalid probability rejection, freshness,
observation gaps and unsafe/missing-data traffic stops. A TCP test observer was
scoped to the emitting connection to avoid unrelated late closure events; production
closure behavior was unchanged.
