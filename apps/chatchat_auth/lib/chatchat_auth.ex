defmodule ChatchatAuth do
  @moduledoc false

  @type issued_token :: %{access_token: String.t(), expires_at: String.t()}

  @spec issue(pos_integer()) :: issued_token()
  def issue(user_id) do
    issued_at = System.system_time(:second)
    max_age = max_age()

    token =
      Phoenix.Token.sign(
        secret_key_base(),
        token_salt(),
        user_id,
        signed_at: issued_at,
        max_age: max_age
      )

    expires_at =
      issued_at
      |> Kernel.+(max_age)
      |> DateTime.from_unix!()
      |> DateTime.to_iso8601()

    %{access_token: token, expires_at: expires_at}
  end

  @spec verify(String.t() | nil) ::
          {:ok, pos_integer()} | {:error, :expired | :invalid | :missing}
  def verify(token) do
    Phoenix.Token.verify(secret_key_base(), token_salt(), token, max_age: max_age())
  end

  defp secret_key_base do
    Application.fetch_env!(:chatchat_auth, :secret_key_base)
  end

  defp token_salt do
    Application.fetch_env!(:chatchat_auth, :token_salt)
  end

  defp max_age do
    Application.fetch_env!(:chatchat_auth, :max_age)
  end
end
