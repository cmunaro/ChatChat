defmodule ChatchatAuthTest do
  use ExUnit.Case

  test "issues a token containing the user id and expiration" do
    %{access_token: token, expires_at: expires_at} = ChatchatAuth.issue(42)

    assert {:ok, 42} = ChatchatAuth.verify(token)
    assert {:ok, expiration, 0} = DateTime.from_iso8601(expires_at)
    assert DateTime.after?(expiration, DateTime.utc_now())
  end

  test "rejects invalid and missing tokens" do
    assert {:error, :invalid} = ChatchatAuth.verify("invalid")
    assert {:error, :missing} = ChatchatAuth.verify(nil)
  end
end
