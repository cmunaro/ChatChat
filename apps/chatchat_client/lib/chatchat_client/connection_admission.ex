defmodule ChatchatClient.ConnectionAdmission do
  @moduledoc false

  def new(limit) when is_integer(limit) and limit > 0 do
    %{
      table: :ets.new(:connection_admission, [:set, :public, write_concurrency: true]),
      limit: limit
    }
  end

  def run(nil, _user_id, operation), do: operation.()

  def run(admission, user_id, operation) do
    start = :erlang.phash2(user_id, admission.limit)

    owner =
      Enum.find_value(0..(admission.limit - 1), fn offset ->
        candidate = {rem(start + offset, admission.limit), self()}
        if reserve(admission.table, candidate), do: candidate
      end)

    if owner do
      try do
        operation.()
      after
        release(admission.table, owner)
      end
    else
      {:error, :capacity}
    end
  end

  def snapshot(admission) do
    active =
      Enum.count(:ets.tab2list(admission.table), fn {_slot, pid} -> Process.alive?(pid) end)

    %{limit: admission.limit, active: active}
  end

  defp reserve(table, {slot, _pid} = owner) do
    if :ets.insert_new(table, owner) do
      true
    else
      case :ets.lookup(table, slot) do
        [{^slot, holder}] ->
          if Process.alive?(holder) do
            false
          else
            release(table, {slot, holder})
            :ets.insert_new(table, owner)
          end

        [] ->
          :ets.insert_new(table, owner)
      end
    end
  rescue
    ArgumentError -> false
  end

  # Delete only the exact owner. A killed holder is reclaimed by its next contender.
  defp release(table, owner) do
    :ets.delete_object(table, owner)
  rescue
    ArgumentError -> :ok
  end
end
