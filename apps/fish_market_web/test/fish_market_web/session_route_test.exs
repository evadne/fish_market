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

  # Group 2: SessionRoute edge cases

  describe "URL-encoded session keys" do
    test "rejects URL-encoded session keys in validation" do
      # The pattern only allows [A-Za-z0-9._-] characters, not %
      encoded_key = "agent%3Amain%3Atest"
      refute SessionRoute.valid_session_key?(encoded_key)
    end

    test "handles URL decoding in legacy decode" do
      # The legacy decoder tries URI.decode
      session_id = "agent%3Amain%3Atest-session"
      assert {:ok, "agent:main:test-session"} = SessionRoute.decode(session_id)
    end

    test "rejects URL-encoded keys with spaces after decoding" do
      # Spaces are not in the allowed character set
      session_id = "agent%3Amain%3Atest%20with%20spaces"
      assert :error = SessionRoute.decode(session_id)
    end
  end

  describe "boundary patterns" do
    test "rejects empty segments in session key" do
      refute SessionRoute.valid_session_key?("agent::cron:123")
      refute SessionRoute.valid_session_key?(":main:cron:123")
      refute SessionRoute.valid_session_key?("agent:main::123")
    end

    test "rejects trailing colons in session key" do
      refute SessionRoute.valid_session_key?("agent:main:cron:")
      refute SessionRoute.valid_session_key?("agent:main:cron:123:")
    end

    test "rejects leading colons in session key" do
      refute SessionRoute.valid_session_key?(":agent:main:cron:123")
    end

    test "accepts minimum valid session key structure" do
      assert SessionRoute.valid_session_key?("a:b:c")
      assert SessionRoute.valid_session_key?("agent:main:short")
    end

    test "rejects session keys with less than 3 segments" do
      refute SessionRoute.valid_session_key?("agent:main")
      refute SessionRoute.valid_session_key?("agent")
      refute SessionRoute.valid_session_key?("")
    end
  end

  describe "empty/nil inputs" do
    test "decode returns error for empty string" do
      assert :error = SessionRoute.decode("")
    end

    test "decode returns error for nil input" do
      assert :error = SessionRoute.decode(nil)
    end

    test "encode rejects empty session key" do
      # encode/1 has guard: session_key != ""
      assert_raise(FunctionClauseError, fn ->
        SessionRoute.encode("")
      end)
    end

    test "valid_session_key? returns false for empty/nil inputs" do
      refute SessionRoute.valid_session_key?("")
      refute SessionRoute.valid_session_key?(nil)
    end
  end
end
