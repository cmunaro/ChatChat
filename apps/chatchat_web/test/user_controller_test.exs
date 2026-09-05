defmodule ChatchatWeb.UserControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias ChatchatBroker.Accounts
  alias ChatchatBroker.Repo

  @endpoint ChatchatWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "GET /api/user/search allows a valid bearer token" do
    assert {:ok, user} = Accounts.register_user("alice", "correct horse")
    assert {:ok, result_user} = Accounts.register_user("Bobby", "correct horse")
    %{access_token: token} = ChatchatAuth.issue(user.id)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/user/search", %{name: "bob"})

    assert json_response(conn, 200) == [
             %{"id" => result_user.id, "username" => "Bobby"}
           ]

    assert conn.assigns.current_user_id == user.id
  end

  test "GET /api/user/search rejects a missing bearer token" do
    conn = get(build_conn(), "/api/user/search", %{name: "bob"})

    assert %{"error" => "unauthorized"} = json_response(conn, 401)
    assert conn.halted
  end

  test "GET /api/user/search rejects an invalid token or non-Bearer scheme" do
    invalid_token_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer invalid")
      |> get("/api/user/search", %{name: "bob"})

    wrong_scheme_conn =
      build_conn()
      |> put_req_header("authorization", "Basic credentials")
      |> get("/api/user/search", %{name: "bob"})

    assert %{"error" => "unauthorized"} = json_response(invalid_token_conn, 401)
    assert %{"error" => "unauthorized"} = json_response(wrong_scheme_conn, 401)
  end

  test "GET /api/user/search requires the exact Bearer scheme" do
    assert {:ok, user} = Accounts.register_user("alice", "correct horse")
    %{access_token: token} = ChatchatAuth.issue(user.id)

    conn =
      build_conn()
      |> put_req_header("authorization", "bearer #{token}")
      |> get("/api/user/search", %{name: "bob"})

    assert %{"error" => "unauthorized"} = json_response(conn, 401)
    assert conn.halted
  end

  test "GET /api/user/search rejects an empty token and duplicate authorization headers" do
    empty_token_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer ")
      |> get("/api/user/search", %{name: "bob"})

    duplicate_headers_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer first")
      |> prepend_req_headers([{"authorization", "Bearer second"}])
      |> get("/api/user/search", %{name: "bob"})

    assert %{"error" => "unauthorized"} = json_response(empty_token_conn, 401)
    assert %{"error" => "unauthorized"} = json_response(duplicate_headers_conn, 401)
  end

  test "GET /api/user/search rejects an expired token" do
    token =
      Phoenix.Token.sign(
        ChatchatWeb.Endpoint,
        "user authentication",
        123,
        signed_at: System.system_time(:second) - 901
      )

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/user/search", %{name: "bob"})

    assert %{"error" => "unauthorized"} = json_response(conn, 401)
  end
end
