# ChatChat

Elixir distributed real-time chat exercise.

## Features

- [x] Register and ogin
- [x] Search users
- [~] 1to1 chats
- [ ] Group chats
- [~] Send text, images and files
- [ ] React to messages
- [ ] Edit messages
- [ ] Delete messages
- [ ] Store and retry undelivered messages
- [ ] Admin dashboard
  - [ ] Live connections
  - [ ] Delivery statistics
  - [ ] Latency, mailbox and bottleneck metrics
  - [ ] Entity management
  - [x] Api documentation
- [ ] High-load client simulation
- [x] User discovery by username
- [ ] Conversation membership and authorization
- [x] Online presence
- [ ] Offline message delivery
- [ ] Groups
  - [ ] Creation
  - [ ] Deletion
  - [ ] Join
  - [ ] Exit

## Implementation

- [ ] Release-based Docker images
- [~] Docker Compose development environment
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
- [ ] Backpressure handling
- [ ] Multi-node and high-load simulations
- [~] GitHub Actions
  - [x] Unit and integration tests
  - [~] Format and Credo checks
  - [~] Images published to GitHub image registry
- [x] Latest Elixir/Erlang versions pinned with mise
- [ ] Horizontal autoscaling experiment
- [~] Logs
  - [ ] Loki http traces
  - [x] Grafana dashboards
- [ ] Node-local caching with ConCache

## Architecture goal so far

chatchat_web (multi instance): HTTP API, LiveView admin, OpenAPI

chatchat_tcp (multi instance): Persistent TCP connections, protocol handling

chatchat_broker (multi instance): Domain logic, authorization, Ecto persistence

chatchat_auth (library): Shared token issuing and verification

chatchat_client (multi instance): Load-test clients

postgres db: Shared PostgreSQL database

redis: Short lived data persistence

## Start up

Create and migrate the database:
```sh
mix ecto.create
mix ecto.migrate
mix phx.server
```

## API documentation

```text
/swaggerui
/openapi
```

## Message delivery architecture

[Message delivery flow](MESSAGE_DELIVERY.md)

## Metrics

- Prometheus: http://localhost:9090
- Grafana: http://localhost:3000 (`admin` / `admin`)
- Web application metrics: http://localhost:4000/metrics
- TCP application metrics: http://localhost:9568/metrics

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

Every client independently evaluates once per second whether to send one message and whether to
temporarily disconnect. Disconnected clients reconnect automatically.

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
