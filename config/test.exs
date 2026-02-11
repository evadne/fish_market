import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :fish_market_web, FishMarketWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "utr++snNaSnlFz5vc4V2+10TSg8Y9ncXPk4Vy3YXnRqLM9MAb12/mjumK/0lBIM0",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :fish_market, FishMarket.OpenClaw,
  gateway_url: System.get_env("OPENCLAW_GATEWAY_URL", "ws://127.0.0.1:18789"),
  gateway_token: System.get_env("OPENCLAW_GATEWAY_TOKEN", "test-token"),
  gateway_password: System.get_env("OPENCLAW_GATEWAY_PASSWORD")
