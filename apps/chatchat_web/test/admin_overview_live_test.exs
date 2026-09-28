defmodule ChatchatWeb.Admin.OverviewLiveTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ChatchatBroker.{Accounts, Repo}

  @endpoint ChatchatWeb.Endpoint

  defmodule StubStats do
    def load do
      %{
        registered_users: 125,
        online_users: 42,
        messages_in_delivery: 18,
        messages_in_database: 7,
        updated_at: ~U[2026-09-27 20:00:00Z]
      }
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    previous = Application.get_env(:chatchat_web, :admin_stats)
    Application.put_env(:chatchat_web, :admin_stats, StubStats)

    on_exit(fn ->
      if previous do
        Application.put_env(:chatchat_web, :admin_stats, previous)
      else
        Application.delete_env(:chatchat_web, :admin_stats)
      end
    end)
  end

  test "GET /admin renders the current system overview" do
    body = authenticated_conn() |> get("/admin") |> html_response(200)

    assert body =~ "System overview"
    assert body =~ "Registered users"
    assert body =~ "125"
    assert body =~ "Online users"
    assert body =~ "42"
    assert body =~ "Messages in delivery"
    assert body =~ "18"
    assert body =~ "Messages in delivery DB"
    assert body =~ "7"
    assert body =~ ~s(id="live-messages")
    assert body =~ "Live messages"
    assert body =~ ~s(aria-expanded="false")
    assert body =~ "User search"
  end

  test "keeps the live-message collapse state in the LiveView socket" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, messages_open: false}}

    assert {:noreply, opened} =
             ChatchatWeb.Admin.OverviewLive.handle_event("toggle_messages", %{}, socket)

    assert opened.assigns.messages_open
    assert {:noreply, refreshed} = ChatchatWeb.Admin.OverviewLive.handle_info(:refresh, opened)
    assert refreshed.assigns.messages_open
  end

  test "groups both message directions in the same client pair" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, message_edges: %{}}}

    assert {:noreply, first} =
             ChatchatWeb.Admin.OverviewLive.handle_info(
               {:message_admitted, %{message_id: "first", sender_id: 10, recipient_id: 11}},
               socket
             )

    assert {:noreply, second} =
             ChatchatWeb.Admin.OverviewLive.handle_info(
               {:message_admitted, %{message_id: "second", sender_id: 11, recipient_id: 10}},
               first
             )

    assert %{
             {10, 11} => %{
               directions: %{
                 {10, 11} => %{count: 1},
                 {11, 10} => %{count: 1}
               }
             }
           } = second.assigns.message_edges
  end

  test "merges directional panels already held by a running LiveView" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        message_edges: %{
          {12, 13} => %{count: 2, last_seen: 1, message_id: "forward"},
          {13, 12} => %{count: 1, last_seen: 2, message_id: "reverse"}
        }
      }
    }

    assert {:noreply, refreshed} = ChatchatWeb.Admin.OverviewLive.handle_info(:refresh, socket)

    assert %{
             {12, 13} => %{
               directions: %{
                 {12, 13} => %{count: 2},
                 {13, 12} => %{count: 1}
               }
             }
           } = refreshed.assigns.message_edges
  end

  test "broadcasts valid Redis message events to admin sessions" do
    Phoenix.PubSub.subscribe(ChatchatWeb.PubSub, "admin:messages")

    payload =
      Jason.encode!(%{message_id: Ecto.UUID.generate(), sender_id: 12, recipient_id: 13})

    redis_message =
      {:redix_pubsub, :pubsub, :subscription, :message,
       %{channel: "chatchat:admin:messages", payload: payload}}

    state = %{pubsub: :pubsub, subscription: :subscription}

    assert {:noreply, ^state} =
             ChatchatWeb.Admin.MessageStream.handle_info(redis_message, state)

    assert_receive {:message_admitted, %{sender_id: 12, recipient_id: 13}}
  end

  test "GET /admin redirects an anonymous visitor to the login page" do
    conn = get(build_conn(), "/admin")

    assert redirected_to(conn) == "/admin/login"
  end

  test "a regular user id in the session cannot access the admin" do
    assert {:ok, user} = Accounts.register_user("regular_user", "correct horse")

    conn =
      build_conn()
      |> init_test_session(%{admin_user_id: user.id})
      |> get("/admin")

    assert redirected_to(conn) == "/admin/login"
    refute get_session(conn, :admin_user_id)
  end

  test "an administrator can sign in and sign out" do
    assert {:ok, _admin} = Accounts.register_admin("admin", "correct horse")

    conn =
      build_conn()
      |> init_test_session(%{})
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
      |> post("/admin/login", %{username: "admin", password: "correct horse"})

    assert redirected_to(conn) == "/admin"
    assert is_integer(get_session(conn, :admin_user_id))

    admin_conn = conn |> recycle() |> get("/admin")
    assert html_response(admin_conn, 200) =~ "System overview"

    logout_conn =
      admin_conn
      |> recycle()
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
      |> post("/admin/logout")

    assert redirected_to(logout_conn) == "/admin/login"
    refute get_session(logout_conn, :admin_user_id)
  end

  test "invalid credentials do not create an admin session" do
    assert {:ok, _admin} = Accounts.register_admin("admin", "correct horse")

    conn =
      build_conn()
      |> init_test_session(%{})
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
      |> post("/admin/login", %{username: "admin", password: "wrong"})

    assert html_response(conn, 401) =~ "Invalid username or password"
    refute get_session(conn, :admin_user_id)
  end

  defp authenticated_conn do
    {:ok, admin} = Accounts.register_admin("overview_admin", "correct horse")
    build_conn() |> init_test_session(%{admin_user_id: admin.id})
  end
end

defmodule ChatchatWeb.Admin.StatsTest do
  use ExUnit.Case, async: true

  alias ChatchatWeb.Admin.Stats

  test "parses a successful Prometheus instant-vector response" do
    body =
      Jason.encode!(%{
        status: "success",
        data: %{result: [%{value: [1_800_000_000, "42"]}]}
      })

    assert Stats.parse_response(%Finch.Response{status: 200, body: body}) == 42
  end

  test "returns nil for unavailable or empty Prometheus results" do
    empty = Jason.encode!(%{status: "success", data: %{result: []}})

    assert Stats.parse_response(%Finch.Response{status: 200, body: empty}) == nil
    assert Stats.parse_response(%Finch.Response{status: 503, body: "unavailable"}) == nil
  end
end
