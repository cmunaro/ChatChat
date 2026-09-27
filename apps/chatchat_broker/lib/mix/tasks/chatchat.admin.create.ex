defmodule Mix.Tasks.Chatchat.Admin.Create do
  @moduledoc "Creates an administrator account in the ChatChat database."

  use Mix.Task

  alias ChatchatBroker.Accounts

  @shortdoc "Creates an administrator account"

  @impl Mix.Task
  def run([username]) do
    Mix.Task.run("app.start")

    password = prompt_for_password()

    case Accounts.register_admin(username, password) do
      {:ok, admin} ->
        Mix.shell().info("Created administrator #{admin.username} (id #{admin.id})")

      {:error, errors} ->
        Mix.raise(Enum.join(errors, ", "))
    end
  end

  def run(_arguments) do
    Mix.raise("usage: mix chatchat.admin.create USERNAME")
  end

  defp prompt_for_password do
    password = read_hidden("Password: ")
    confirmation = read_hidden("Confirm password: ")

    if password == confirmation, do: password, else: Mix.raise("passwords do not match")
  end

  defp read_hidden(prompt) do
    IO.write(prompt)
    :ok = :shell.start_interactive({:noshell, :raw})

    try do
      case :io.get_password() do
        password when is_binary(password) -> password
        password when is_list(password) -> List.to_string(password)
        _unavailable -> Mix.raise("could not read password from the terminal")
      end
    after
      :shell.start_interactive({:noshell, :cooked})
      IO.write("\n")
    end
  end
end
