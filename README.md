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
| Presence | One connection/user; lease 30s, renewal 10s |
| Distribution ports | 4369 / 9100, private network only |

BEAM distribution uses the shared cookie and is **unencrypted by default**. Keep replicas on
a trusted private network. Across untrusted networks, configure `-proto_dist inet_tls` and
`-ssl_dist_optfile` with peer verification. Never expose distribution ports or log cookies.
Single-node Mix development needs no discovery setup.

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
