defmodule Stellar.Horizon.Client.Default do
  @moduledoc """
  Hackney HTTP client implementation.

  This implementation allows you to use your own JSON encoding library. The default is Jason.
  """

  @behaviour Stellar.Horizon.Client.Spec

  alias Stellar.Horizon.{ErrorMapper, Server}

  @type status :: pos_integer()
  @type headers :: [{binary(), binary()}, ...]
  @type body :: binary()
  @type success_response :: {:ok, status(), headers(), body()}
  @type error_response :: {:error, status(), headers(), body()} | {:error, any()}
  @type client_response :: success_response() | error_response()
  @type parsed_response :: {:ok, map()} | {:error, struct()}

  @impl true
  def request(%Server{url: base_url}, method, path, headers \\ [], body \\ "", opts \\ []) do
    options = http_options(opts)

    method
    |> http_client().request(base_url <> path, accept_gzip(headers), body, options)
    |> handle_response()
  end

  @spec handle_response(response :: client_response()) :: parsed_response()
  defp handle_response({:ok, status, headers, body}) when status >= 200 and status <= 299 do
    decoded_body = headers |> gunzip(body) |> json_library().decode!(keys: :atoms)
    {:ok, decoded_body}
  end

  defp handle_response({:ok, status, headers, body}) when status >= 400 and status <= 599 do
    decoded_body = headers |> gunzip(body) |> json_library().decode!(keys: :atoms)
    ErrorMapper.build({:horizon, decoded_body})
  end

  defp handle_response({:error, reason}) do
    ErrorMapper.build({:network, reason})
  end

  @spec accept_gzip(headers :: list()) :: list()
  defp accept_gzip(headers) do
    if has_header?(headers, "accept-encoding"),
      do: headers,
      else: [{"Accept-Encoding", "gzip"} | headers]
  end

  # Hackney does not decompress, so the body is inflated here when Horizon gzipped it.
  @spec gunzip(headers :: list(), body :: binary()) :: binary()
  defp gunzip(headers, body) do
    case body do
      <<0x1F, 0x8B, _rest::binary>> -> if gzipped?(headers), do: :zlib.gunzip(body), else: body
      _ -> body
    end
  end

  @spec gzipped?(headers :: list()) :: boolean()
  defp gzipped?(headers) do
    Enum.any?(headers, fn {name, value} ->
      String.downcase(to_string(name)) == "content-encoding" and
        String.downcase(to_string(value)) == "gzip"
    end)
  end

  @spec has_header?(headers :: list(), name :: binary()) :: boolean()
  defp has_header?(headers, name) do
    Enum.any?(headers, fn {key, _value} -> String.downcase(to_string(key)) == name end)
  end

  @spec http_client() :: atom()
  defp http_client, do: Application.get_env(:stellar_sdk, :http_client, :hackney)

  @spec json_library() :: module()
  defp json_library, do: Application.get_env(:stellar_sdk, :json_library, Jason)

  @spec http_options(options :: Keyword.t()) :: Keyword.t()
  defp http_options(options) do
    default_options = [recv_timeout: 30_000, follow_redirect: true]
    override_options = Application.get_env(:stellar_sdk, :hackney_options, [])

    default_options
    |> Keyword.merge(override_options)
    |> Keyword.merge(options)
    |> (&[:with_body | &1]).()
  end
end
