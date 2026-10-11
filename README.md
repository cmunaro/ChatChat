# ChatChat

Distributed 1:1 chat exercise built with Elixir/OTP.

**Available:** authentication, user search, presence, offline delivery, client simulation.
**Planned:** groups, reactions, editing, attachments, TCP encryption.

## Architecture

```mermaid
flowchart LR
    Client --> HAProxy
    HAProxy --> TCP[TCP nodes]
    TCP <-->|Direct BEAM delivery| TCP
    TCP --> Redis[Redis: presence / routes]
    TCP --> PostgreSQL[PostgreSQL: users / pending messages]
    Web[Phoenix HTTP / admin] --> PostgreSQL
```

| App | Responsibility |
| --- | --- |
| `chatchat_web` | HTTP, LiveView admin, OpenAPI |
| `chatchat_tcp` | Authenticated connections, presence, delivery |
| `chatchat_broker` | Domain rules, PostgreSQL |
| `chatchat_auth` | Tokens |
| `chatchat_client` | Mock clients, simulations |

Delivery: **receiver ACK or PostgreSQL commit → `ok`**. See [delivery flow](MESSAGE_DELIVERY.md).

## Local start

Use the Elixir/Erlang versions in `mise.toml`.

```sh
docker compose up -d redis postgres
mix ecto.create
mix ecto.migrate
mix phx.server
```

## TCP load balancing

```sh
export TCP_CLUSTER_COOKIE="$(openssl rand -hex 32)"
docker compose up -d --build --scale tcp=2
# Keep the same cookie when scaling:
docker compose up -d --scale tcp=4
```

| Setting | Value |
| --- | --- |
| Client endpoint | `localhost:4040` (containers: `haproxy:4040`) |
| Balancing | Fewest active connections; `/metrics` health checks |
| Discovery | Docker DNS; `libcluster` DNSPoll |
| Node names | `chatchat_tcp@<container-address>` |
| Presence | One connection/user; lease 30s, renewal jittered 8–12s |
| Distribution ports | 4369 / 9100, private network only |

BEAM distribution uses the shared cookie and is **unencrypted by default**. Keep replicas on
a trusted private network. Across untrusted networks, configure `-proto_dist inet_tls` and
`-ssl_dist_optfile` with peer verification. Never expose distribution ports or log cookies.
Single-node Mix development needs no discovery setup.

Each TCP node uses a dedicated Redis heartbeat connection and four user-sharded
session/route lanes plus four separate renewal lanes. Each lane reserves at most
512 operations before mailbox submission, with a shared five-second queue/command
budget. Overload fails closed; command timeouts restart only the affected lane to
discard pending Redis work. Lua owner/session checks and lease expiry are unchanged.
Redis metrics use fixed `heartbeat`, `session` and `renewal` role labels; capture
also records lane mailbox lengths and reserved slots. These limits are independent
of message admission budgets.


## Admin & monitoring

Create an admin: `mix chatchat.admin.create admin`.

| Surface | URL |
| --- | --- |
| Admin | http://localhost:4000/admin |
| HTTP docs | http://localhost:4000/admin/swaggerui |
| OpenAPI | http://localhost:4000/admin/openapi |
| TCP protocol | http://localhost:4000/admin/tcp-protocol |
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3000 (`admin` / `admin`) |
| Web metrics | http://localhost:4000/metrics |
| HAProxy metrics | http://localhost:8404/metrics |

Prometheus discovers TCP replicas; Grafana aggregates their metrics.
Local connection metrics poll every five seconds independently of delivery and
PostgreSQL. Background collections have a two-second limit and one task per source.
Runtime gauges require successful collection within 15 seconds and an exporter
that is up; unavailable totals display `Unknown / stale`. PostgreSQL pending rows
use the maximum fresh observation because TCP replicas share the database.
The runtime collection health panel shows freshness by node and source.
`Collector not deployed` identifies TCP images built before the freshness collector.
The dashboard includes a legacy view with unverified freshness, kept per exporter:
older connection gauges report cluster totals and must not be summed. HAProxy
session counts provide live backend socket counts, including unauthenticated sockets.
Task 2 diagnostic charts require rebuilt TCP images. Rebuild application images
before the next simulation; changing dashboard files does not update running code.
Do not restart a running stress test merely to enable instrumentation. Empty event
charts can mean no matching events, and HTTP charts exclude unknown routes such as
metrics scrapes. The datasource scrape interval matches Prometheus at five seconds.

