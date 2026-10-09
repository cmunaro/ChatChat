# ChatChat agent guide

@/Users/cmunaro/.codex/RTK.md

## Context and ownership

Elixir/OTP umbrella; use tool versions in `mise.toml`. Run Mix commands from the repository root.

- `apps/chatchat_web`: Phoenix HTTP, LiveView admin, authentication plugs, OpenAPI.
- `apps/chatchat_tcp`: TCP framing, authenticated connections, Redis presence/admission/delivery/persistence.
- `apps/chatchat_broker`: domain rules, accounts, Ecto/PostgreSQL storage and migrations.
- `apps/chatchat_auth`: token creation and verification.
- `apps/chatchat_client`: client sockets and load simulation.

Read `README.md` for setup; read `MESSAGE_DELIVERY.md` before changing message lifecycle. Consult affected code/tests and `config/` for actual behavior; README checkboxes are not authoritative.

## Work efficiently

- Search with `rg`; read relevant files/ranges, not entire directories. Batch independent reads. Exclude `_build/`, `deps/`, `.git/` and generated output from broad searches.
- Trace the affected flow and invariants before editing. Reuse existing behavior, then extend its owning module; prefer standard tools/dependencies before adding abstractions.
- Make the simplest complete change. Keep responsibilities in their app; avoid duplicate logic, speculative features, new dependencies without need, and unrelated cleanup.
- Keep updates and final reports brief: result, meaningful verification, remaining limitations. Do not repeat code or command output.
- Preserve unrelated user changes. Never print secrets from `.env` or runtime configuration. Do not reset data, run load provisioning, or launch large simulations without explicit authorization.

## Stability invariants

- Derive identity from authenticated state. Validate untrusted HTTP/TCP input; preserve frame limits, timeouts, authorization and receiver-scoped ACKs.
- Delivery is at least once with stable `message_id` deduplication. Preserve atomic Redis transitions, admission capacity accounting, recoverable persistence claims, and cleanup only after PostgreSQL commit.
- Keep queues, worker concurrency, queries and batches bounded. Preserve retry/crash recovery and multi-node behavior; avoid blocking connection handlers or keyspace-wide scans.
- Use existing OTP supervision and Ecto patterns. Add migrations rather than rewriting applied migrations. Treat protocol, API, schema and Redis-key changes as compatibility changes; update affected consumers, tests and documentation together.

## Verification

- For behavior changes, add focused regression coverage at the responsible layer, including relevant failure/retry cases. Documentation-only edits need no runtime tests.
- Start with affected tests: `mix test apps/<app>/test/<file>.exs`. Broaden to `mix test` for cross-app changes.
- CI checks: `mix format --check-formatted`, `mix credo --min-priority high`, `MIX_ENV=test mix compile --warnings-as-errors`, `mix test`.
- Integration tests require PostgreSQL and Redis. Use `TEST_DATABASE_URL` pointing to a dedicated test database and `TEST_REDIS_URL` pointing to an isolated test Redis DB (default `/15`); run `MIX_ENV=test mix ecto.migrate` before database tests. Never point tests at production/shared data.
- Run the smallest sufficient checks; report failures or unavailable services explicitly. Do not claim unrun checks passed.
