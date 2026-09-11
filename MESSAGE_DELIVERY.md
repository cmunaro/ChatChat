# Message delivery

Messages remain in Redis for a 20-second online-delivery window. Messages not acknowledged during that window are moved to PostgreSQL for future delivery.

## Message acceptance

```mermaid
sequenceDiagram
    participant C1 as Sender
    participant BE as Backend
    participant Redis

    C1->>BE: send_message(request_id, receiver_id, message)
    BE->>BE: Read sender_id from authenticated socket
    BE->>BE: Generate message_id
    BE->>Redis: SET chatchat:{admission}:pending:<sender_id>:<base64url(request_id)> PX admission_ttl
    Redis-->>BE: OK
    BE-->>C1: message_admitted(request_id, message_id)

    C1->>BE: message_accepted_ack(request_id, message_id)
    BE->>Redis: EVALSHA confirmation script

    alt Pending attribution matches
        Redis->>Redis: SET chatchat:message:<message_id>
        Redis->>Redis: SADD chatchat:sending:<receiver_id> message_id
        Redis->>Redis: ZADD chatchat:sending_deadlines now + 20 seconds
        Redis->>Redis: DEL pending entry
        Redis->>Redis: PUBLISH chatchat:delivery receiver_id
        Redis-->>BE: accepted
        BE-->>C1: message_accepted_ack_confirmed(message_id)
    else Pending entry expired or does not match
        Redis-->>BE: unknown
        BE-->>C1: error(unknown_message)
    end
```

The confirmation script creates these entries atomically:

```text
chatchat:message:<message_id>          -> complete admitted message
chatchat:sending:<receiver_id>         -> set of message_ids
chatchat:sending_deadlines             -> score: expires_at_ms, member: message_id
```

The pending entry remains keyed by `sender_id + request_id` because it identifies the sender's admission request. It is deleted when the message enters the sending state. Repeating the sender acknowledgement after that returns `unknown_message`.

The script is loaded at startup and called with `EVALSHA`. On `NOSCRIPT`, the backend loads it again and retries once.

## Delivery worker

```mermaid
sequenceDiagram
    participant Redis
    participant DW as Delivery worker
    participant C2 as Receiver

    Redis-->>DW: chatchat:delivery(receiver_id)

    alt Receiver is online
        DW->>C2: message(message_id, sender_id, payload)
        C2-->>DW: message_delivered_ack(message_id)
        DW->>Redis: Atomically delete message, receiver membership, and deadline
    else Receiver is offline
        DW->>Redis: Leave message until reconnect or deadline
    end

    opt Receiver connects while the message remains in Redis
        DW->>Redis: SMEMBERS chatchat:sending:<receiver_id>
        Redis-->>DW: Receiver message IDs
        DW->>Redis: Pipeline GET chatchat:message:<message_id>
        DW->>C2: Send each message
    end
```

The delivery worker subscribes to the Redis delivery channel. The same `wake(receiver_id)` path handles both Pub/Sub notifications and receiver authentication. It reads only that receiver's set and pipelines the corresponding message reads; it never scans the Redis keyspace.

The `message_id` is included in every delivery and acknowledgement. A successful acknowledgement sends no response to the client. It atomically removes the message, its receiver-set membership, and its deadline.

## Persistence worker

```mermaid
sequenceDiagram
    participant PW as Persistence worker
    participant Redis
    participant DB as PostgreSQL

    PW->>Redis: ZRANGEBYSCORE sending_deadlines -inf now LIMIT 0 batch_size
    Redis-->>PW: Only expired message keys

    loop Each bounded batch
        PW->>Redis: Atomically claim expired entries
        Redis-->>PW: Claimed payloads
        PW->>DB: Repo.insert_all(messages, on_conflict: nothing)

        alt PostgreSQL commit succeeds
            DB-->>PW: committed
            PW->>Redis: Delete claimed payloads and index entries
        else PostgreSQL fails
            DB-->>PW: error
            PW->>Redis: Release claims for retry
        end
    end
```

The worker never runs `SCAN`. The sorted set is the expiration index, so finding expired messages costs approximately `O(log N + batch_size)`.

Messages are handled in fixed-size batches:

1. Read expired members from `sending_deadlines`.
2. Atomically claim them so the delivery worker cannot start another delivery.
3. Fetch their payloads with a Redis pipeline.
4. Insert the batch with `Repo.insert_all/3`.
5. Use `message_id` as a PostgreSQL unique key and `on_conflict: :nothing`.
6. Remove Redis data only after PostgreSQL commits.

Claims must remain recoverable in Redis until the database commit. If the backend crashes, the persistence worker can reclaim stale claims. A recipient acknowledgement racing with persistence must be resolved idempotently against the claimed message.

When a query returns a full batch, the worker immediately requests another one. Otherwise, it reads the earliest deadline and schedules itself for that time instead of polling every second.

## PostgreSQL message

The stored record needs at least:

```text
message_id
sender_id
receiver_id
payload
inserted_at
```

`message_id` is unique. This makes retries safe if PostgreSQL commits but the backend crashes before cleaning Redis.
