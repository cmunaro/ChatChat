defmodule ChatchatTcp.RedisScript do
  @spec load(Redix.connection(), binary(), binary()) :: :ok | {:error, term()}
  def load(connection, script, expected_sha) do
    case Redix.command(connection, ["SCRIPT", "LOAD", script]) do
      {:ok, ^expected_sha} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec command(Redix.connection(), binary(), binary(), Redix.command()) ::
          {:ok, term()} | {:error, term()}
  def command(
        connection,
        script,
        sha,
        command,
        deadline \\ System.monotonic_time(:millisecond) + 5_000
      ) do
    case command_before(connection, command, deadline) do
      {:error, %Redix.Error{message: "NOSCRIPT" <> _}} ->
        with {:ok, ^sha} <-
               command_before(
                 connection,
                 ["SCRIPT", "LOAD", script],
                 deadline
               ) do
          command_before(connection, command, deadline)
        end

      result ->
        result
    end
  end

  @doc false
  def command_before(connection, command, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0,
      do:
        Redix.command(connection, command,
          timeout: remaining,
          telemetry_metadata: %{connection_name: connection_name(connection)}
        ),
      else: {:error, %Redix.ConnectionError{reason: :timeout}}
  end

  defp connection_name(connection) when is_pid(connection) do
    case Process.info(connection, :registered_name) do
      {:registered_name, name} -> name
      _ -> nil
    end
  end

  defp connection_name(connection), do: connection
end
