defmodule ChatchatClient.Api do
  @base_url "http://localhost:4000"
  @password "chatchat-client-password"
  @timeout 10_000

  @spec register(binary()) :: :ok | {:error, term()}
  def register(username) do
    case post("/api/register", %{username: username, password: @password}) do
      {:ok, status, _body} when status in [204, 422] -> :ok
      error -> error
    end
  end

  @spec login(binary()) :: {:ok, binary()} | {:error, term()}
  def login(username) do
    with {:ok, 200, body} <- post("/api/login", %{username: username, password: @password}),
         {:ok, %{"access_token" => token}} <- Jason.decode(body) do
      {:ok, token}
    end
  end

  @spec search(binary(), binary()) :: {:ok, term()} | {:error, term()}
  def search(token, name) do
    query = URI.encode_query(%{name: name})
    headers = [{~c"authorization", String.to_charlist("Bearer " <> token)}]

    with {:ok, {{_version, 200, _phrase}, _headers, body}} <-
           :httpc.request(
             :get,
             {String.to_charlist("#{@base_url}/api/user/search?#{query}"), headers},
             [timeout: @timeout],
             body_format: :binary
           ) do
      Jason.decode(body)
    end
  end

  defp post(path, payload) do
    request = {
      String.to_charlist(@base_url <> path),
      [{~c"accept", ~c"application/json"}],
      ~c"application/json",
      Jason.encode!(payload)
    }

    case :httpc.request(:post, request, [timeout: @timeout], body_format: :binary) do
      {:ok, {{_version, status, _phrase}, _headers, body}} -> {:ok, status, body}
      error -> error
    end
  end
end
