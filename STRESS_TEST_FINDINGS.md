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
