defmodule ChatchatBroker.Domain.UserSearchResult do
  @enforce_keys [:id, :username]
  defstruct [:id, :username]

  @type t :: %__MODULE__{
          id: pos_integer(),
          username: String.t()
        }
end
