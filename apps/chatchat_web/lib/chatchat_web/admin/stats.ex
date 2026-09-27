defmodule ChatchatWeb.Admin.Stats do
  @moduledoc false

  alias ChatchatBroker.Storage.AccountsStore
  alias ChatchatBroker.Storage.MessagesStore

  @spec load() :: map()
  def load do
    job = Application.get_env(:chatchat_web, :prometheus_tcp_job, "chatchat_tcp_local")

    queries = %{
      online_users: ~s|sum(chatchat_tcp_connected_clients{job="#{job}"})|,
      redis_messages: ~s|max(chatchat_redis_pending_messages{job="#{job}"})|
    }

    prometheus =
      queries
      |> Task.async_stream(fn {name, query} -> {name, query_prometheus(query)} end,
        ordered: false,
        timeout: 2_500
      )
      |> Enum.reduce(%{}, fn
        {:ok, {name, result}}, results -> Map.put(results, name, result)
        _, results -> results
      end)

    database_messages = MessagesStore.count_undelivered()
    redis_messages = Map.get(prometheus, :redis_messages)

    %{
      registered_users: AccountsStore.count_users(),
      online_users: Map.get(prometheus, :online_users),
      messages_in_delivery: add_if_available(redis_messages, database_messages),
      messages_in_database: database_messages,
      updated_at: DateTime.utc_now()
    }
  end

  @doc false
  @spec parse_response(Finch.Response.t()) :: non_neg_integer() | nil
  def parse_response(%Finch.Response{status: 200, body: body}) do
    with {:ok, %{"status" => "success", "data" => %{"result" => results}}} <- Jason.decode(body),
         [%{"value" => [_timestamp, value]} | _] <- results,
         {number, ""} <- Float.parse(value) do
      round(number)
    else
      _ -> nil
    end
  end

  def parse_response(_response), do: nil

  defp query_prometheus(query) do
    query_string = URI.encode_query(%{query: query})

    url =
      Application.fetch_env!(:chatchat_web, :prometheus_url) <>
        "/api/v1/query?" <> query_string

    :get
    |> Finch.build(url)
    |> Finch.request(ChatchatWeb.Finch, receive_timeout: 2_000)
    |> case do
      {:ok, response} -> parse_response(response)
      {:error, _reason} -> nil
    end
  end

  defp add_if_available(nil, _database_messages), do: nil
  defp add_if_available(redis_messages, database_messages), do: redis_messages + database_messages
end
