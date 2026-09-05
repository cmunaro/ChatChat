defmodule ChatchatWeb.AuthControllerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest

  alias ChatchatBroker.Repo

  @endpoint ChatchatWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "POST /api/register creates an account" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/register", Jason.encode!(%{username: "Alice", password: "correct horse"}))

    assert response(conn, 204) == ""
  end

  test "POST /api/register rejects a duplicate username" do
    payload = Jason.encode!(%{username: "alice", password: "correct horse"})

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/register", payload)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/register", payload)

    assert %{"errors" => ["username already taken"]} = json_response(conn, 422)
  end

  test "POST /api/register rejects valid JSON without a password" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/register", Jason.encode!(%{username: "alice"}))

    assert %{"errors" => %{"credentials" => ["username and password are required"]}} =
             json_response(conn, 422)
  end

  test "POST /api/login returns a verifiable access token" do
    register_payload = Jason.encode!(%{username: "alice", password: "correct horse"})

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/register", register_payload)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/api/login",
        Jason.encode!(%{username: "alice", password: "correct horse"})
      )

    response = json_response(conn, 200)

    assert %{
             "access_token" => token,
             "expires_at" => expires_at
           } = response

    assert {:ok, user_id} = ChatchatAuth.verify(token)
    assert is_integer(user_id)
    assert {:ok, expiration, 0} = DateTime.from_iso8601(expires_at)
    assert DateTime.diff(expiration, DateTime.utc_now(), :second) < 1_000
  end

  test "access token verification rejects an expired token" do
    token =
      Phoenix.Token.sign(
        ChatchatWeb.Endpoint,
        "user authentication",
        123,
        signed_at: System.system_time(:second) - 901
      )

    assert {:error, :expired} = ChatchatAuth.verify(token)
  end

  test "POST /api/login rejects invalid credentials" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/login", Jason.encode!(%{username: "missing", password: "wrong password"}))

    assert %{"error" => "invalid credentials"} = json_response(conn, 401)
  end

  test "POST /api/login rejects valid JSON without a password" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/login", Jason.encode!(%{username: "alice"}))

    assert %{"error" => "invalid credentials"} = json_response(conn, 401)
  end

  test "POST /api/login returns JSON for a malformed request body" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/login", ~s({"username":"alice",}))

    assert %{"error" => "malformed JSON request body"} = json_response(conn, 400)
  end
end
