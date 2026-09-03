defmodule ChatchatWeb.AuthToken do
  @token_salt "user authentication"
  @max_age 15 * 60

  @type issued_token :: %{access_token: String.t(), expires_at: String.t()}

  @spec issue(pos_integer()) :: issued_token()
  def issue(user_id) do
    issued_at = System.system_time(:second)

    token =
      Phoenix.Token.sign(
        ChatchatWeb.Endpoint,
        @token_salt,
        user_id,
        signed_at: issued_at,
        max_age: @max_age
      )

    expires_at =
      issued_at
      |> Kernel.+(@max_age)
      |> DateTime.from_unix!()
      |> DateTime.to_iso8601()

    %{access_token: token, expires_at: expires_at}
  end

  @spec verify(String.t() | nil) ::
          {:ok, pos_integer()} | {:error, :expired | :invalid | :missing}
  def verify(token) do
    Phoenix.Token.verify(ChatchatWeb.Endpoint, @token_salt, token, max_age: @max_age)
  end
end
