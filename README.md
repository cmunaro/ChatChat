# ChatChat

Elixir distributed real-time chat exercise.

## Features

- [ ] 1to1 chats
- [ ] Group chats
- [ ] Send text, images and files
- [ ] React to messages
- [ ] Edit messages
- [ ] Delete messages
- [ ] Store and retry undelivered messages
- [ ] Admin dashboard
  - [ ] Live connections
  - [ ] Delivery statistics
  - [ ] Latency, mailbox and bottleneck metrics
  - [ ] Entity management
  - [ ] Api documentation
- [ ] High-load client simulation
- [ ] User discovery by username or invite
- [ ] Conversation membership and authorization
- [ ] Online presence
- [ ] Offline message delivery
- [ ] Groups
  - [ ] Creation
  - [ ] Deletion
  - [ ] Join
  - [ ] Exit

## Implementation

- [ ] Elixir umbrella with independent applications
  - [ ] OTP application per child app
  - [ ] Acyclic dependency graph
  - [ ] No orchestrator app
- [ ] Release-based Docker images
  - [ ] HTTP/admin node
  - [ ] Persistent TCP node
  - [ ] Simulated clients
- [ ] Docker Compose development environment
- [ ] Ecto SQL storage and migrations
- [ ] Phoenix HTTP API and LiveView admin
- [ ] Thousand Island custom encrypted protocol
  - [ ] Connect, disconnect and reconnect
- [ ] Pub/sub messaging
  - [ ] Phoenix PubSub on a single node
  - [ ] Redis PubSub across nodes
  - [ ] REST, PubSub and RPC boundaries
- [ ] API documentation with OpenAPI Spex
  - [ ] Request and response schemas
  - [ ] OpenAPI specification
  - [ ] Swagger UI in admin
- [ ] Backpressure handling
- [ ] Multi-node and high-load simulations
- [ ] GitHub Actions
  - [ ] Unit and integration tests
  - [ ] Format and Credo checks
  - [ ] Images published to GitHub image registry
- [ ] Latest Elixir/Erlang versions pinned with mise
- [ ] Horizontal autoscaling experiment
- [ ] Logs
  - [ ] Loki http traces
  - [ ] Grafana dashboards
- [ ] Node-local caching with ConCache
- [ ] API documentation with `open_api_spex`
  - [ ] Request and response schemas
  - [ ] Swagger UI

## Architecture goal so far

chatchat_web (multi instance): HTTP API, LiveView admin, OpenAPI

chatchat_tcp (multi instance): Persistent TCP connections, protocol handling

chatchat_broker (multi instance): Domain logic, authorization, Ecto persistence

chatchat_simulator (multi instance): Load-test clients

postgres db: Shared PostgreSQL database

## Start up

Create and migrate the database:
```sh
mix ecto.create
mix ecto.migrate
mix phx.server
```
