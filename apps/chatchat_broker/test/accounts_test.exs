defmodule ChatchatBroker.AccountsTest do
  use ExUnit.Case, async: false

  alias ChatchatBroker.Accounts
  alias ChatchatBroker.Repo
  alias ChatchatBroker.Storage.Schemas.User, as: UserRecord

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "registers a user with a trimmed username and hashed password" do
    assert {:ok, user} = Accounts.register_user("  Alice_1 ", "1234567 abcd ")

    assert user.username == "Alice_1"
    refute Map.has_key?(user, :password)
    refute Map.has_key?(user, :password_hash)

    record = Repo.get!(UserRecord, user.id)
    assert record.password_hash != "1234567 abcd "
    assert Argon2.verify_pass("1234567 abcd ", record.password_hash)
  end

  test "rejects a duplicate trimmed username" do
    assert {:ok, _user} = Accounts.register_user("alice", "1234567 abcd")

    assert {:error, ["username already taken"]} =
             Accounts.register_user(" alice ", "1234567 abc")
  end

  test "rejects an invalid password before it reaches storage" do
    assert {:error, ["password must be from 8 to 128 chars long"]} =
             Accounts.register_user("alice", "short")
  end

  test "authenticates valid credentials and rejects invalid credentials" do
    assert {:ok, user} = Accounts.register_user("alice", "correct horse")
    assert {:ok, authenticated_user} = Accounts.authenticate_user(" alice ", "correct horse")
    assert authenticated_user.id == user.id
    assert {:error, :invalid_credentials} = Accounts.authenticate_user("alice", "wrong password")

    assert {:error, :invalid_credentials} =
             Accounts.authenticate_user("missing", "wrong password")
  end
end
