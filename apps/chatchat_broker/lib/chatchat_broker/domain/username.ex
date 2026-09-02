defmodule ChatchatBroker.Domain.Username do
  @minimum_length 3
  @maximum_length 32
  @valid_format ~r/^[a-zA-Z0-9_]+$/

  @spec validate(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate(username) when is_binary(username) do
    normalized = String.trim(username)

    cond do
      String.length(normalized) not in @minimum_length..@maximum_length ->
        {:error, "username must be from #{@minimum_length} to #{@maximum_length} chars long"}

      not Regex.match?(@valid_format, normalized) ->
        {:error, "invalid char in username"}

      true ->
        {:ok, normalized}
    end
  end

  def validate(_username) do
    {:error, "username must be from #{@minimum_length} to #{@maximum_length} chars long"}
  end

  @spec normalize(term()) :: {:ok, String.t()} | :error
  def normalize(username) when is_binary(username), do: {:ok, String.trim(username)}
  def normalize(_username), do: :error
end
