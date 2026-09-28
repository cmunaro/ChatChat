defmodule ChatchatWeb.Admin.OverviewLive do
  @moduledoc false

  use Phoenix.LiveView, layout: {ChatchatWeb.Layouts, :app}

  alias ChatchatBroker.Accounts

  @refresh_interval 5_000
  @message_topic "admin:messages"
  @maximum_edges 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      schedule_refresh()
      Phoenix.PubSub.subscribe(ChatchatWeb.PubSub, @message_topic)
    end

    socket =
      assign(socket,
        search_query: "",
        search_results: [],
        search_error: nil,
        messages_open: false,
        message_edges: %{}
      )

    {:ok, refresh(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, refresh(socket)}
  end

  def handle_info({:message_admitted, event}, socket) do
    {:noreply, update_message_graph(socket, event)}
  end

  @impl true
  def handle_event("toggle_messages", _params, socket) do
    {:noreply, update(socket, :messages_open, &(!&1))}
  end

  @impl true
  def handle_event("search", %{"name" => name}, socket) do
    case Accounts.search_user(name) do
      {:ok, users} ->
        {:noreply, assign(socket, search_query: name, search_results: users, search_error: nil)}

      {:error, message} ->
        {:noreply, assign(socket, search_query: name, search_results: [], search_error: message)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="admin-shell">
      <header class="page-header">
        <div>
          <p class="eyebrow">ChatChat Admin</p>
          <h1>System overview</h1>
          <p class="subtitle">A live view of accounts and the message-delivery pipeline.</p>
        </div>
        <div class="header-actions">
          <div class="live-status">
            <span class="status-dot"></span>
            Live · updated <time id="last-updated"><%= format_time(@stats.updated_at) %></time>
          </div>
          <form method="post" action="/admin/logout">
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <button class="logout-button" type="submit">Sign out</button>
          </form>
        </div>
      </header>

      <section class="metric-grid" aria-label="System metrics">
        <.metric_card
          id="registered-users"
          label="Registered users"
          value={@stats.registered_users}
          detail="Accounts in PostgreSQL"
        />
        <.metric_card
          id="online-users"
          label="Online users"
          value={@stats.online_users}
          detail="Connected TCP clients across all nodes"
        />
        <.metric_card
          id="messages-in-delivery"
          label="Messages in delivery"
          value={@stats.messages_in_delivery}
          detail="Redis and PostgreSQL backlog"
        />
        <.metric_card
          id="messages-in-database"
          label="Messages in delivery DB"
          value={@stats.messages_in_database}
          detail="Undelivered messages persisted in PostgreSQL"
        />
      </section>

      <section id="live-messages" class="live-messages-section">
        <button
          id="live-messages-toggle"
          type="button"
          class="live-messages-summary"
          phx-click="toggle_messages"
          aria-expanded={to_string(@messages_open)}
          aria-controls="live-message-graph"
        >
          <div class="live-messages-title">
            <span class={[@messages_open && "open", "disclosure-icon"]} aria-hidden="true"></span>
            <div>
              <p class="eyebrow">Traffic</p>
              <h2>Live messages</h2>
            </div>
          </div>
          <div class="stream-state">
            <span class="status-dot"></span>
            <%= message_stream_label(@message_edges) %>
          </div>
        </button>

        <div
          :if={@messages_open}
          id="live-message-graph"
          class="message-graph"
          aria-label="Live message graph"
        >
          <div :if={map_size(@message_edges) == 0} class="graph-empty-state">
            <div class="empty-node" aria-hidden="true">●</div>
            <h3>No messages observed yet</h3>
            <p>
              Users and message paths will appear here as traffic passes through the TCP service.
            </p>
          </div>

          <div :if={map_size(@message_edges) > 0} class="message-flows">
            <div
              :for={{{left_id, right_id}, edge} <- sorted_edges(@message_edges)}
              id={"pair-#{left_id}-#{right_id}"}
              class="message-flow"
            >
              <div class="client-node">
                <span class="client-state online"></span>
                <strong><%= left_id %></strong>
                <small>Client</small>
              </div>
              <div class="message-directions">
                <.message_edge
                  direction="right"
                  from={left_id}
                  to={right_id}
                  edge={direction(edge, left_id, right_id)}
                />
                <.message_edge
                  direction="left"
                  from={right_id}
                  to={left_id}
                  edge={direction(edge, right_id, left_id)}
                />
              </div>
              <div class="client-node">
                <span class="client-state unknown"></span>
                <strong><%= right_id %></strong>
                <small>Client</small>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section class="users-section" aria-labelledby="users-heading">
        <div class="section-heading">
          <div>
            <p class="eyebrow">Accounts</p>
            <h2 id="users-heading">User search</h2>
          </div>
          <p>Searches are limited to 20 results.</p>
        </div>

        <form id="user-search-form" phx-submit="search" class="search-form">
          <label class="sr-only" for="user-search">Username</label>
          <input
            id="user-search"
            type="search"
            name="name"
            value={@search_query}
            placeholder="Search by username"
            autocomplete="off"
            minlength="3"
            required
          />
          <button type="submit">Search</button>
        </form>

        <p :if={@search_error} id="user-search-error" class="search-message error" role="alert">
          <%= @search_error %>
        </p>

        <div :if={@search_results != []} class="users-table-wrapper">
          <table id="user-search-results">
            <thead>
              <tr><th scope="col">ID</th><th scope="col">Username</th></tr>
            </thead>
            <tbody>
              <tr :for={user <- @search_results} id={"user-#{user.id}"}>
                <td><%= user.id %></td>
                <td><%= user.username %></td>
              </tr>
            </tbody>
          </table>
        </div>

        <p
          :if={@search_query != "" and is_nil(@search_error) and @search_results == []}
          class="search-message"
        >
          No users found.
        </p>
      </section>
    </main>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, default: nil
  attr :detail, :string, required: true

  defp metric_card(assigns) do
    ~H"""
    <article id={@id} class="metric-card">
      <p class="metric-label"><%= @label %></p>
      <p class={["metric-value", is_nil(@value) && "unavailable"]}>
        <%= format_value(@value) %>
      </p>
      <p class="metric-detail"><%= @detail %></p>
    </article>
    """
  end

  attr :direction, :string, required: true
  attr :from, :integer, required: true
  attr :to, :integer, required: true
  attr :edge, :map, default: nil

  defp message_edge(assigns) do
    ~H"""
    <div
      :if={@edge}
      id={"edge-#{@from}-#{@to}-#{@edge.count}"}
      class={["message-edge", "direction-#{@direction}"]}
      aria-label={"#{@from} to #{@to}: #{@edge.count} messages"}
    >
      <span :if={@direction == "left"} class="edge-arrow" aria-hidden="true">‹</span>
      <span class="edge-line"></span>
      <span :if={@direction == "right"} class="edge-arrow" aria-hidden="true">›</span>
      <span class="edge-count"><%= @edge.count %></span>
    </div>
    """
  end

  defp refresh(socket) do
    stats_module = Application.get_env(:chatchat_web, :admin_stats, ChatchatWeb.Admin.Stats)

    socket
    |> normalize_message_graph()
    |> assign(:stats, stats_module.load())
  end

  defp update_message_graph(socket, event) do
    socket = normalize_message_graph(socket)
    pair_key = ordered_pair(event.sender_id, event.recipient_id)
    direction_key = {event.sender_id, event.recipient_id}
    pair = Map.get(socket.assigns.message_edges, pair_key, %{directions: %{}})
    previous = Map.get(pair.directions, direction_key, %{count: 0})
    now = System.monotonic_time()

    direction = %{
      count: previous.count + 1,
      last_seen: now,
      message_id: event.message_id
    }

    edge = %{directions: Map.put(pair.directions, direction_key, direction), last_seen: now}

    edges =
      socket.assigns.message_edges
      |> Map.put(pair_key, edge)
      |> trim_edges()

    assign(socket, :message_edges, edges)
  end

  defp normalize_message_graph(%{assigns: %{message_edges: edges}} = socket) do
    assign(socket, :message_edges, normalize_edges(edges))
  end

  defp normalize_message_graph(socket), do: socket

  defp normalize_edges(edges) do
    Enum.reduce(edges, %{}, fn
      {_pair_key, %{directions: directions}}, normalized ->
        Enum.reduce(directions, normalized, fn {direction_key, edge}, pairs ->
          put_direction(pairs, direction_key, edge)
        end)

      {direction_key, edge}, normalized ->
        put_direction(normalized, direction_key, edge)
    end)
  end

  defp put_direction(edges, {sender_id, recipient_id} = direction_key, direction) do
    pair_key = ordered_pair(sender_id, recipient_id)
    pair = Map.get(edges, pair_key, %{directions: %{}, last_seen: direction.last_seen})
    existing = Map.get(pair.directions, direction_key)
    direction = newest_direction(existing, direction)

    Map.put(edges, pair_key, %{
      directions: Map.put(pair.directions, direction_key, direction),
      last_seen: max(pair.last_seen, direction.last_seen)
    })
  end

  defp newest_direction(nil, direction), do: direction

  defp newest_direction(existing, direction) do
    if direction.last_seen > existing.last_seen, do: direction, else: existing
  end

  defp trim_edges(edges) when map_size(edges) <= @maximum_edges, do: edges

  defp trim_edges(edges) do
    {oldest_key, _edge} = Enum.min_by(edges, fn {_key, edge} -> edge.last_seen end)
    Map.delete(edges, oldest_key)
  end

  defp sorted_edges(edges) do
    Enum.sort_by(edges, fn {_key, edge} -> edge.last_seen end, :desc)
  end

  defp ordered_pair(first_id, second_id) when first_id <= second_id, do: {first_id, second_id}
  defp ordered_pair(first_id, second_id), do: {second_id, first_id}

  defp direction(edge, from, to), do: Map.get(edge.directions, {from, to})

  defp message_stream_label(edges) when map_size(edges) == 0, do: "Waiting for traffic"
  defp message_stream_label(edges), do: "#{map_size(edges)} active pairs"

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval)
  defp format_value(nil), do: "Unavailable"
  defp format_value(value), do: Integer.to_string(value)
  defp format_time(datetime), do: Calendar.strftime(datetime, "%H:%M:%S UTC")
end
