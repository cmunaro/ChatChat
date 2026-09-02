defmodule ChatchatBroker.Domain.UsernameTest do
  use ExUnit.Case, async: true

  alias ChatchatBroker.Domain.Username

  test "normalizes and validates a username without storage" do
    assert {:ok, "Alice_1"} = Username.validate("  Alice_1 ")
  end

  test "rejects invalid length and characters" do
    assert {:error, "username must be from 3 to 32 chars long"} = Username.validate("ab")
    assert {:error, "invalid char in username"} = Username.validate("alice!")
  end
end
