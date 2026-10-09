defmodule ChatchatTcp.Capacity do
  @moduledoc "Fixed slots acquired before submission; owners reserve worst-case bytes per slot."

  def new(name, slots) do
    table = :ets.new(name, [:set, :named_table, :public, write_concurrency: true])
    :ets.insert(table, {:slots, slots})
    table
  end

  def claim(table) do
    [{:slots, slots}] = :ets.lookup(table, :slots)
    reference = make_ref()
    owner = self()

    case Enum.find(1..slots, fn slot ->
           case :ets.lookup(table, slot) do
             [{^slot, pid, _ref, :pending} = abandoned] ->
               unless Process.alive?(pid), do: :ets.delete_object(table, abandoned)

             _ ->
               :ok
           end

           :ets.insert_new(table, {slot, owner, reference, :pending})
         end) do
      nil -> {:error, :capacity}
      slot -> {:ok, {slot, owner, reference}}
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  def activate(table, {slot, owner, reference}) do
    case :ets.lookup(table, slot) do
      [{^slot, ^owner, ^reference, :pending}] ->
        :ets.insert(table, {slot, owner, reference, :active})
        :ok

      _ ->
        {:error, :capacity}
    end
  end

  def release(table, {slot, owner, reference}) do
    :ets.match_delete(table, {slot, owner, reference, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end
end
