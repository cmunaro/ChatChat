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
  def command(connection, script, sha, command) do
    case Redix.command(connection, command) do
      {:error, %Redix.Error{message: "NOSCRIPT" <> _}} ->
        with :ok <- load(connection, script, sha) do
          Redix.command(connection, command)
        end

      result ->
        result
    end
  end

  @spec pipeline(Redix.connection(), binary(), binary(), [Redix.command()]) ::
          {:ok, [term()]} | {:error, term()}
  def pipeline(connection, script, sha, commands) do
    case Redix.pipeline(connection, commands) do
      {:ok, results} = result ->
        if Enum.any?(results, &noscript?/1) do
          with :ok <- load(connection, script, sha) do
            Redix.pipeline(connection, commands)
          end
        else
          result
        end

      {:error, %Redix.Error{message: "NOSCRIPT" <> _}} ->
        with :ok <- load(connection, script, sha) do
          Redix.pipeline(connection, commands)
        end

      result ->
        result
    end
  end

  defp noscript?(%Redix.Error{message: "NOSCRIPT" <> _}), do: true
  defp noscript?(_result), do: false
end
