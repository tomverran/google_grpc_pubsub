defmodule Pubsub.Client do
  use GenServer

  @type t :: %__MODULE__{
          channel: GRPC.Channel.t(),
          emulator?: boolean()
        }

  defstruct [:channel, :emulator?]

  def start_link(init_opts) do
    GenServer.start_link(__MODULE__, init_opts)
  end

  @spec channel() :: GRPC.Channel.t()
  def channel() do
    :poolboy.transaction(:grpc_client_pool, fn pid ->
      GenServer.call(pid, :channel)
    end)
  end

  @spec call(module(), atom(), any(), Keyword.t()) :: any()
  def call(mod, fun, req, opts \\ []) do
    :poolboy.transaction(:grpc_client_pool, fn pid ->
      GenServer.call(pid, {:call, {mod, fun, req, opts}})
    end)
  end

  @impl true
  def init(_init_opts) do
    opts = Application.get_env(:google_grpc_pubsub, __MODULE__, [])

    emulator? = Keyword.get(opts, :emulator, false)

    if emulator? do
      host = Keyword.fetch!(opts, :host)
      port = Keyword.fetch!(opts, :port)

      GRPC.Stub.connect(host, port,
        adapter_opts: %{
          http2_opts: %{keepalive: :infinity}
        }
      )
    else
      ssl_opts = opts |> Keyword.get(:ssl_opts, []) |> Keyword.merge(cacerts: :certifi.cacerts())

      credentials = GRPC.Credential.new(ssl: ssl_opts)

      GRPC.Stub.connect("pubsub.googleapis.com", 443,
        cred: credentials,
        adapter_opts: %{
          http2_opts: %{keepalive: :infinity}
        }
      )
    end
    |> case do
      {:ok, channel} ->
        {:ok, %__MODULE__{channel: channel, emulator?: emulator?}}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def handle_call(:channel, _info, %__MODULE__{channel: channel} = client) do
    {:reply, channel, client}
  end

  @impl true
  def handle_call(
        {:call, {mod, fun, req, opts}},
        _info,
        %__MODULE__{channel: channel, emulator?: emulator?} = client
      ) do
    opts = if emulator?, do: opts, else: request_opts(opts)

    {:reply, apply(mod, fun, [channel, req, opts]), client}
  end

  @impl true
  def handle_info(_info, client) do
    {:noreply, client}
  end

  @spec request_opts(Keyword.t()) :: Keyword.t()
  defp request_opts(opts) do
    case Goth.Token.for_scope("https://www.googleapis.com/auth/pubsub") do
      {:ok, %{token: token, type: token_type}} ->
        Keyword.put(opts, :metadata, %{"authorization" => "#{token_type} #{token}"})

      _ ->
        opts
    end
  end
end
