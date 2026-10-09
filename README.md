# ChatChat

Elixir distributed real-time chat exercise.

## Features

- [x] Register and login
- [x] Search users
- [x] 1to1 chats
- [ ] Group chats
- [~] Send text, images and files
- [ ] React to messages
- [ ] Edit messages
- [ ] Delete messages
- [x] Store and retry undelivered messages
- [ ] Admin dashboard
  - [ ] Live connections
  - [ ] Delivery statistics
  - [ ] Latency, mailbox and bottleneck metrics
  - [ ] Entity management
  - [x] Api documentation
- [x] High-load client simulation
- [x] User discovery by username
- [ ] Conversation membership and authorization
- [x] Online presence
- [x] Offline message delivery
- [ ] Groups
  - [ ] Creation
  - [ ] Deletion
  - [ ] Join
  - [ ] Exit

## Implementation

- [x] Release-based Docker images
- [x] Docker Compose development environment
- [x] Ecto SQL storage and migrations
- [ ] Phoenix HTTP API and LiveView admin
- [~] Thousand Island custom encrypted protocol
  - [x] Connect and disconnect with authentication
  - [ ] Reconnect
  - [ ] Encryption
- [x] Direct BEAM delivery across TCP nodes
- [x] Node-local telemetry and Phoenix PubSub for admin updates
- [ ] API documentation with OpenAPI Spex
  - [x] Request and response schemas
  - [x] OpenAPI specification
  - [ ] Swagger UI in admin
- [x] Bounded per-node receipt-or-commit delivery
- [x] Multi-node and high-load simulations
- [~] GitHub Actions
  - [x] Unit and integration tests
  - [x] Format and Credo checks
  - [~] Images published to GitHub image registry
- [x] Latest Elixir/Erlang versions pinned with mise
- [ ] Horizontal autoscaling experiment
- [~] Logs
  - [ ] Loki http traces
  - [x] Grafana dashboards
- [ ] Node-local caching with ConCache

## Architecture

- `chatchat_web`: HTTP, LiveView admin, OpenAPI
- `chatchat_tcp`: TCP protocol, presence, delivery
- `chatchat_broker`: domain and PostgreSQL
- `chatchat_auth`: tokens
- `chatchat_client`: simulation
- HAProxy: TCP balancing
- Redis: expiring session presence and node routing only
- PostgreSQL: users and offline messages

## Start up

Create and migrate the database:
```sh
mix ecto.create
mix ecto.migrate
mix phx.server
```

## API documentation

```text
/admin/swaggerui
/admin/openapi
/admin/tcp-protocol
```

## Admin dashboard

Create an administrator account
```sh
mix chatchat.admin.create admin
```

Dashboard: `http://localhost:4000/admin`

## Message delivery architecture

[Message delivery flow](MESSAGE_DELIVERY.md)

[Delivery architecture goal](MESSAGE_DELIVERY_GOAL.md)

## Metrics

- Prometheus: http://localhost:9090
- Grafana: http://localhost:3000 (`admin` / `admin`)
- Web application metrics: http://localhost:4000/metrics
- TCP application metrics: discovered per replica by Prometheus
- HAProxy metrics: http://localhost:8404/metrics

## TCP load balancing

Docker Compose runs scalable `chatchat_tcp` replicas behind HAProxy. Clients always connect to
`localhost:4040`; containers use `haproxy:4040`. HAProxy checks each replica's `/metrics` endpoint
and sends each new long-lived connection to the replica with the fewest active connections. Docker
DNS lets HAProxy and Prometheus add and remove replicas without hard-coded container names.

```text
client -> HAProxy :4040 -> tcp replica 1 :4040
                       -> tcp replica 2 :4040
                       -> ...
```

Start the local stack normally:

```sh
export TCP_CLUSTER_COOKIE="$(openssl rand -hex 32)"
docker compose up -d --build --scale tcp=2
```

Keep the same private cookie when changing the replica count. TCP releases use unique
`chatchat_tcp@<container-address>` BEAM names and `libcluster` DNS polling of the `tcp` service.
Redis routes resolve only against the local node and connected cluster nodes; untrusted route
strings never become atoms. Single-node Mix development needs no discovery configuration.

