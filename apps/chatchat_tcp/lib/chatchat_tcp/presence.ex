defmodule ChatchatTcp.Presence do
  alias ChatchatTcp.Presence.Registry, as: PresenceRegistry

  @spec register(integer()) :: {:error, {:already_registered, pid()}} | {:ok, pid()}
  def register(user_id) when is_integer(user_id) do
    Registry.register(PresenceRegistry, user_id, nil)
  end

  @spec online?(integer()) :: boolean()
  def online?(user_id) when is_integer(user_id) do
    Registry.lookup(PresenceRegistry, user_id) != []
  end

  @spec get_connections(integer()) :: [{pid(), any()}]
  def get_connections(user_id) when is_integer(user_id) do
    Registry.lookup(PresenceRegistry, user_id)
  end

  def get_connections(_), do: []
end
