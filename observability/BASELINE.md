# Controlled connection and traffic baseline

Task 3 uses a fresh `chatchat-task3` deployment, PostgreSQL database, Redis,
monitoring and barrier volumes. HAProxy remains in the path. No admission,
presence, reconnect, delivery or health-check settings are increased. The runner
refuses existing baseline resources or any running Docker containers. Do not stop
another workload to make this check pass without authorization.

The run provisions 80,000 dedicated users and generates load. Run only when
explicitly authorized, on a Docker host with at least 12 CPUs and approximately
32 GiB RAM. CPU sets separate workloads **inside the Docker host**; they do not
provide physical-host isolation from other applications or hypervisor contention.

Keep the host awake throughout a run (on macOS, prefix the command with
`caffeinate -i`). Large observation gaps invalidate capacity attribution.

From the repository root:

```sh
python3 observability/run_baseline.py --build \
  --output /tmp/chatchat-baseline-new-run
```

The script builds current releases and the socket probe. It generates a private
cluster cookie in memory and never writes container environments. Each TCP node
has two normal schedulers, one dirty CPU scheduler and one dirty I/O scheduler.
Generators have the same scheduler settings; web and provision have one normal
scheduler. Effective versions, image IDs, quotas, CPU sets, memory limits,
replicas, BEAM schedulers, initial queues and HAProxy version/thread configuration
are saved, rather than inferred from defaults. Runtime queues, CPU use, cgroup
throttling, memory events, socket pressure and existing diagnostics are sampled.

| Service | Replicas | Docker CPUs | CPU quota per replica | Memory limit per replica |
| --- | ---: | --- | ---: | ---: |
| TCP | 2 | 0–3, shared only by TCP | 2 | 8 GiB |
| Generators | 2 | 4–6, shared only by generators | 1.5 | 4 GiB |
| HAProxy | 1, existing 2 threads | 7 | 1 | 2 GiB |
| PostgreSQL | 1 | 8 | 1 | 2 GiB |
| Redis | 1 | 9 | 1 | 1 GiB |
| Web / provision | 1 each, provision exits before load | 10 | 1 | 1 GiB |
| Prometheus | 1 | 11 | 1 | 1 GiB |

Default connection steps are 10k, 20k, 40k and 80k, below the previous approximately
107k setup failure. Each step recreates only generators with distinct run-barrier
claims and non-overlapping users. The backend allocation stays fixed. A sampled 90-second cooldown between
generator recreations lets old proxy/backend source-port TIME_WAIT populations
expire, preventing the next step from inheriting port occupancy. Setup has a
240-second wall-clock deadline in the runner, including waiting for ready shards;
the application deadline alone does not bound a ready shard waiting for its peers.
Creation concurrency is 20 per shard with a 5-ms ramp interval. These are simulator
options, not a guaranteed aggregate arrival rate; actual setup timing is captured.

Two generators claim shards from a three-participant barrier, deliberately holding
activity. The runner starts traffic only after both wrappers are ready and **fresh
TCP authenticated counts** equal the requested population. Each step then holds
for 120 seconds, covering repeated 30-second leases and 10-second renewals and 30-second pings.
A step passes the automated connection gate only with at least six observations,
fresh sockets at or above 99.9% of the request throughout the hold, and zero
recorded reconnect failures, with no observation gaps longer than 30 seconds. Closure/reconnect counts and missing observations
still need review; this gate does not prove an unlimited soak or absence of brief
unsampled outages.

Traffic uses the largest passing connection step, reproducing its setup and hold
if the next step failed. Send probabilities ramp through 0.01, 0.05, 0.10 and 0.20
per client per second for 120 seconds each. Intentional disconnections stay zero,
payloads are 128 bytes, and uniform receiver selection stays within each shard's
existing simulator population. HAProxy balances both shards across the same two
clustered TCP nodes; generator count and receiver selection stay fixed between
traffic steps. This is not an identical workload comparison with the earlier
six-shard run. Nominal offered messages/second are requested sockets × probability;
measured submission and unique confirmation rates are reported separately.

After a 30-second warmup, the runner ends an unsafe traffic step early on a
missing generator counters, missing/falling fresh socket count or
more than `max(100, 1% of sockets)` outstanding unique submissions. This is a safety
stop, not a throughput/latency acceptance target. Review backlog slope, confirmation
latency, CPU headroom, retries and queues to determine sustainable measured steps.
One protected ETS setting per simulator changes send probability through
`ChatchatClient.set_simulation_send_probability/2`; wrappers read it on each tick.
This avoids sequentially updating busy wrappers and preserves client stores.
A 120-second drain sets send probability to zero while retaining clients and their
outboxes. No failure injection is performed.

Client status retains existing attempt fields and adds unique confirmations,
actual send/retry attempts, and cumulative confirmation-latency buckets at 10, 50,
100, 500, 1,000 and 10,000 ms. Latency starts at the first outbox admission and
includes retries. Only matching `ok` removes an identity and records confirmation;
stale/duplicate results do not count. Histogram overflow remains measurable in
the count but has no finite upper bound. Latency buckets include only confirmed
messages; outstanding work is reported separately to expose unconfirmed tails. These counters describe sender acceptance
(receiver ACK **or PostgreSQL commit**), not completed receiver delivery.

`queued_messages - unique_confirmed_messages` is outstanding unique submitted
work, including retained rejections. Population `outboxes.json` scans at connection hold and drain boundaries report actual outboxes, inbox identities and inflight
attempts. They use eight workers, 25-ms client-state timeouts, a five-second scan
deadline per shard and a bounded 80k population; timestamps, unavailable clients and unscanned clients are explicit. Scans and counters
are not atomic. Client process death can lose in-memory work; do not infer no loss
unless scans, diagnostics, PostgreSQL backlog and final counters reconcile.

Raw samples and summaries are saved per phase. Resource metadata is saved per
connection step; `results.json` records gates. After final observations, the runner
stops writers, truncates only its fresh `chatchat_baseline` application tables,
saves verified counts to `cleanup.txt`, and removes its project containers/volumes.
Interrupted runs also attempt this cleanup. Inspect failures and Docker resources
before repeating a run; never delete shared data. Report the largest **tested**
sustainable step and any untested interval, rather than claiming an exact maximum.

Service-free capture/gate regressions:

```sh
python3 -m unittest discover -s observability -p 'test_capture*.py'
python3 -m unittest discover -s observability -p 'test_baseline.py'
```
