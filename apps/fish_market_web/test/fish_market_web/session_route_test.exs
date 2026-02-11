defmodule FishMarketWeb.SessionRouteTest do
  use ExUnit.Case, async: true

  alias FishMarketWeb.SessionRoute

  test "encodes and decodes a session route token" do
    session_key = "agent:main:main-164"
    token = SessionRoute.encode(session_key)

    assert {:ok, ^session_key} = SessionRoute.decode(token)
  end

  test "rejects malformed session key in legacy token" do
    assert :error = SessionRoute.decode("k-YWdlbnQ6bWFpbjp")
  end

  test "validates required session key structure" do
    assert SessionRoute.valid_session_key?("agent:main:cron:43e27541-d0e5-4f9f-815e-807bffe5cd95")
    refute SessionRoute.valid_session_key?("agent:main:")
    refute SessionRoute.valid_session_key?("agent:main")
  end
end
