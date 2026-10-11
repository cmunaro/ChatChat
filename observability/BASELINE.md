# Controlled connection and traffic baseline

Task 3 uses a fresh `chatchat-task3` deployment, PostgreSQL database, Redis,
monitoring and barrier volumes. HAProxy remains in the path. Resource allocations stay fixed; application behavior and health-check settings follow the checked-out source.
Presence connection roles and bounds follow the checked-out implementation;
record the source/image metadata for before/after comparisons. The runner
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
| HAProxy | 1, 2 threads by default | 7 | 1 | 2 GiB |
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
for 120 seconds, covering repeated 30-second leases and renewals (8–12 seconds after task 8) and 30-second pings.
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
outboxes. `--backend-outage` then resumes 0.01 traffic, stops one dedicated TCP node for 30 seconds, restarts it, observes 180 seconds of recovery and drains for another 120 seconds. Stopped-node probes remain unavailable.

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
attempts. They use eight workers, 25-ms client-state timeouts with one bounded retry, a five-second scan
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

For a same-image proxy comparison, build the first run only and use
`--proxy-threads 2` and then `--proxy-threads 1`, with identical steps and traffic.
The runner writes a private rendered configuration into each output directory;
the checked-in configuration remains the default. Compare image IDs, CPU limits,
setup duration, healthy check latency, listen-drop deltas and recovery observations.
`timeout check 2s` bounds the response phase, following a connect timeout of 5s.
With `inter 2s fall 3 rise 2`, a conservative failed-check detection budget is
27 seconds (three connect/response/interval budgets), and healthy recovery is
18 seconds (two such budgets), plus DNS, scheduling and observation delays.
These configured budgets are not measured hard real-time guarantees.

Queue counts come from outbox admission, including requests whose callers later
time out; submission failures are separate. Older runs counted successful API
returns and can undercount admitted work during overload. Sender confirmation
still means receiver receipt or durable commit; receiver scans establish delivery.

Use `--backend-outage --outage-mode pause` for a DNS-preserving failure: the runner
pauses one TCP container for 30 seconds, always resumes it, observes 180 seconds
of recovery and drains for 120 seconds. The default `stop` mode restarts the
container and can remove it through Docker DNS before health failure hysteresis
runs. Capture includes all active proxy states, including maintenance. Failed
exporter observations remain unavailable.

Capture includes exporter scrape duration and source scrape timestamps, plus
current target health, last-scrape time and sanitized failure categories. The
target API observation has its own probe timestamps and can follow the sample's
PromQL evaluation time. Use these to distinguish capture failures from failed
exporter scrapes; `up=0` does not establish backend DOWN. Raw target errors and
URLs are discarded, and missing target evidence remains explicitly unavailable.

A server `presence_unavailable` error is transient: the client closes/reconnects
with its existing outbox eligible for retry. Malformed or other uncorrelated
protocol errors retain the existing explicit suspension policy; reconnect does
not clear a prior safety hold.

Task 10's initial comparison target is continuous fresh observations of 80,000
authenticated sockets within 120 seconds after a 30-second backend pause, followed
by complete reconciliation within the existing 120-second drain. This is an
experimental acceptance target, not a production SLA. Keep the existing resource
allocation, 0.01 traffic probability and two proxy threads as the comparison anchor.
For the first reconnect-spread trial, require steady-state p95 ≤50 ms and at least
760 confirmations/s, lower recovery retry failures and proxy namespace listen-drop
deltas than the instrumented control, no unexplained missing identities and zero
final pending work. Retain the 240-second setup deadline and existing bounded
recovery/drain phases. Only the client policy image changes intentionally; preserve
all backend/proxy images and resource limits. A single paired run establishes a
tested outcome, not statistical confidence across deployments.
The 20-second first-reconnect spread failed acceptance and was reverted. The next
trial retains the original retry delays and caps concurrent live-client reconnect
handshakes at each simulator's existing `creation_concurrency` (20 per shard in
this baseline). It uses a fixed-size local ETS slot set; contention defers to the
existing tagged backoff timer rather than queuing a socket operation. Exact-owner
release and lazy reclamation of killed owners preserve the bound without a new
coordinator mailbox. `reconnect_deferred` counts local admission deferrals separately
from network attempts/failures; `reconnect_admission` reports the configured limit
and sampled active holders. The first fixed-slot/exponential-deferral version
failed the recovery/drain target and was replaced with bounded free-slot borrowing
and 1.6–2-second admission retries. Admission contention does not increment or
reset network failure backoff; existing network failures keep their longer delay.
The same target, gates, resources and reconciliation
criteria apply. Standalone clients retain their existing independent retry policy.

