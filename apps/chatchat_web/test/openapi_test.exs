defmodule ChatchatWeb.OpenApiTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  @endpoint ChatchatWeb.Endpoint

  test "GET /openapi serves the authentication API specification" do
    spec =
      build_conn()
      |> get("/openapi")
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
             "required" => ["username", "password"],
             "properties" => %{
               "username" => %{"minLength" => 3, "maxLength" => 32},
               "password" => %{"minLength" => 8, "maxLength" => 128, "writeOnly" => true}
             }
           } = spec["components"]["schemas"]["CredentialsRequest"]
  end

  test "GET /swaggerui serves the interactive API documentation" do
    conn = get(build_conn(), "/swaggerui")

    assert html_response(conn, 200) =~ "/openapi"
  end
end
