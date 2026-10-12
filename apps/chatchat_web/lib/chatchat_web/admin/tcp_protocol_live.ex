defmodule ChatchatWeb.Admin.TcpProtocolLive do
  @moduledoc false

  use Phoenix.LiveView, layout: {ChatchatWeb.Layouts, :app}

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, groups: groups())}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="admin-shell">
      <header class="page-header">
        <div>
          <p class="eyebrow">ChatChat Admin</p>
          <h1>TCP protocol</h1>
          <p class="subtitle">Newline-delimited JSON frames exchanged on the persistent socket.</p>
        </div>
        <div class="header-actions">
          <a class="logout-button" href="/admin">Overview</a>
          <a class="logout-button" href="/admin/swaggerui">HTTP API</a>
        </div>
      </header>

      <div class="protocol-intro">
        Authenticate first. Commit the client outbox before sending its stable UUID.
        <code>message_result</code> reports durable receipt or committed PostgreSQL ownership
        (<code>ok</code>), retryable failure (<code>failed</code>), or permanent rejection
        (<code>rejected</code>). Save and deduplicate incoming messages by sender and message ID
        before sending <code>message_delivered_ack</code>. Frames are limited to 4,096 bytes.
      </div>

      <section :for={group <- @groups} class="protocol-group">
        <h2><%= group.name %></h2>
        <details :for={frame <- group.frames} class="protocol-frame">
          <summary>
            <span class="protocol-name"><%= frame.name %></span>
            <span class="protocol-direction"><%= frame.direction %></span>
            <span class="protocol-purpose"><%= frame.purpose %></span>
          </summary>
          <div class="protocol-body">
            <pre><code><%= frame.example %></code></pre>
          </div>
        </details>
      </section>
    </main>
    """
  end

  defp groups do
    [
      group("Connection", [
        frame("authenticate", "Client → server", "First frame; authenticates the socket.", %{
          type: "authenticate",
          token: "signed-access-token"
        }),
        frame("authenticated", "Server → client", "Confirms authentication.", %{
          type: "authenticated",
          user_id: 10
        }),
        frame("ping", "Client → server", "Checks that the connection is alive.", %{type: "ping"}),
        frame("pong", "Server → client", "Answers a ping.", %{type: "pong"})
      ]),
      group("Presence", [
        frame("is_online", "Client → server", "Checks whether a user is connected.", %{
          type: "is_online",
          user_id: 11
        }),
        frame("online status", "Server → client", "Returns the current presence state.", %{
          is_online: true
        })
      ]),
      group("Message submission", [
        frame(
          "send_message",
          "Client → server",
          "Sends a committed outbox entry; retries keep the message ID.",
          %{
            type: "send_message",
            request_id: "7a724ef9-c670-49e2-b992-bd8ceff94d24",
            message_id: "c3945190-a81c-4c80-912f-9bfc788d0651",
            user_id: 11,
            message: "Hello"
          }
        ),
        frame(
          "message_result",
          "Server → client",
          "Correlates both IDs: ok, failed, or rejected.",
          %{
            type: "message_result",
            request_id: "7a724ef9-c670-49e2-b992-bd8ceff94d24",
            message_id: "c3945190-a81c-4c80-912f-9bfc788d0651",
            status: "ok"
          }
        )
      ]),
      group("Message delivery", [
        frame(
          "message",
          "Server → client",
          "Save content and sender/message identity atomically before ACK.",
          %{
            type: "message",
            message_id: "c3945190-a81c-4c80-912f-9bfc788d0651",
            from_user_id: 10,
            message: "Hello",
            inserted_at: "2026-10-09T10:00:00.000000Z",
            receipt_id: "26df9a61-b860-4aa7-a982-fac892087538"
          }
        ),
        frame(
          "message_delivered_ack",
          "Client → server",
          "ACK saved duplicates too; receipt is session-scoped.",
          %{
            type: "message_delivered_ack",
            message_id: "c3945190-a81c-4c80-912f-9bfc788d0651",
            from_user_id: 10,
            receipt_id: "26df9a61-b860-4aa7-a982-fac892087538"
          }
        )
      ]),
      group("Message deletion", [
        frame(
          "delete_message",
          "Client → server",
          "Deletes an authenticated sender/message identity; retry with a fresh request ID.",
          %{
            type: "delete_message",
            request_id: "7a724ef9-c670-49e2-b992-bd8ceff94d24",
            message_id: "c3945190-a81c-4c80-912f-9bfc788d0651",
            user_id: 11
          }
        ),
        frame(
          "message_deleted",
          "Server → client",
          "Retain a sender/message tombstone before message_delivered_ack; ignore late content.",
          %{
            type: "message_deleted",
            from_user_id: 10,
            message_id: "c3945190-a81c-4c80-912f-9bfc788d0651",
            receipt_id: "26df9a61-b860-4aa7-a982-fac892087538"
          }
        )
      ]),
      group("Errors", [
        frame(
          "error",
          "Server → client",
          "Uncorrelated protocol error closes the socket and durably suspends client sends.",
          %{
            type: "error",
            error: "invalid_request"
          }
        )
      ])
    ]
  end

  defp group(name, frames), do: %{name: name, frames: frames}

  defp frame(name, direction, purpose, example) do
    %{
      name: name,
      direction: direction,
      purpose: purpose,
      example: Jason.encode!(example, pretty: true)
    }
  end
end
