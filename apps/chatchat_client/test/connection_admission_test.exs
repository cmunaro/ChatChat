defmodule ChatchatClient.ConnectionAdmissionTest do
  use ExUnit.Case, async: true
  alias ChatchatClient.ConnectionAdmission

  test "live owners bound concurrent work and exceptions release ownership" do
    admission = ConnectionAdmission.new(1)
    owner = self()

    holder =
      Task.async(fn ->
        ConnectionAdmission.run(admission, 1, fn ->
          send(owner, :reserved)
          receive do: (:release -> :done)
        end)
      end)

    assert_receive :reserved
    assert ConnectionAdmission.snapshot(admission) == %{limit: 1, active: 1}

    assert {:error, :capacity} =
             ConnectionAdmission.run(admission, 2, fn -> flunk("capacity bypass") end)

    send(holder.pid, :release)
    assert Task.await(holder) == :done

    assert_raise RuntimeError, "failed", fn ->
      ConnectionAdmission.run(admission, 3, fn -> raise "failed" end)
    end

    assert ConnectionAdmission.snapshot(admission).active == 0
    assert :ok = ConnectionAdmission.run(admission, 4, fn -> :ok end)
  end

  test "killed owners are reclaimed and a deleted simulation table fails closed" do
    admission = ConnectionAdmission.new(1)
    parent = self()

    holder =
      spawn(fn ->
        ConnectionAdmission.run(admission, 1, fn ->
          send(parent, :reserved)
          receive do: (:never -> :ok)
        end)
      end)

    monitor = Process.monitor(holder)
    assert_receive :reserved
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}
    assert :recovered = ConnectionAdmission.run(admission, 2, fn -> :recovered end)
    assert :ets.info(admission.table, :size) == 0
    :ets.delete(admission.table)

    assert {:error, :capacity} =
             ConnectionAdmission.run(admission, 3, fn -> flunk("deleted gate bypass") end)
  end

  test "a contender borrows an unused slot instead of waiting behind its hashed owner" do
    admission = ConnectionAdmission.new(2)
    parent = self()

    holder =
      Task.async(fn ->
        ConnectionAdmission.run(admission, 1, fn ->
          send(parent, :reserved)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :reserved

    assert :borrowed =
             ConnectionAdmission.run(admission, 1, fn ->
               assert ConnectionAdmission.snapshot(admission).active == 2
               :borrowed
             end)

    send(holder.pid, :release)
    Task.await(holder)
    assert ConnectionAdmission.snapshot(admission).active == 0
  end
end
