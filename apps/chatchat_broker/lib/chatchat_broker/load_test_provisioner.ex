defmodule ChatchatBroker.LoadTestProvisioner do
  @moduledoc false

  alias ChatchatBroker.Domain.Password
  alias ChatchatBroker.Repo
  alias ChatchatBroker.Storage.Schemas.User

  @first_user_id 1_500_000_001
  @batch_size 5_000
  @password "chatchat-load-test-password"

  @spec run(pos_integer()) :: :ok
  def run(count) when is_integer(count) and count > 0 do
    password_hash = Password.hash(@password)
    timestamp = DateTime.utc_now()

    @first_user_id..(@first_user_id + count - 1)
    |> Stream.chunk_every(@batch_size)
    |> Enum.each(fn ids ->
      entries =
        Enum.map(ids, fn id ->
          %{
            id: id,
            username: "loadtest_#{id}",
            password_hash: password_hash,
            inserted_at: timestamp
          }
        end)

      Repo.insert_all(User, entries,
        conflict_target: [:id],
        on_conflict: {:replace, [:username, :password_hash, :inserted_at]}
      )
    end)

    IO.puts("Provisioned #{count} load-test users beginning at ID #{@first_user_id}")
    :ok
  end

  @spec first_user_id() :: pos_integer()
  def first_user_id, do: @first_user_id
end
