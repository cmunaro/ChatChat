# Message delivery sequence

## 1. Message admission and sender confirmation

```mermaid
sequenceDiagram
    participant C1
    participant BE
    participant Redis
    C1->>C1: Persist Message + RequestId + C2 locally
    C1->>BE: Message + RequestId + C2
    BE->>BE: Read C1 from authenticated socket
    BE->>Redis: Create or find request atomically

    alt RequestId is new
        Redis->>Redis: Generate MessageId and store complete message
        Redis-->>BE: MessageId + awaiting_sender_ack
    else RequestId matches the existing message
        Redis-->>BE: Existing MessageId + current state
    else RequestId belongs to different content
        Redis-->>BE: Idempotency conflict
        BE-->>C1: Reject RequestId
    end

    alt Request accepted and current state is not aborted
        loop Retry until ACK confirmation or admission deadline
            BE-->>C1: RequestId + MessageId

            alt C1 receives the response
                C1->>C1: Persist RequestId to MessageId mapping locally
                C1->>BE: message_accepted_ack + MessageId
                BE->>BE: Validate C1 and request ownership
                BE->>Redis: CAS awaiting_sender_ack to ready_for_delivery
                Redis-->>BE: State changed or already ready
                BE-->>C1: message_accepted_ack_confirmed + MessageId
            else Response, ACK, or ACK confirmation is lost
                C1->>BE: Retry same RequestId or repeat acceptance ACK
                BE->>Redis: Find request and current state owned by C1
                Redis-->>BE: Same MessageId + current state
            end
        end

        alt State is ready_for_delivery
            BE->>Redis: Hand off to online delivery
        else Admission deadline expires
            BE->>Redis: CAS awaiting_sender_ack to aborted and retain RequestId tombstone
            BE-->>C1: RequestId + MessageId + admission_aborted
            C1->>C1: Mark attempt aborted and require a new RequestId for resend
        end
    else Request is already aborted
        BE-->>C1: RequestId + MessageId + admission_aborted
        C1->>C1: Mark attempt aborted
    else Request rejected by idempotency conflict
        BE->>BE: Stop processing request
    end
```

## 2. Immediate delivery to an online recipient

```mermaid
sequenceDiagram
    participant C1
    participant BE
    participant Redis
    participant C2
    participant DB

    BE->>Redis: Find C2 connections and claim MessageId lease with fencing token

    alt C2 connection exists
        Redis-->>BE: Connection owner + delivery lease
        BE->>C2: Message + MessageId + C1

        alt C2 ACK arrives before lease expiry
            C2->>BE: message_delivered_ack + MessageId
            BE->>BE: Validate C2 owns the delivery
            BE->>Redis: With fencing token mark delivered, delete ciphertext, create next ResultId and ResultVersion
            Redis-->>BE: Delivery committed
            BE-->>C2: delivery_ack_confirmed + MessageId
            BE->>BE: Start receipt delivery for ResultId
        else Send fails or lease expires
            BE->>Redis: CAS message to transferring_to_db
            BE->>DB: Atomically upsert RequestId, pending message, queued ResultId and ResultVersion
            DB-->>BE: Message and result committed
            BE->>Redis: Mark DB as owner and delete ciphertext and delivery lease
            BE->>BE: Start receipt delivery for ResultId
        end
    else C2 has no connection
        Redis-->>BE: Offline
        BE->>Redis: CAS message to transferring_to_db
        BE->>DB: Atomically upsert RequestId, pending message, queued ResultId and ResultVersion
        DB-->>BE: Message and result committed
        BE->>Redis: Mark DB as owner and delete ciphertext
        BE->>BE: Start receipt delivery for ResultId
    end
```

## 3. Late recipient ACK after database fallback

```mermaid
sequenceDiagram
    participant C2
    participant BE
    participant Redis
    participant DB

    C2->>BE: message_delivered_ack + MessageId
    BE->>BE: Validate authenticated user is C2
    BE->>Redis: Read MessageId storage location and current state

    alt PostgreSQL owns a pending message
        BE->>DB: Conditionally change pending to delivered and create the next result in one transaction
        DB-->>BE: Canonical delivered state + ResultId + ResultVersion
        BE->>Redis: Invalidate any queued result version 1
        BE->>Redis: Close expired delivery lease
        BE-->>C2: delivery_ack_confirmed + MessageId
        BE->>BE: Start receipt delivery for ResultId
    else Redis still owns the message and its server-side delivery attempt has the current fencing token
        BE->>Redis: Mark delivered, delete ciphertext, create next ResultId and ResultVersion atomically
        Redis-->>BE: Delivery committed
        BE-->>C2: delivery_ack_confirmed + MessageId
        BE->>BE: Start receipt delivery for ResultId
    else Message is transferring to PostgreSQL
        BE->>DB: Resolve committed transfer, then conditionally apply ACK to the authoritative copy
        DB-->>BE: Canonical delivered state + ResultId + ResultVersion
        BE->>Redis: Finish transfer metadata and invalidate superseded result
        BE-->>C2: delivery_ack_confirmed + MessageId
    else Message was already marked delivered in its authoritative store
        BE-->>C2: delivery_ack_confirmed + MessageId
    else Message does not belong to C2
        BE-->>C2: Invalid delivery ACK
    end
```

