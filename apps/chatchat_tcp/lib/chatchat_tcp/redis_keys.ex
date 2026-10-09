defmodule ChatchatTcp.RedisKeys do
  @moduledoc "Presence hints only; Redis never owns or stores message payloads."
  def presence_route(user_id), do: "chatchat:presence_route:#{user_id}"
  def presence_node(node_id), do: "chatchat:presence_node:#{node_id}"
end
