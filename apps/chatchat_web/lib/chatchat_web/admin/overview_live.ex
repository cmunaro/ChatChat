defmodule ChatchatWeb.Admin.OverviewLive do
  @moduledoc false

  use Phoenix.LiveView, layout: {ChatchatWeb.Layouts, :app}

  alias ChatchatBroker.Accounts

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    socket = assign(socket, search_query: "", search_results: [], search_error: nil)

    {:ok, refresh(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, refresh(socket)}
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

  defp refresh(socket) do
    stats_module = Application.get_env(:chatchat_web, :admin_stats, ChatchatWeb.Admin.Stats)
    assign(socket, :stats, stats_module.load())
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval)
  defp format_value(nil), do: "Unavailable"
  defp format_value(value), do: Integer.to_string(value)
  defp format_time(datetime), do: Calendar.strftime(datetime, "%H:%M:%S UTC")
end
