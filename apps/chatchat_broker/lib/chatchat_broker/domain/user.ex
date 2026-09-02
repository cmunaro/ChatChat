defmodule ChatchatBroker.Domain.User do
  @enforce_keys [:id, :username]
  defstruct [:id, :username, :inserted_at]

  @type t :: %__MODULE__{
          id: pos_integer(),
          username: String.t(),
          inserted_at: DateTime.t() | nil
        }
end