Rebuilt clients report bounded `connection_diagnostics.timings_ms` histograms for
first and repeated reconnect timer waits, lateness beyond the scheduled timer,
and successful/failed TCP connect and authentication durations. Socket failure
counters separate connect/authentication timeout, existing ownership rejection,
presence unavailability and other errors without retaining responses or tokens.
The socket timing histograms cover reconnects observed by simulator wrappers;
startup socket calls emit telemetry but do not enter these population histograms.
Wait starts when the reconnect timer is scheduled, not when an outage begins.
Connect/authenticate timing includes runtime scheduling and network/server work;
it does not isolate server execution. Retry intervals include the previous attempt
duration plus the next timer wait, so configured delay caps do not bound them.
Histograms retain their count/sum and existing buckets, add 10/50/100/500-ms buckets,
and have explicit overflow beyond 60 seconds. Hard client death cannot record a
completed operation and still loses in-memory stores. New fields require rebuilt
client images; do not treat missing fields as zero.

Task 11 is complete at 1,200/s for five minutes with 80k users and fixed resources.
The user revised the original 15-minute acceptance to five minutes, with complete
reconciliation required for accepted runs. Reuse the saved passing evidence; no
additional load run is required. The commands below record the original trials,
not a requirement to repeat them. Neither trial injected outages:

Original ramp procedure:

```sh
caffeinate -i python3 observability/run_baseline.py --build --steps 80000 \
  --hold 120 --traffic-hold 300 --traffic .01 .015 .02 .03 .04 .05 \
  --soak 900 --output /tmp/chatchat-task11-throughput-20261011
```

The nominal ramp is 800/1,200/1,600/2,400/3,200/4,000 messages/s; stop at the
first rejected step. Each step drains for 120 seconds and must reconcile all
admissions, confirmations and receiver inbox identities with complete population
scans and zero outbox/inflight/PostgreSQL pending work before continuing. Soak
the highest accepted rate for 900 seconds, then reconcile again. Setup and
connection hold remain 240/120 seconds. Existing safety stops apply after the
30-second warmup; sampled container memory at 90% also stops traffic. CPU,
lane reservations and memory are captured for attribution, not increased.

Acceptance uses post-warmup counter/histogram deltas: at least 95% of nominal
rate confirmed, confirmation p95 ≤100 ms, final outstanding ≤100 identities,
endpoint backlog slope ≤1 identity/s, fresh ≥99.9% sockets, full hold duration,
and no capture gap >30 seconds. Review the complete backlog series as well as
this endpoint slope. These are experimental duration/latency criteria, not a
production SLA. A failed higher step brackets only the tested interval; if every
step passes, report a lower bound rather than an exact ceiling. The pre-run
`plan.json` records durations and criteria; `results.json` records rate gates and
per-drain reconciliation. Missing evidence fails acceptance. Maximum traffic
and soak time is 45 minutes plus bounded drains/setup/build, usually less because
the ramp stops on its first failure.


Task 11's initial ramp passed the five-minute 800/1,200/s traffic gates but stopped
at 1,600/s after shared Redis timeouts; its drain did not fully reconcile. The
runner saved the failure and cleaned up, discarding remaining dedicated test data.
Do not infer eventual delivery or no loss for that unsafe population. No higher
rates ran. A final fresh duration-only trial reused exactly the same images:

```sh
caffeinate -i python3 observability/run_baseline.py --steps 80000 --hold 120 \
  --traffic-hold 900 --traffic .015 \
  --output /tmp/chatchat-task11-soak-20261011
```

That trial stopped after about 13 minutes at generator memory 90.38%, retaining
80k sockets, approximately 1,197 confirmations/s and p95 ≤50 ms. All 937,565
identities reconciled after drain, but the 15-minute duration criterion failed.
The saved 300-second 1,200/s ramp satisfies revised task 11 acceptance: 1,201.1
confirmations/s, p95 ≤50 ms, fresh 80k sockets during traffic, and complete 80k
receiver scans reconciling 600,374 cumulative identities. The second drain briefly
dipped to 75,626 sockets before recovering. That incident, failed 1,600/s
reconciliation and longer-run memory failure remain unresolved limitations; see
the findings. Acceptance makes no claim beyond five minutes. Task 12 is separate. The executed runner is preserved in each
artifact directory; subsequent gate hardening also rejects memory-stopped phases
and requires the expected scan population. Neither trial establishes an exact
capacity ceiling or authorizes increasing resource limits.
