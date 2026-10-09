defmodule ChatchatTcp.PresenceRoutingTest do
  use ExUnit.Case, async: true

  alias ChatchatTcp.Presence

  test "routing accepts only known node atoms without interning Redis input" do
    assert {:ok, node()} == Presence.trusted_node(Atom.to_string(node()))

    assert {:ok, :trusted@localhost} ==
             Presence.trusted_node("trusted@localhost", [:trusted@localhost])

    assert {:error, :unavailable} = Presence.trusted_node("trusted@localhost", [])
    assert {:error, :unavailable} = Presence.trusted_node(nil)

    unknown = "untrusted_#{Ecto.UUID.generate()}@attacker"
    assert {:error, :unavailable} = Presence.trusted_node(unknown)
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end
end
