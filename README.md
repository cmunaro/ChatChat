# ChatChat

Elixir distributed real-time chat exercise.

## Features

- [x] Register and ogin
- [x] Search users
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
  - [x] Api documentation
- [ ] High-load client simulation
- [ ] User discovery by username or invite
- [ ] Conversation membership and authorization
- [x] Online presence
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
  - [x] Connect and disconnect with authentication
  - [ ] Reconnect
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

## Architecture goal so far

chatchat_web (multi instance): HTTP API, LiveView admin, OpenAPI

chatchat_tcp (multi instance): Persistent TCP connections, protocol handling

chatchat_broker (multi instance): Domain logic, authorization, Ecto persistence

chatchat_auth (library): Shared token issuing and verification

chatchat_simulator (multi instance): Load-test clients

postgres db: Shared PostgreSQL database

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

## TCP authentication

The TCP listener uses port `4040`. Each frame is JSON followed by a newline. The first frame must
contain the access token returned by the login API:

```json
{"type":"authenticate","token":"ACCESS_TOKEN"}
```

On success, the server keeps the connection open and replies:

```json
{"type":"authenticated","user_id":42}
```

An invalid token, a missing authentication frame, or a second authentication attempt returns an
error frame and closes the connection. The user is considered online while at least one of their
authenticated TCP connections is alive.