Validate runtime dashboard queries with synthetic data (requires `promtool`):

```sh
python3 observability/test_dashboard.py promtool
# With the existing Prometheus container; no live data is modified:
python3 observability/test_dashboard.py docker exec -i chatchat-prometheus-1 /bin/promtool
```

Delivery diagnostics expose queue wait, worker scheduling delay, route lookup,
direct receipt wait, persistence, and post-commit wakeup time. Queue/schedule are
tagged by routing or fallback; executing stages include success/error/exception.
Queue abandonment and direct fallback are recorded once. Persistence includes
checkout and commit; Redis time overlaps route/wakeup, so do not add stage p95s.
Hard process kills cannot emit an executing stage's completion or final closure.
Redix round-trip/failure metrics cover calls that emit its pipeline-stop event:
transport failures/timeouts are counted; Redis server error replies inside a
successful pipeline and abrupt connection-process exits are not counted there.
Route/persistence stage errors provide complementary evidence.

TCP closure reasons distinguish authentication, presence lease failure, idle
timeout, protocol error, socket error, peer close, shutdown, and other termination.
Client `simulation_status/1` adds `connection_diagnostics` with disconnect reasons,
reconnect attempt/success/failure counts, and failure stages. Ready wrappers still
do not imply connected sockets. Diagnostics use fixed labels, without message/user
IDs, payloads, tokens, or arbitrary error strings. Existing result fields, retry
intervals, and delivery deadlines remain unchanged.

For a future instrumented run, capture five minutes of read-only diagnostics:

```sh
python3 observability/capture_diagnostics.py \
  --tcp-container chatchat-tcp-1 --tcp-container chatchat-tcp-2 \
  --haproxy-container chatchat-haproxy-1 \
  --loadgen-container chatchat-loadgen-1 \
  --postgres-container chatchat-postgres-1 --redis-container chatchat-redis-1 \
  --output tmp/diagnostics-run-1
```

For large socket populations, build the optional local `ss` probe image:

```sh
docker build -t chatchat-socket-probe -f observability/socket-probe.Dockerfile .
# Add --socket-probe-image chatchat-socket-probe to the capture command.
```

The helper runs without capabilities, shares only the target network namespace,
and does not modify application containers. It uses kernel socket diagnostics to
sample LISTEN occupancy/configured backlog and outgoing source-port counts.
Without it, installed `ss` is preferred, then bounded `/proc` scans; slow scans
are explicitly unavailable. Each probe records its own start/end timestamps.

Repeat `--loadgen-container` for each shard. The output directory must be new.
Defaults: Prometheus `http://localhost:9090`, five-second interval, 300-second
duration; optional `--interval`, `--duration`, and `--prometheus` override them.
Sampling uses four concurrent probes, three-second command/request timeouts (eight seconds for separate socket scans),
bounded response sizes, and at most 32 explicit container targets. Kernel/FD
probes run at most every 30 seconds; socket sampling examines at most 262,144
rows (per address family for `/proc`, total for `ss`) and explicitly marks row and destination truncation.
It records listeners separately from outgoing destination/state counts and unique
source ports for TCP 4040, PostgreSQL 5432, and Redis 6379 (hexadecimal addresses).
Destination tables retain at most 256 groups per scan; omitted rows make counts
lower bounds. LISTEN rx queues are current occupancy, not configured backlog size.
TCP RPC samples Redis-role mailboxes and scheduler queues every tick. Client RPC
samples at most 16 retry states with 25-ms per-process timeouts, without identities
or message contents; these are convenience samples, not population estimates.
Redis INFO and PostgreSQL grouped wait/activity snapshots are opt-in probes. Slow samples skip missed ticks.
Outputs are `capture.json`, timestamped `samples.jsonl`, and `summary.md`.
The summary aligns stage means, connection/health rates, queue pressure and CPU;
raw samples include per-node p95s, client counters, socket/TIME_WAIT totals,
port ranges, descriptor limits/usage, and listen-overflow counters. The summary
correlates listener samples with namespace counter deltas; neither cumulative
drops nor a queue snapshot attributes every dropped connection to a listener.
Missing probes are explicit. Kernel/socket totals alone cannot prove
per-destination port exhaustion; compare counter deltas and metric freshness.
No workload or missing new diagnostics leaves attribution pending. The capture
does not launch traffic, provision users, change settings, or read environments.

