defmodule ChatchatTcp.MessageDelivery do
  @moduledoc "Bounded receipt-or-commit attempts and session-scoped receipt reservations."
  use GenServer

  alias ChatchatBroker.Storage.MessagesStore
  alias ChatchatTcp.{Capacity, Delivery, Diagnostics, Presence, Protocol}

  @sender_gate ChatchatTcp.SenderCapacity
  @receiver_gate ChatchatTcp.ReceiverCapacity
  @direct_ms 2_000
  @result_ms 8_000
  @stored_ms 10_000
  @workers 32

  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def submit(sender, session, request) do
    with :ok <- Protocol.validate_send(sender, request),
         {:ok, ticket} <- Capacity.claim(@sender_gate),
         :ok <-
           GenServer.call(
             __MODULE__,
             {:admit, ticket, sender, session, request["request_id"], request["message_id"],
              request["user_id"]},
             :infinity
           ) do
      send(__MODULE__, {:payload, elem(ticket, 2), request["message"]})
      {:accepted, elem(ticket, 2)}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def acknowledge(receiver, session, request) do
    if Protocol.uuid?(request["message_id"]) and Protocol.uuid?(request["receipt_id"]) and
         Protocol.user?(request["from_user_id"]) do
      GenServer.call(__MODULE__, {:ack, self(), receiver, session, request}, :infinity)
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  def deliver_stored(message, session) do
    with {:ok, ticket} <- Capacity.claim(@receiver_gate),
         {:ok, _handler, receipt} <-
           GenServer.call(
             __MODULE__,
             {:stored_permit, ticket, message.receiver_id, session, message.sender_id,
              message.message_id},
             :infinity
           ),
         :ok <- send_stored_frame(message, receipt) do
      :ok
    else
      _ -> {:error, :capacity}
    end
  end

  defp send_stored_frame(message, receipt) do
    frame =
      Protocol.delivery(
        message.sender_id,
        message.message_id,
        message.payload,
        message.inserted_at,
        receipt
      )

    case Protocol.encode(frame) do
      {:ok, encoded} ->
        send(__MODULE__, {:stored_frame, self(), receipt, encoded})
        :ok

      {:error, reason} ->
        release_receipt(receipt)
        {:error, reason}
    end
  end

  def frame_consumed(receipt) do
    GenServer.call(__MODULE__, {:frame_consumed, self(), receipt}, :infinity)
  catch
    :exit, _ -> :ok
  end

  def authorize_frame(receiver, session, receipt) do
    GenServer.call(__MODULE__, {:authorize_frame, self(), receiver, session, receipt}, :infinity)
  catch
    :exit, _ -> false
  end

  def release_receipt(receipt), do: GenServer.cast(__MODULE__, {:release_receipt, receipt})
  def metric_snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @impl true
  def init(nil) do
    # Reserve 20 KiB per attempt, including fallback copies and fixed metadata.
    Capacity.new(@sender_gate, div(8 * 1_024 * 1_024, 20_480))
    Capacity.new(@receiver_gate, div(8 * 1_024 * 1_024, 12_288))
    {:ok, %{attempts: %{}, receipts: %{}, jobs: %{}, queue: :queue.new()}}
  end

  @impl true
  def handle_call({:admit, ticket, sender, session, request, id, receiver}, {pid, _}, state) do
    connected = connection(sender, session) == {:ok, pid}
    count = Enum.count(state.attempts, fn {_, attempt} -> attempt.sender == pid end)

    if connected and count < 16 and elem(ticket, 1) == pid and
         Capacity.activate(@sender_gate, ticket) == :ok do
      reference = elem(ticket, 2)
      now = now()
      monitor = Process.monitor(pid)

      attempt = %{
        ticket: ticket,
        sender: pid,
        sender_id: sender,
        session: session,
        request: request,
        id: id,
        receiver: receiver,
        message: nil,
        inserted_at: DateTime.utc_now(),
        deadline: now + @result_ms,
        direct_deadline: now + @direct_ms,
        phase: :payload,
        queued_at: nil,
        direct_started_at: nil,
        completed: false,
        monitor: monitor,
        permits: [],
        transmissions: 0,
        job: nil,
        result_timer: Process.send_after(self(), {:deadline, reference}, @result_ms),
        direct_timer: nil,
        resend_timer: nil,
        pending_frames: MapSet.new(),
        remote_monitors: %{}
      }

      {:reply, :ok, %{state | attempts: Map.put(state.attempts, reference, attempt)}}
    else
      Capacity.release(@sender_gate, ticket)
      {:reply, {:error, :capacity}, state}
    end
  end

  def handle_call({:stored_permit, ticket, receiver, session, sender, id}, {pid, _}, state) do
    if elem(ticket, 1) == pid do
      case reserve_receipt(ticket, receiver, session, sender, id, nil, @stored_ms, state) do
        {:ok, handler, receipt, state} -> {:reply, {:ok, handler, receipt}, state}
        {:error, state} -> {:reply, {:error, :capacity}, state}
      end
    else
      {:reply, {:error, :capacity}, state}
    end
  end

  def handle_call({:ack, handler, receiver, session, request}, _from, state) do
    receipt = request["receipt_id"]
    expected_sender = request["from_user_id"]
    expected_id = request["message_id"]

    case state.receipts[receipt] do
      %{
        handler: ^handler,
        receiver: ^receiver,
        session: ^session,
        sender: sender,
        id: id,
        expires: expires
      } = tracking
      when sender == expected_sender and id == expected_id ->
        if now() < expires and connection(receiver, session) == {:ok, handler} do
          if tracking.origin do
            {origin, reference} = tracking.origin
            remote_send(origin, {:receipt, reference, receipt, self()})
            {:reply, :ok, drop_receipt(state, receipt)}
          else
            :telemetry.execute([:chatchat, :inbox, :receipt], %{count: 1}, %{})
            state = drop_receipt(state, receipt)
            {:reply, :ok, start_delete(receiver, sender, id, state)}
          end
        else
          {:reply, :ok, state}
        end

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:frame_consumed, handler, receipt}, _from, state) do
    case state.receipts[receipt] do
      %{handler: ^handler} = tracking ->
        state = %{state | receipts: Map.put(state.receipts, receipt, %{tracking | queued: false})}
        state = if now() >= tracking.expires, do: remove_receipt(state, receipt), else: state
        {:reply, :ok, state}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:authorize_frame, handler, receiver, session, receipt}, _from, state) do
    allowed =
      case state.receipts[receipt] do
        %{handler: ^handler, receiver: ^receiver, session: ^session, expires: expires} ->
          now() < expires

        _ ->
          false
      end

    {:reply, allowed, state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       attempts: map_size(state.attempts),
       receipts: map_size(state.receipts),
       workers: map_size(state.jobs),
       waiting: :queue.len(state.queue)
     }, state}
  end

  @impl true
  def handle_cast({:release_receipt, receipt}, state),
    do: {:noreply, drop_receipt(state, receipt)}

  @impl true
  def handle_info({:payload, reference, payload}, state) do
    case state.attempts[reference] do
      %{phase: :payload} = attempt ->
        attempt = %{attempt | message: payload, phase: :routing}

        {:noreply,
         enqueue(reference, %{state | attempts: Map.put(state.attempts, reference, attempt)})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:permit_request, origin, reference, receiver, session, sender, id}, state) do
    # Only connected cluster nodes can ask for a permit. No payload arrives yet.
    if node(origin) in [node() | Node.list()] do
      case Capacity.claim(@receiver_gate) do
        {:ok, ticket} ->
          case reserve_receipt(
                 ticket,
                 receiver,
                 session,
                 sender,
                 id,
                 {origin, reference},
                 @direct_ms,
                 state
               ) do
            {:ok, handler, receipt, state} ->
              remote_send(origin, {:permit, reference, self(), handler, session, receipt})
              {:noreply, state}

            {:error, state} ->
              remote_send(origin, {:permit_refused, reference})
              {:noreply, state}
          end

        _ ->
          remote_send(origin, {:permit_refused, reference})
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:permit, reference, coordinator, _handler, session, receipt}, state) do
    case state.attempts[reference] do
      %{phase: :direct, route: route, completed: false} = attempt ->
        if now() < attempt.direct_deadline and node(coordinator) == route.node and
             session == route.session do
          frame =
            Protocol.delivery(
              attempt.sender_id,
              attempt.id,
              attempt.message,
              attempt.inserted_at,
              receipt
            )

          case Protocol.encode(frame) do
            {:ok, encoded} ->
              transferred =
                remote_send(
                  coordinator,
                  {:direct_frame, self(), reference, session, receipt, encoded}
                )

              remote_monitor = Process.monitor(coordinator)

              pending =
                if transferred == :ok,
                  do: MapSet.put(attempt.pending_frames, receipt),
                  else: attempt.pending_frames

              attempt = %{
                attempt
                | pending_frames: pending,
                  remote_monitors: Map.put(attempt.remote_monitors, remote_monitor, coordinator)
              }

              attempt = %{
                attempt
                | permits: [{coordinator, receipt} | attempt.permits],
                  transmissions: attempt.transmissions + 1
              }

              attempt =
                if attempt.transmissions == 1,
                  do: %{
                    attempt
                    | resend_timer: Process.send_after(self(), {:resend, reference}, 500)
                  },
                  else: attempt

              {:noreply, %{state | attempts: Map.put(state.attempts, reference, attempt)}}

            _ ->
              {:noreply, finish(state, reference, :rejected, :invalid_request)}
          end
        else
          remote_send(coordinator, {:"$gen_cast", {:release_receipt, receipt}})
          {:noreply, state}
        end

      _ ->
        remote_send(coordinator, {:"$gen_cast", {:release_receipt, receipt}})
        {:noreply, state}
    end
  end

  def handle_info({:direct_frame, origin, reference, session, receipt, encoded}, state) do
    # Acknowledge buffer transfer even when the permit already expired. This
    # releases origin byte accounting, never confirms durable receipt.
    remote_send(origin, {:frame_seen, reference, receipt, self()})

    case state.receipts[receipt] do
      %{origin: {^origin, ^reference}, session: ^session} ->
        {:noreply, queue_frame(state, receipt, encoded)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:stored_frame, producer, receipt, encoded}, state) do
    case state.receipts[receipt] do
      %{ticket: {_slot, ^producer, _reference}, origin: nil} ->
        {:noreply, queue_frame(state, receipt, encoded)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:frame_seen, reference, receipt, coordinator}, state) do
    case state.attempts[reference] do
      %{permits: permits} = attempt ->
        if {coordinator, receipt} in permits do
          attempt = %{attempt | pending_frames: MapSet.delete(attempt.pending_frames, receipt)}

          {:noreply,
           maybe_release(
             %{state | attempts: Map.put(state.attempts, reference, attempt)},
             reference
           )}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:permit_refused, reference}, state), do: {:noreply, fallback(state, reference)}

  def handle_info({:resend, reference}, state) do
    case state.attempts[reference] do
      %{phase: :direct, completed: false, transmissions: transmissions} = attempt
      when transmissions < 2 ->
        if now() < attempt.direct_deadline, do: request_permit(reference, attempt)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:direct_timeout, reference}, state), do: {:noreply, fallback(state, reference)}

  def handle_info({:receipt, reference, receipt, coordinator}, state) do
    case state.attempts[reference] do
      %{completed: false} = attempt ->
        if now() < attempt.direct_deadline and {coordinator, receipt} in attempt.permits do
          attempt = %{attempt | pending_frames: MapSet.delete(attempt.pending_frames, receipt)}
          state = %{state | attempts: Map.put(state.attempts, reference, attempt)}
          {:noreply, finish(state, reference, :ok, :receipt)}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:committed, reference, {:ok, _stored}}, state),
    do: {:noreply, finish(state, reference, :ok, :fallback)}

  def handle_info({:deadline, reference}, state) do
    reason =
      case state.attempts[reference] do
        %{job: nil} -> :capacity
        _ -> :unavailable
      end

    {:noreply, finish(state, reference, :failed, reason)}
  end

  def handle_info({:receipt_expired, receipt}, state),
    do: {:noreply, drop_receipt(state, receipt)}

  def handle_info({reference, result}, state) when is_reference(reference) do
    Process.demonitor(reference, [:flush])
    {job, jobs} = Map.pop(state.jobs, reference)
    {:noreply, job_result(job, result, %{state | jobs: jobs}) |> drain()}
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, state) do
    case Map.pop(state.jobs, reference) do
      {nil, _} ->
        state =
          Enum.reduce(state.receipts, state, fn {receipt, tracking}, state ->
            if tracking.monitor == reference, do: drop_receipt(state, receipt, true), else: state
          end)

        state =
          Enum.reduce(state.attempts, state, fn {id, attempt}, state ->
            case Map.pop(attempt.remote_monitors, reference) do
              {nil, _} ->
                state

              {coordinator, monitors} ->
                receipts = for {^coordinator, receipt} <- attempt.permits, do: receipt
                pending = Enum.reduce(receipts, attempt.pending_frames, &MapSet.delete(&2, &1))
                attempt = %{attempt | pending_frames: pending, remote_monitors: monitors}
                state = %{state | attempts: Map.put(state.attempts, id, attempt)}
                if attempt.completed, do: maybe_release(state, id), else: fallback(state, id)
            end
          end)

        attempts =
          Enum.filter(state.attempts, fn {_, attempt} -> attempt.monitor == reference end)

        state =
          Enum.reduce(attempts, state, fn {id, attempt}, state ->
            state = %{state | attempts: Map.put(state.attempts, id, %{attempt | sender: nil})}
            finish(state, id, :failed, :unavailable)
          end)

        {:noreply, drain(state)}

      {job, jobs} ->
        {:noreply, job_result(job, {:error, :unavailable}, %{state | jobs: jobs}) |> drain()}
    end
  end

  defp reserve_receipt(ticket, receiver, session, sender, id, origin, lifetime, state) do
    count = Enum.count(state.receipts, fn {_, receipt} -> receipt.receiver == receiver end)

    with {:ok, handler} <- connection(receiver, session),
         true <- count < 16,
         :ok <- Capacity.activate(@receiver_gate, ticket) do
      receipt = Ecto.UUID.generate()

      tracking = %{
        ticket: ticket,
        handler: handler,
        receiver: receiver,
        session: session,
        sender: sender,
        id: id,
        origin: origin,
        expires: now() + lifetime,
        monitor: Process.monitor(handler),
        timer: Process.send_after(self(), {:receipt_expired, receipt}, lifetime),
        queued: false,
        dispatched: false
      }

      {:ok, handler, receipt, %{state | receipts: Map.put(state.receipts, receipt, tracking)}}
    else
      _ ->
        Capacity.release(@receiver_gate, ticket)
        {:error, state}
    end
  end

  defp queue_frame(state, receipt, encoded) do
    tracking = state.receipts[receipt]

    if (tracking && not tracking.dispatched) and now() < tracking.expires and
         is_binary(encoded) and byte_size(encoded) <= 4_097 do
      send(tracking.handler, {:delivery_frame, tracking.session, receipt, encoded})

      %{
        state
        | receipts: Map.put(state.receipts, receipt, %{tracking | queued: true, dispatched: true})
      }
    else
      state
    end
  end

  defp drop_receipt(state, receipt, force \\ false) do
    case state.receipts[receipt] do
      %{queued: true} = tracking when not force ->
        Process.cancel_timer(tracking.timer)
        # A queued frame still consumes its permit until the handler discards or
        # sends it. Expiry cannot create room for an unbounded stale mailbox.
        %{state | receipts: Map.put(state.receipts, receipt, %{tracking | expires: 0})}

      _ ->
        remove_receipt(state, receipt)
    end
  end

  defp remove_receipt(state, receipt) do
    case Map.pop(state.receipts, receipt) do
      {nil, _} ->
        state

      {tracking, receipts} ->
        Process.demonitor(tracking.monitor, [:flush])
        Process.cancel_timer(tracking.timer)
        Capacity.release(@receiver_gate, tracking.ticket)
        %{state | receipts: receipts}
    end
  end

  defp connection(user, session) do
    case Presence.get_connections(user) do
      [{pid, %{"session" => ^session}}] -> {:ok, pid}
      _ -> {:error, :unavailable}
    end
  end

  defp enqueue(reference, state) do
    attempt = %{state.attempts[reference] | queued_at: Diagnostics.now()}

    drain(%{
      state
      | attempts: Map.put(state.attempts, reference, attempt),
        queue: :queue.in(reference, state.queue)
    })
  end

  defp drain(state) do
    if map_size(state.jobs) < @workers do
      case :queue.out(state.queue) do
        {:empty, _} ->
          state

        {{:value, reference}, queue} ->
          state = %{state | queue: queue}

          case state.attempts[reference] do
            %{completed: false, job: nil} = attempt ->
              if now() < attempt.deadline do
                start_job(reference, attempt, state) |> drain()
              else
                finish(state, reference, :failed, :capacity) |> drain()
              end

            _ ->
              drain(state)
          end
      end
    else
      state
    end
  end

  defp start_job(reference, attempt, state) do
    parent = self()
    remaining = min(5_000, max(attempt.deadline - now(), 1))
    phase = attempt.phase
    Diagnostics.elapsed(attempt.queued_at, :queue, phase, :dispatched)
    submitted_at = Diagnostics.now()

    task =
      Task.Supervisor.async_nolink(ChatchatTcp.Delivery.TaskSupervisor, fn ->
        Diagnostics.elapsed(submitted_at, :schedule, phase, :started)

        case phase do
          :routing ->
            Diagnostics.measure(:route, :routing, fn -> Presence.route(attempt.receiver) end)

          :fallback ->
            result =
              Diagnostics.measure(:persist, :fallback, fn ->
                MessagesStore.insert_pending(
                  %{
                    sender_id: attempt.sender_id,
                    message_id: attempt.id,
                    receiver_id: attempt.receiver,
                    payload: attempt.message
                  },
                  remaining
                )
              end)

            if match?({:ok, _}, result) do
              send(parent, {:committed, reference, result})

              Diagnostics.measure(:wake, :fallback, fn ->
                wake_current_receiver(attempt.receiver)
              end)
            end

            result
        end
      end)

    attempt = %{attempt | job: task.ref, queued_at: nil}

    %{
      state
      | jobs: Map.put(state.jobs, task.ref, {reference, phase}),
        attempts: Map.put(state.attempts, reference, attempt)
    }
  end

  defp job_result(nil, _result, state), do: state
  defp job_result(:delete, _result, state), do: state

  defp job_result({reference, phase}, result, state) do
    case state.attempts[reference] do
      nil ->
        state

      attempt ->
        state = %{state | attempts: Map.put(state.attempts, reference, %{attempt | job: nil})}

        cond do
          attempt.completed ->
            maybe_release(state, reference)

          phase == :routing and match?({:ok, _}, result) and now() < attempt.direct_deadline ->
            {:ok, route} = result

            attempt =
              Map.put(
                %{attempt | phase: :direct, job: nil, direct_started_at: Diagnostics.now()},
                :route,
                route
              )

            request_permit(reference, attempt)

            timer =
              Process.send_after(
                self(),
                {:direct_timeout, reference},
                max(attempt.direct_deadline - now(), 0)
              )

            attempt = %{attempt | direct_timer: timer}

            %{state | attempts: Map.put(state.attempts, reference, attempt)}

          result == {:error, :identity_conflict} ->
            finish(state, reference, :rejected, :identity_conflict)

          result == {:error, :invalid_receiver} ->
            finish(state, reference, :rejected, :invalid_receiver)

          phase == :routing ->
            fallback(state, reference)

          match?({:ok, _}, result) ->
            finish(state, reference, :ok, :fallback)

          true ->
            finish(state, reference, :failed, :unavailable)
        end
    end
  end

  defp request_permit(reference, attempt) do
    result =
      remote_send(
        {__MODULE__, attempt.route.node},
        {:permit_request, self(), reference, attempt.receiver, attempt.route.session,
         attempt.sender_id, attempt.id}
      )

    unless result == :ok, do: send(self(), {:permit_refused, reference})
  end

  defp fallback(state, reference) do
    case state.attempts[reference] do
      %{completed: false, phase: phase, job: nil} = attempt when phase in [:direct, :routing] ->
        Diagnostics.elapsed(attempt.direct_started_at, :direct_wait, :direct, :fallback)
        attempt = %{attempt | phase: :fallback, direct_started_at: nil}
        enqueue(reference, %{state | attempts: Map.put(state.attempts, reference, attempt)})

      _ ->
        state
    end
  end

  defp finish(state, reference, status, reason) do
    case state.attempts[reference] do
      %{completed: false} = attempt ->
        {status, reason} =
          if status == :ok and now() >= attempt.deadline,
            do: {:failed, :unavailable},
            else: {status, reason}

        Diagnostics.elapsed(attempt.queued_at, :queue, attempt.phase, :abandoned)
        Diagnostics.elapsed(attempt.direct_started_at, :direct_wait, :direct, status)

        if attempt.sender do
          wire_reason = if status == :ok, do: nil, else: reason

          send(
            attempt.sender,
            {:message_result, reference,
             Protocol.result(attempt.request, attempt.id, status, wire_reason)}
          )
        end

        Enum.each([attempt.result_timer, attempt.direct_timer, attempt.resend_timer], fn timer ->
          if timer, do: Process.cancel_timer(timer)
        end)

        :telemetry.execute([:chatchat, :message, :result], %{count: 1}, %{
          status: status,
          reason: reason,
          message_id: attempt.id,
          sender_id: attempt.sender_id,
          recipient_id: attempt.receiver
        })

        Enum.each(attempt.permits, fn {coordinator, receipt} ->
          remote_send(coordinator, {:"$gen_cast", {:release_receipt, receipt}})
        end)

        attempt = %{attempt | completed: true, queued_at: nil, direct_started_at: nil}

        state = %{
          state
          | attempts: Map.put(state.attempts, reference, attempt),
            queue: :queue.filter(&(&1 != reference), state.queue)
        }

        maybe_release(state, reference)

      _ ->
        state
    end
  end

  defp maybe_release(state, reference) do
    attempt = state.attempts[reference]

    if attempt.completed and is_nil(attempt.job) and MapSet.size(attempt.pending_frames) == 0,
      do: remove_attempt(state, reference),
      else: state
  end

  defp remove_attempt(state, reference) do
    {attempt, attempts} = Map.pop(state.attempts, reference)
    Process.demonitor(attempt.monitor, [:flush])
    Enum.each(Map.keys(attempt.remote_monitors), &Process.demonitor(&1, [:flush]))
    Capacity.release(@sender_gate, attempt.ticket)
    %{state | attempts: attempts}
  end

  defp start_delete(receiver, sender, id, state) do
    if map_size(state.jobs) < @workers do
      task =
        Task.Supervisor.async_nolink(ChatchatTcp.Delivery.TaskSupervisor, fn ->
          MessagesStore.delete_for_receiver(receiver, sender, id)
        end)

      %{state | jobs: Map.put(state.jobs, task.ref, :delete)}
    else
      state
    end
  end

  defp wake_current_receiver(receiver) do
    case Presence.route(receiver) do
      {:ok, route} -> remote_send({Delivery, route.node}, {:wake, receiver})
      _ -> :ok
    end
  end

  defp remote_send(destination, message) do
    :erlang.send(destination, message, [:nosuspend, :noconnect])
  rescue
    ArgumentError -> :unavailable
  end

  defp now, do: System.monotonic_time(:millisecond)
end
