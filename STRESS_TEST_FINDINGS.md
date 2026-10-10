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
