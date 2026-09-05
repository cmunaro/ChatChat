defmodule ChatchatTcp do
  @moduledoc false

  def port do
    {:ok, {_address, port}} = ThousandIsland.listener_info(ChatchatTcp.Server)
    port
  end
end
