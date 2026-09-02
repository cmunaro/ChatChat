defmodule ChatchatBroker.Domain.PasswordTest do
  use ExUnit.Case, async: true

  alias ChatchatBroker.Domain.Password

  test "validates password length without retaining the password" do
    assert :ok = Password.validate("correct horse")

    assert {:error, "password must be from 8 to 128 chars long"} =
             Password.validate("short")
  end

  test "hashes and verifies passwords" do
    hash = Password.hash("correct horse")

    refute hash == "correct horse"
    assert Password.valid?("correct horse", hash)
    refute Password.valid?("wrong password", hash)
  end
end
