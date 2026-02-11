defmodule FishMarket.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DNSCluster, query: Application.get_env(:fish_market, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: FishMarket.PubSub},
      FishMarket.OpenClaw.GatewayClient
      # Start a worker by calling: FishMarket.Worker.start_link(arg)
      # {FishMarket.Worker, arg}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: FishMarket.Supervisor)
  end
end
