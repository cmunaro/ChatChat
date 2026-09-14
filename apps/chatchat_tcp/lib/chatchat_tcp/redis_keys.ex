defmodule ChatchatTcp.RedisKeys do
  @sending_deadlines "chatchat:sending_deadlines"
  @persisting "chatchat:persisting"

  @spec message(Ecto.UUID.t()) :: binary()
  def message(message_id), do: "chatchat:message:#{message_id}"

  @spec pending(pos_integer(), binary()) :: binary()
  def pending(sender_id, request_id) do
    encoded_request_id = Base.url_encode64(request_id, padding: false)
    "chatchat:{admission}:pending:#{sender_id}:#{encoded_request_id}"
  end

  @spec sending(pos_integer()) :: binary()
  def sending(receiver_id), do: "chatchat:sending:#{receiver_id}"

  @spec persisting(Ecto.UUID.t()) :: binary()
  def persisting(message_id), do: "chatchat:persisting:#{message_id}"

  @spec sending_deadlines() :: binary()
  def sending_deadlines, do: @sending_deadlines

  @spec persisting_set() :: binary()
  def persisting_set, do: @persisting
end
