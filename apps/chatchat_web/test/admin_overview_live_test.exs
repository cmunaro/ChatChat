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
