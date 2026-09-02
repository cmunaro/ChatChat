defmodule ChatchatBroker.Domain.Password do
  @minimum_length 8
  @maximum_length 128

  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(password) when is_binary(password) do
    if String.length(password) in @minimum_length..@maximum_length,
      do: :ok,
      else: {:error, length_error()}
  end

  def validate(_password), do: {:error, length_error()}

  @spec hash(String.t()) :: String.t()
  def hash(password), do: Argon2.hash_pwd_salt(password)

  @spec valid?(String.t(), String.t()) :: boolean()
  def valid?(password, password_hash), do: Argon2.verify_pass(password, password_hash)

  @spec simulate_verify() :: false
  def simulate_verify, do: Argon2.no_user_verify()

  defp length_error do
    "password must be from #{@minimum_length} to #{@maximum_length} chars long"
  end
end