## 4. Delivery of messages stored for an offline recipient

```mermaid
sequenceDiagram
    participant C2
    participant BE
    participant DB
    participant Redis

    C2->>BE: Connect and authenticate
    BE->>Redis: Read ready C2 messages, expired leases, and ownership metadata
    Redis-->>BE: Redis candidates
    BE->>DB: Read pending C2 messages and transfer records
    DB-->>BE: PostgreSQL candidates
    BE->>BE: Reconcile by MessageId and authoritative owner
    BE->>Redis: Atomically acquire dispatch ownership epochs for reconciled MessageIds
    Redis-->>BE: Won MessageIds + ownership epochs
    BE->>Redis: Claim won Redis-owned messages with fencing tokens
    BE->>DB: Claim won PostgreSQL-owned messages using the same ownership epochs

    loop Each claimed message
        BE->>C2: Message + MessageId + C1

        alt C2 ACK arrives before lease expiry
            C2->>BE: message_delivered_ack + MessageId
            BE->>BE: Validate C2 owns the delivery
            alt Redis owns MessageId
                BE->>Redis: With fencing token mark delivered, delete ciphertext, create next ResultId and ResultVersion
                Redis-->>BE: Delivery committed
            else PostgreSQL owns MessageId
                BE->>DB: With fencing token delete ciphertext, retire older result payloads, retain their ACK tombstones, and create next ResultId and ResultVersion
                DB-->>BE: Delivery committed
                BE->>Redis: Invalidate any queued result version 1
            end
            BE-->>C2: delivery_ack_confirmed + MessageId
            BE->>BE: Start receipt delivery for ResultId
        else Send fails or lease expires
            BE->>BE: Release the lease in the authoritative store and retain the message
        end
    end
```

## 5. Duplicate delivery after a lost recipient ACK

```mermaid
sequenceDiagram
    participant BE
    participant C2
    BE->>C2: Message + existing MessageId + C1
    C2->>C2: Find MessageId in local state

    alt MessageId was already processed
        C2->>BE: Repeat message_delivered_ack + MessageId
    else MessageId is new
        C2->>C2: Persist MessageId and message locally
        C2->>BE: message_delivered_ack + MessageId
    end

    BE-->>C2: delivery_ack_confirmed + MessageId
```

## 6. Delivery result to the sender

`ResultId` identifies a specific result transition. The first result has version 1. A queued
message may later produce a delivered result with the next version.

```mermaid
sequenceDiagram
    participant C1
    participant BE
    participant Redis
    participant DB

    BE->>Redis: Find C1 connection owner and ResultId ownership metadata

    alt C1 is online
        Redis-->>BE: C1 connection location
        alt Redis owns ResultId
            BE->>Redis: Claim ResultId lease with fencing token
        else PostgreSQL owns ResultId
            BE->>DB: Claim ResultId lease with fencing token
        end
        BE-->>C1: ResultId + MessageId + ResultVersion + result

        alt C1 ACK arrives before result lease expiry
            C1->>BE: delivery_result_ack + ResultId
            BE->>BE: Validate C1 owns ResultId
            alt Redis owns ResultId
                BE->>Redis: With fencing token mark acknowledged and retain tombstone
                BE->>DB: Delete stale matching result if present
            else PostgreSQL owns ResultId
                BE->>DB: With fencing token mark acknowledged, remove payload, retain tombstone
                BE->>Redis: Remove stale result payload if present
            end
            BE-->>C1: delivery_result_ack_confirmed + ResultId
        else Send fails or result lease expires
            alt Redis owns ResultId
                BE->>Redis: CAS result to transferring_to_db
                BE->>DB: Upsert ResultId + MessageId + result + C1
                DB-->>BE: Result committed
                BE->>Redis: Mark DB as owner and delete result payload
            else PostgreSQL owns ResultId
                BE->>DB: Release lease and retain result
            end
        end
    else C1 is offline
        Redis-->>BE: Offline
        alt Redis owns ResultId
            BE->>Redis: CAS result to transferring_to_db
            BE->>DB: Upsert ResultId + MessageId + result + C1
            DB-->>BE: Result committed
            BE->>Redis: Mark DB as owner and delete result payload
        else PostgreSQL owns ResultId
            BE->>DB: Retain pending result
        end
    end
```

