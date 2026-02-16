defmodule FishMarket.OpenClawTest do
  use ExUnit.Case, async: true

  alias FishMarket.OpenClaw

  # Group 4: OpenClaw context tests

  describe "topic string generation" do
    test "session_topic/1 generates correct topic string" do
      session_key = "agent:main:test-session"
      expected = "openclaw:session:agent:main:test-session"

      assert OpenClaw.session_topic(session_key) == expected
    end

    test "session_topic/1 handles special characters" do
      session_key = "agent:main:test_with-dashes_and.dots"
      expected = "openclaw:session:agent:main:test_with-dashes_and.dots"

      assert OpenClaw.session_topic(session_key) == expected
    end

    test "gateway_topic/0 returns correct topic" do
      assert OpenClaw.gateway_topic() == "openclaw:gateway"
    end

    test "chat_topic/0 returns correct topic" do
      assert OpenClaw.chat_topic() == "openclaw:chat"
    end
  end

  describe "idempotency key format" do
    test "idempotency_key/0 generates unique keys" do
      key1 = OpenClaw.idempotency_key()
      key2 = OpenClaw.idempotency_key()

      # Keys should be different
      refute key1 == key2

      # Keys should follow the format: fm-<integer>-<base64>
      assert key1 =~ ~r/^fm-\d+-[A-Za-z0-9_-]+$/
      assert key2 =~ ~r/^fm-\d+-[A-Za-z0-9_-]+$/
    end

    test "idempotency key has correct prefix" do
      key = OpenClaw.idempotency_key()
      assert String.starts_with?(key, "fm-")
    end

    test "idempotency key parts are valid" do
      key = OpenClaw.idempotency_key()
      ["fm", integer_part, base64_part] = String.split(key, "-", parts: 3)

      # Integer part should be parseable
      assert String.to_integer(integer_part) > 0

      # Base64 part should be valid (no padding, URL-safe)
      assert base64_part =~ ~r/^[A-Za-z0-9_-]+$/
      assert String.length(base64_part) > 0
    end
  end

  describe "PubSub subscribe/broadcast wiring" do
    test "subscribe_gateway/0 returns :ok" do
      assert OpenClaw.subscribe_gateway() == :ok
    end

    test "subscribe_chat/0 returns :ok" do
      assert OpenClaw.subscribe_chat() == :ok
    end

    test "subscribe_event/1 returns :ok for valid event" do
      assert OpenClaw.subscribe_event("test-event") == :ok
      assert OpenClaw.subscribe_event("agent") == :ok
    end

    test "subscribe_session/1 returns :ok" do
      session_key = "agent:main:test-subscribe"
      assert OpenClaw.subscribe_session(session_key) == :ok
    end

    test "unsubscribe_event/1 returns :ok" do
      event = "test-unsubscribe-event"
      OpenClaw.subscribe_event(event)
      assert OpenClaw.unsubscribe_event(event) == :ok
    end

    test "unsubscribe_session/1 returns :ok" do
      session_key = "agent:main:test-unsubscribe"
      OpenClaw.subscribe_session(session_key)
      assert OpenClaw.unsubscribe_session(session_key) == :ok
    end

    test "broadcast_gateway/2 returns :ok" do
      assert OpenClaw.broadcast_gateway(:connected, %{}) == :ok
      assert OpenClaw.broadcast_gateway(:disconnected, %{reason: "test"}) == :ok
    end

    test "broadcast_event/2 returns :ok" do
      payload = %{"sessionKey" => "agent:main:test", "data" => "test"}
      assert OpenClaw.broadcast_event("agent", payload) == :ok
      assert OpenClaw.broadcast_event("chat", payload) == :ok
    end

    test "broadcast_local_user_message/2 returns :ok" do
      session_key = "agent:main:test-message"
      payload = %{"role" => "user", "content" => "test message"}
      assert OpenClaw.broadcast_local_user_message(session_key, payload) == :ok
    end

    test "subscribe then broadcast message flow" do
      # Subscribe to a session
      session_key = "agent:main:pubsub-test"
      :ok = OpenClaw.subscribe_session(session_key)

      # Broadcast a message
      payload = %{"sessionKey" => session_key, "data" => "test event"}
      :ok = OpenClaw.broadcast_event("agent", payload)

      # Should receive the message
      assert_receive {:openclaw_event, "agent", ^payload}, 1000

      # Clean up
      OpenClaw.unsubscribe_session(session_key)
    end

    test "gateway subscription receives broadcast" do
      # Subscribe to gateway events
      :ok = OpenClaw.subscribe_gateway()

      # Broadcast a gateway event
      :ok = OpenClaw.broadcast_gateway(:test_event, %{status: "ok"})

      # Should receive the message
      assert_receive {:openclaw_gateway, :test_event, %{status: "ok"}}, 1000
    end
  end

  describe "request/3 when gateway not connected" do
    test "returns {:error, :not_connected} when gateway not connected" do
      # Gateway process is running but not connected during tests
      result = OpenClaw.request("test.method", %{}, 1000)
      assert result == {:error, :not_connected}
    end

    test "returns error for various methods when gateway not connected" do
      assert {:error, :not_connected} = OpenClaw.sessions_list()
      assert {:error, :not_connected} = OpenClaw.sessions_delete("test-key")
      assert {:error, :not_connected} = OpenClaw.models_list()
      assert {:error, :not_connected} = OpenClaw.chat_history("test-key")
      assert {:error, :not_connected} = OpenClaw.chat_send("test-key", "test message")
    end
  end
end
