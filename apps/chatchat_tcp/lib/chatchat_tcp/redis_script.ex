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
end