## 7. Delivery of stored results when the sender reconnects

```mermaid
sequenceDiagram
    participant C1
    participant BE
    participant Redis
    participant DB

    C1->>BE: Connect and authenticate
    BE->>Redis: Read pending C1 results and ownership metadata
    Redis-->>BE: Redis result candidates
    BE->>DB: Read pending C1 results and transfer records
    DB-->>BE: PostgreSQL result candidates
    BE->>BE: Reconcile by ResultId and authoritative owner
    BE->>Redis: Atomically acquire dispatch ownership epochs for reconciled ResultIds
    Redis-->>BE: Won ResultIds + ownership epochs
    BE->>Redis: Claim won Redis-owned results with fencing tokens
    BE->>DB: Claim won PostgreSQL-owned results using the same ownership epochs

    loop Each claimed result
        BE-->>C1: ResultId + MessageId + ResultVersion + result

        alt C1 ACK arrives before lease expiry
            C1->>BE: delivery_result_ack + ResultId
            BE->>BE: Validate C1 owns ResultId
            alt Redis owns ResultId
                BE->>Redis: With fencing token mark acknowledged, remove payload, retain tombstone
            else PostgreSQL owns ResultId
                BE->>DB: With fencing token mark acknowledged, remove payload, retain tombstone
            end
            BE-->>C1: delivery_result_ack_confirmed + ResultId
        else Send fails or lease expires
            BE->>BE: Release the lease in the authoritative store and retain the result
        end
    end
```

## 8. Backend crash recovery

```mermaid
sequenceDiagram
    participant FailedBE
    participant Redis
    participant DB
    participant RecoveryBE

    FailedBE--xRedis: Connection lost
    RecoveryBE->>Redis: Read ready items, expired leases, and ownership metadata
    Redis-->>RecoveryBE: Redis recovery candidates
    RecoveryBE->>DB: Read expired leases and incomplete transfers
    DB-->>RecoveryBE: PostgreSQL recovery candidates
    RecoveryBE->>RecoveryBE: Reconcile candidates and resolve incomplete transfers
    RecoveryBE->>Redis: Atomically acquire new ownership epochs for recoverable identities
    Redis-->>RecoveryBE: Won identities + ownership epochs
    RecoveryBE->>Redis: Claim won Redis-owned items with new fencing tokens
    RecoveryBE->>DB: Claim won PostgreSQL-owned items using the same epochs and new fencing tokens
    RecoveryBE->>RecoveryBE: Resume the phase recorded with each item
```

## 9. Duplicate or reordered delivery results

```mermaid
sequenceDiagram
    participant BE
    participant C1
    BE-->>C1: ResultId + MessageId + ResultVersion + result
    C1->>C1: Read processed ResultIds and highest ResultVersion from local state

    alt ResultId was already processed
        C1->>BE: Repeat delivery_result_ack + ResultId
        BE-->>C1: delivery_result_ack_confirmed + ResultId
    else ResultVersion is older than stored version
        C1->>BE: delivery_result_ack + ResultId
        BE-->>C1: delivery_result_ack_confirmed + ResultId
    else ResultVersion is new
        C1->>C1: Persist result and highest ResultVersion atomically
        C1->>BE: delivery_result_ack + ResultId
        BE-->>C1: delivery_result_ack_confirmed + ResultId
    end
```

## Required identities

