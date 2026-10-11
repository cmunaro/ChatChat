# ChatChat

Elixir/OTP umbrella for authenticated 1:1 chat, presence, offline delivery and client simulation.

`chatchat_web`: Phoenix API/admin; `chatchat_tcp`: sockets/presence/delivery;
`chatchat_broker`: accounts/PostgreSQL; `chatchat_auth`: tokens;
`chatchat_client`: clients/load generators.

Clients → HAProxy → TCP nodes. Redis owns presence/routes; PostgreSQL stores
users and pending messages. See [delivery guarantees](MESSAGE_DELIVERY.md).

## Local start

Use the versions in [mise.toml](mise.toml); run Mix from the repository root.

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
```

Keep the cookie when scaling. HAProxy uses least connections and `/metrics`
health checks; Docker DNS discovers replicas. TCP is at `localhost:4040`.
TCP and BEAM distribution are unencrypted by default: keep them on trusted
networks; configure distribution TLS across untrusted networks.

Presence permits one connection/user: 30s lease, jittered 8–12s renewal.
Each node has a heartbeat Redis connection and four session plus four renewal
lanes; each lane admits 512 operations with a 5s budget. Lease failures close sockets.

## Admin & monitoring

Create an admin: `mix chatchat.admin.create admin`.

| Service | Local address |
| --- | --- |
| Admin / HTTP docs / TCP protocol | `:4000/admin`, `/admin/swaggerui`, `/admin/tcp-protocol` |
| OpenAPI | `:4000/admin/openapi` |
| Prometheus / Grafana | `:9090` / `:3000` (Grafana default: `admin` / `admin`) |
| Web / HAProxy metrics | `:4000/metrics` / `:8404/metrics` |

Runtime gauges require an up exporter and collection within 15s. Ready client
wrappers are not authenticated sockets; HAProxy sessions also include unauthenticated
connections. Never sum legacy cluster-wide connection gauges.

Read-only diagnostics: `python3 observability/capture_diagnostics.py --help`.
The isolated [baseline runner](observability/run_baseline.py) reserves CPU sets,
checks sockets before traffic, stops unsafe phases and reconciles pending work.
It requires a fresh dedicated 12-CPU deployment and removes its test data on cleanup.
Optional failures: `--failure-scenario redis|postgres|tcp-all`.

## Client simulation

In `iex -S mix phx.server`:

```elixir
simulation = ChatchatClient.simulate(%{
  number_of_clients: 10,
  send_message_probability_per_second: 0.5,
  disconnection_probability_per_second: 0.1
})
ChatchatClient.simulation_status(simulation)
ChatchatClient.stop_simulation(simulation)
```

Activity starts after clients are ready; `auto_start_activity: false` allows manual
`ChatchatClient.start_simulation_activity/1`. Send probability can change through
`ChatchatClient.set_simulation_send_probability/2`.
Reconnect retains stores; process death destroys them. Retries use jittered
backoff and a per-simulator handshake limit equal to `creation_concurrency`.

Compose's `loadtest` profile provisions 150k users. Defaults: 25k clients/shard,
20 concurrent handshakes, `.10` sends and `.01` disconnects per client/second,
900s activity. Match `LOADGEN_PARTICIPANTS` to the generator count; traffic starts
at the all-shard barrier. Use a fresh `LOAD_TEST_RUN_ID` when recreating generators.
Build TCP, web and loadgen together; rebuilt images require container recreation.

## Tests

Use dedicated PostgreSQL and Redis; never production/shared data.

```sh
docker compose -p chatchat-delivery-tests -f docker-compose.test.yml up -d --wait
export TEST_DATABASE_URL=ecto://chatchat:chatchat@localhost:15432/chatchat_test
export TEST_REDIS_URL=redis://localhost:6379/15
MIX_ENV=test mix ecto.migrate
mix test
mix format --check-formatted
mix credo --min-priority high
MIX_ENV=test mix compile --warnings-as-errors
```

Test ports must be free. Diagnostics tests need no services:
`python3 -m unittest discover -s observability -p 'test_baseline.py'` and
`python3 -m unittest discover -s observability -p 'test_capture*.py'`.