BEAM distribution authenticates with the shared cookie but is not encrypted by default. Keep
TCP replicas, Docker DNS, EPMD (4369), and distribution (9100) on a trusted private network;
these ports are not published to the host. For traffic crossing an untrusted network, configure
Erlang distribution TLS (`-proto_dist inet_tls` and `-ssl_dist_optfile`) with peer certificate
verification before deployment. Do not expose distribution ports or log cookies.

Presence supports one active connection per user. A second connection receives `already_connected`.
Session leases expire after 30 seconds and renew every 10 seconds; failed renewal closes the
connection. Stale cleanup cannot remove a newer session.

Dedicated disposable integration services:

```sh
docker compose -p chatchat-delivery-tests -f docker-compose.test.yml up -d --wait
export TEST_DATABASE_URL=ecto://chatchat:chatchat@localhost:15432/chatchat_test
export TEST_REDIS_URL=redis://localhost:16379/15
MIX_ENV=test mix ecto.migrate
```

The isolated two-node discovery fixture starts no ChatChat applications:

```sh
MIX_ENV=test elixir --name chatchat_check@127.0.0.1 -S mix run --no-start scripts/check_tcp_cluster.exs
```

Change the replica count without editing HAProxy or Prometheus:

```sh
docker compose up -d --scale tcp=4
```

Prometheus scrapes every discovered TCP replica separately, while Grafana aggregates their metrics.
HAProxy's own connection and backend-health metrics are also scraped.

## Client simulation

Start the application with IEx:

```sh
iex -S mix phx.server
```

Start with a small simulation and increase the number of clients progressively:

```elixir
simulation =
  ChatchatClient.simulate(%{
    number_of_clients: 1000,
    send_message_probability_per_second: 0.5,
    disconnection_probability_per_second: 0.1
  })
```

The simulator first creates, authenticates, and connects every requested client. Only after all
clients are ready does the simulation enter its running phase and start the duration timer. During
that phase, every client independently evaluates once per second whether to send one message and
whether to temporarily disconnect. Disconnected clients reconnect automatically.

Inspect or stop the simulation:

```elixir
ChatchatClient.simulation_status(simulation)
ChatchatClient.stop_simulation(simulation)
```

Optional settings:

```elixir
%{
  creation_concurrency: 40,
  ramp_interval_ms: 0,
  duration_seconds: :infinity,
  message_payload_size: 32
}
```

### Docker load test

```sh
LOAD_TEST_RUN_ID=run-1 LOADGEN_PARTICIPANTS=4 \
docker compose --profile loadtest up -d --build --scale tcp=2 --scale loadgen=4
```

Provision runs migrations, creates 150k users, and clears this run's barrier. Each generator starts
20k clients; traffic starts after all four shards connect.

## Durable mocked-client state

`ChatchatClient.send_message/3` returns `{:ok, message_id}` after local outbox commit:
this means queued. A matching server `ok` confirms receipt or PostgreSQL commit and removes
that outbox entry. Failed, disconnected, and unknown outcomes retry with the same identity.
Permanent rejections remain available through `ChatchatClient.Store.outbox/2`.

Interactive development uses `.client-state/interactive.sqlite3`. Releases require
`CLIENT_STATE_ROOT` and `CLIENT_STATE_NAMESPACE`; reuse both across restarts. Simulation
runs select isolated namespaces, with at most 16 concurrent runs. Load-generator shards
persist their assignment in their namespace. Keep the state volume for recovery.
Inbox deduplication is retained indefinitely. Disconnect never clears durable state.
After correcting a protocol error, explicitly call `ChatchatClient.Store.resume(store, user_id)`
to resume a suspended user. Remove namespace files only after stopping their store and
intentionally abandoning that run's recovery and deduplication history.

Dedicated integration services are defined in `docker-compose.test.yml` (PostgreSQL port
15432 and Redis port 16379, DB 15). Set `TEST_DATABASE_URL` and `TEST_REDIS_URL` to these
isolated services and run `MIX_ENV=test mix ecto.migrate` before integration tests.
