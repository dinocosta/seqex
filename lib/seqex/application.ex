defmodule Seqex.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SeqexWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:seqex, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Seqex.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Seqex.Finch},
      # Start a worker by calling: Seqex.Worker.start_link(arg)
      # {Seqex.Worker, arg},
      # Start to serve requests, typically the last entry
      SeqexWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Seqex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SeqexWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
