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
- [ ] Pub/sub messaging
  - [ ] Phoenix PubSub on a single node
  - [ ] Redis PubSub across nodes
  - [ ] REST, PubSub and RPC boundaries
- [ ] API documentation with OpenAPI Spex
  - [x] Request and response schemas
  - [x] OpenAPI specification
  - [ ] Swagger UI in admin
- [x] Bounded delivery and global admission limit
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
- Redis: presence, admission, transient messages
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
docker compose up -d --build --scale tcp=2
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