- `(C1, RequestId)` identifies one send attempt and is used only for admission retries.
- `MessageId` is generated by the backend and identifies the message through every delivery attempt.
- `ResultId` identifies one delivery-state notification, preventing a delayed `not_delivered` ACK from deleting a later `delivered` result.
- `ResultVersion` is monotonic per message. C1 ignores results older than the highest version it has already applied.
- Creating a newer result retires delivery of older result payloads but preserves every older ResultId as an ACKable tombstone. An ACK already in flight therefore still receives confirmation and cannot affect the newer result.
- Redis creation of a new request must atomically generate `MessageId`, store the complete message, and create the idempotency mapping.
- PostgreSQL operations use unique `MessageId`, `ResultId`, `(MessageId, ResultVersion)`, and `(C1, RequestId)` constraints so retries cannot create logical duplicates.
- An aborted `(C1, RequestId)` remains as a tombstone for at least as long as C1 may durably retry it. Reusing it cannot create a new message.
- Removing ciphertext never removes the idempotency record. Retries still return the same `MessageId` and terminal state.
- C1 persists processed `ResultId` and highest `ResultVersion` values before ACKing, so duplicated or reordered results are harmless.
- C1 persists the outgoing message before its first send and persists the `RequestId` to `MessageId` mapping before sending `message_accepted_ack`. A client restart can therefore resume admission without creating a new request.
- C1 does not consider admission complete until it receives `message_accepted_ack_confirmed`. Repeating either the original request or its acceptance ACK is idempotent.
- An `admission_aborted` response is terminal for that RequestId. C1 retains the tombstoned attempt for reconciliation and uses a new RequestId only for an explicit resend.
- After PostgreSQL commits a fallback, the Redis idempotency record points to PostgreSQL. Late ACK handling reads that location and uses PostgreSQL as the authoritative state.
- If the Redis location pointer is missing, BE resolves a retried `(C1, RequestId)` against PostgreSQL before creating a new message.
- If ResultId ownership metadata is missing or transitional, BE resolves the ResultId against PostgreSQL before claiming, acknowledging, or recreating the result.
- ACK handlers tolerate a temporary copy in both Redis and PostgreSQL. They update the authoritative state first and clean up the stale copy afterward.
- `ResultVersion` allocation is performed by whichever store currently owns the authoritative message state. A Redis-to-DB handoff persists the last allocated version in the same database transaction.
- A message-state transition atomically stores the generated ResultId and ResultVersion with the new state. Retrying that transition returns the stored result identity instead of allocating another result.
- The PostgreSQL `pending` to `delivered` change is a conditional transition, not a read followed by an update. Exactly one transaction creates the delivered result; concurrent or late ACK transactions read and return that canonical ResultId and ResultVersion.
- Acceptance and admission expiry use one atomic compare-and-set. Expiry may abort only `awaiting_sender_ack`; it cannot delete a message already ready for delivery.
- Every delivery lease has a monotonically increasing fencing token. A worker may change state only while its token is current, preventing an expired worker from overwriting its replacement.
- Fencing tokens are server-side state. Client ACKs contain only public identifiers; BE resolves the delivery attempt and token from the authenticated connection and rejects ACKs not associated with an attempt sent on that connection.
- Delivery-result leases also use fencing tokens. An expired receipt sender cannot recreate a DB result after C1 has already acknowledged it.
- Message transitions are monotonic. A PostgreSQL upsert may create or retain `pending`, but cannot change `delivered` back to `pending` during reconciliation.
- Terminal message metadata remains after ciphertext deletion for at least as long as C2 may durably retry an ACK or C1 may durably retry the request.
- Moving a message or result from Redis to PostgreSQL first changes its Redis state to `transferring_to_db`. ACK processing follows that state to the authoritative store instead of racing the transfer.
- Reconnect scans reconcile Redis and PostgreSQL candidates by identity before claiming them. A `MessageId` or `ResultId` may have only one authoritative lease, even while both stores temporarily contain payload copies.
- Reconciliation reads are not sufficient for exclusion. Before either store grants a delivery lease, BE must win one Redis-coordinated ownership epoch for that identity; PostgreSQL records that epoch with its lease and rejects work carrying an older epoch. Items in `transferring_to_db` are not dispatchable until ownership is resolved.
- Crash recovery follows the same ownership-epoch protocol as normal dispatch. Expired leases do not authorize independent PostgreSQL claims.
- Acknowledged ResultIds retain tombstones for at least as long as C1 may durably retry the ACK, as well as longer than every delivery and recovery lease. A delayed timeout cannot recreate an already acknowledged result.
- Retry retention is a protocol contract, not only a server cache policy. If clients may retry durable records without a time limit, the corresponding RequestId, MessageId, and ResultId tombstones cannot expire; bounded retention requires a client-visible retry deadline and client enforcement.
- When C2 authenticates, BE checks both Redis and PostgreSQL because Redis may contain accepted messages that were never transferred to PostgreSQL.
- BE does not acknowledge a new request unless Redis confirms the atomic message and idempotency write.
- C1 repeats `delivery_result_ack` until it receives `delivery_result_ack_confirmed`. BE answers repeated ACKs from the ResultId tombstone.
- A Redis-to-PostgreSQL transfer is recoverable when BE crashes after the DB commit but before updating Redis: `transferring_to_db` resolution checks PostgreSQL before retrying or rolling back.
- If PostgreSQL is unavailable during fallback, Redis retains the complete message and retries the handoff. BE cannot emit `not_delivered` until PostgreSQL commits it.
- Redis acknowledgement of a new message requires the configured durability level, including replication confirmation when failover without acknowledged-write loss is required.
- `BE` represents the backend cluster. Delivery to a connection owned by another node is routed to that owner while Redis retains the pending item and lease until the client ACK arrives.
- Delivery order is not guaranteed by `MessageId`. If chat ordering is required, BE must also assign a monotonic sequence per conversation and deliver pending messages in that order.
- The protocol must define whether delivery to any C2 connection or every C2 connection constitutes delivery. The diagrams assume one claimed C2 connection and one valid ACK is sufficient.