Test capture behavior without services:

```sh
python3 -m unittest discover -s observability -p 'test_capture*.py'
```

## Client simulation

Run `iex -S mix phx.server`, then:

```elixir
simulation = ChatchatClient.simulate(%{
  number_of_clients: 10,
  send_message_probability_per_second: 0.5,
  disconnection_probability_per_second: 0.1
})
ChatchatClient.simulation_status(simulation)
ChatchatClient.stop_simulation(simulation)
```

Traffic starts after all clients connect. Disconnected clients reconnect automatically.
Client state survives reconnect; **stop/crash clears retry and deduplication state**.

<details>
<summary>Large Docker load test</summary>

```sh
LOAD_TEST_RUN_ID=run-1 LOADGEN_PARTICIPANTS=4 \
docker compose --profile loadtest up -d --build --scale tcp=2 --scale loadgen=4
```

Provision runs migrations, creates 150k users, and clears the run barrier.
Each generator starts 20k clients; traffic waits for all four shards.
Restarting all generators requires a fresh provisioned run.

</details>

For the authorized, isolated task 3 baseline, see
[controlled connection and traffic runs](observability/BASELINE.md). The runner
reserves separate Docker CPU sets for backend, generator and proxy work, bounds
setup, verifies fresh authenticated sockets before traffic, and saves unique
confirmation latency, retry, outbox and drain observations.

## Tests

Use dedicated test services; never production/shared data.

```sh
docker compose -p chatchat-delivery-tests -f docker-compose.test.yml up -d --wait
export TEST_DATABASE_URL=ecto://chatchat:chatchat@localhost:15432/chatchat_test
export TEST_REDIS_URL=redis://localhost:6379/15
MIX_ENV=test mix ecto.migrate
mix test
```

Two-node discovery check:

```sh
MIX_ENV=test elixir --name chatchat_check@127.0.0.1 -S mix run --no-start scripts/check_tcp_cluster.exs
```

Mock-client reconnect and wrapper startup retries use exponential backoff with
jitter: 0.8–1 second initially, capped at 24–30 seconds between attempts after
repeated failures, plus the bounded connect/authenticate time. Successful
authentication resets the backoff. Only the live client reconnects; the wrapper
recreates it after process death. Socket reconnect retains outbox identities and
inbox deduplication; process death still clears in-memory stores. Status includes
bounded aggregate histograms of actual retry intervals for both owners.

Simulator socket reconnects also share a local handshake limit equal to
`creation_concurrency` (20 per shard in the controlled baseline). A bounded ETS
slot pool admits work before connect/authentication, borrows unused slots, and
reclaims killed owners. Busy clients retain one timer and retry admission after
1.6–2 seconds; actual network failures retain exponential backoff. Status reports
`reconnect_admission`, `connection_diagnostics.reconnect_deferred`, operation timing
histograms and fixed socket-failure categories. Standalone clients keep independent
retries. The validated 80k pause comparison recovered sockets in approximately
100 seconds, with complete reconciliation; this is a tested point, not a recovery SLA.

A transient server `presence_unavailable` response reconnects with pending
messages eligible for retry. Malformed protocol responses still suspend retries
until explicit resume; successful authentication does not clear that safety hold.
