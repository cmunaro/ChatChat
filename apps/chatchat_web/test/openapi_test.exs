defmodule ChatchatWeb.OpenApiTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias ChatchatBroker.{Accounts, Repo}

  @endpoint ChatchatWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "OpenAPI and Swagger require an administrator session" do
    for path <- ["/admin/openapi", "/admin/swaggerui"] do
      conn = get(build_conn(), path)
      assert redirected_to(conn) == "/admin/login"
    end

    assert response(get(build_conn(), "/openapi"), 404)
    assert response(get(build_conn(), "/swaggerui"), 404)
  end

  test "GET /admin/openapi serves the HTTP specification" do
    spec =
      authenticated_conn()
      |> get("/admin/openapi")
      |> json_response(200)

    assert spec["openapi"] =~ "3.0"
    assert spec["info"]["title"] == "ChatChat API"

    assert %{"post" => %{"operationId" => "registerAccount"}} =
             spec["paths"]["/api/register"]

    assert %{"post" => %{"operationId" => "login"}} = spec["paths"]["/api/login"]

    assert %{
             "get" => %{
               "operationId" => "searchUser",
               "security" => [%{"bearerAuth" => []}]
             }
           } = spec["paths"]["/api/user/search"]

    assert %{"type" => "http", "scheme" => "bearer"} =
             spec["components"]["securitySchemes"]["bearerAuth"]

    assert %{
             "type" => "array",
             "maxItems" => 20,
             "items" => %{"$ref" => "#/components/schemas/UserSearchResult"}
           } = spec["components"]["schemas"]["UserSearchResults"]

    assert %{
             "required" => ["username", "password"],
             "properties" => %{
               "username" => %{"minLength" => 3, "maxLength" => 32},
               "password" => %{"minLength" => 8, "maxLength" => 128, "writeOnly" => true}
             }
           } = spec["components"]["schemas"]["CredentialsRequest"]

    refute Map.has_key?(spec["components"]["schemas"], "TcpSendMessage")
  end

  test "GET /admin/swaggerui serves the protected interactive documentation" do
    conn = authenticated_conn() |> get("/admin/swaggerui")

    assert html_response(conn, 200) =~ "/admin/openapi"
  end

  defp authenticated_conn do
    {:ok, admin} = Accounts.register_admin("docs_admin", "correct horse")
    build_conn() |> init_test_session(%{admin_user_id: admin.id})
  end
end
