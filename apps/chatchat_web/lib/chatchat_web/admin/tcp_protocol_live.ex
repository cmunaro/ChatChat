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
        The client must authenticate first. Message submission uses two acknowledgements:
        <code>message_admitted</code> assigns the ID, then <code>message_accepted_ack</code>
        confirms it. Delivery is at least once until the receiver sends
        <code>message_delivered_ack</code>.
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
        frame("send_message", "Client → server", "Requests delivery capacity.", %{
          type: "send_message",
          request_id: "7a724ef9-c670-49e2-b992-bd8ceff94d24",
          user_id: 11,
          message: "Hello"
        }),
        frame(
          "message_admitted",
          "Server → client",
          "Reserves capacity and assigns the message ID.",
          %{
            type: "message_admitted",
            request_id: "7a724ef9-c670-49e2-b992-bd8ceff94d24",
            message_id: "c3945190-a81c-4c80-912f-9bfc788d0651"
          }
        ),
        frame("message_accepted_ack", "Client → server", "Confirms the assigned message ID.", %{
          type: "message_accepted_ack",
          request_id: "7a724ef9-c670-49e2-b992-bd8ceff94d24",
          message_id: "c3945190-a81c-4c80-912f-9bfc788d0651"
        })
      ]),
      group("Message delivery", [
        frame("message", "Server → client", "Delivers a message; deduplicate by message_id.", %{
          type: "message",
          message_id: "c3945190-a81c-4c80-912f-9bfc788d0651",
          from_user_id: 10,
          message: "Hello"
        }),
        frame(
          "message_delivered_ack",
          "Client → server",
          "Completes delivery and releases capacity.",
          %{
            type: "message_delivered_ack",
            message_id: "c3945190-a81c-4c80-912f-9bfc788d0651"
          }
        )
      ]),
      group("Errors", [
        frame("error", "Server → client", "Reports a protocol or admission error.", %{
          type: "error",
          error: "overloaded",
          request_id: "7a724ef9-c670-49e2-b992-bd8ceff94d24"
        })
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
