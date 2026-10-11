defmodule ChatchatClient.ReconnectBackoff do
  @moduledoc "Bounded reconnect/startup delay; authentication resets the failure count."

  def delay(failures) when is_integer(failures) and failures >= 0 do
    ceiling = min(1_000 * Integer.pow(2, min(failures, 5)), 30_000)
    floor = div(ceiling * 4, 5)
    floor + :rand.uniform(ceiling - floor + 1) - 1
  end
end
