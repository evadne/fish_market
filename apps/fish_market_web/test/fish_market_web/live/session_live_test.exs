defmodule FishMarketWeb.SessionLiveTest do
  use FishMarketWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  alias FishMarketWeb.SessionRoute

  # Group 3: SessionLive interaction tests

  describe "send-message event" do
    test "form has correct elements", %{conn: conn} do
      session_key = "agent:main:send-message-form"
      session_id = SessionRoute.encode(session_key)
      {:ok, view, _html} = live(conn, ~p"/session/#{session_id}")

      # Verify the chat form exists with correct ID and elements
      assert has_element?(view, "#chat-message-form")
      assert has_element?(view, "#chat-message-input")
      assert has_element?(view, "#chat-send-button")
    end

    test "form change updates message value", %{conn: conn} do
      session_key = "agent:main:send-message-change"
      session_id = SessionRoute.encode(session_key)
      {:ok, view, _html} = live(conn, ~p"/session/#{session_id}")

      # Change message input
      view
      |> element("#chat-message-form")
      |> render_change(%{chat: %{message: "Hello, world!"}})

      # Should update the textarea value
      assert render(view) =~ "Hello, world!"
    end

    test "form submit triggers send-message event", %{conn: conn} do
      session_key = "agent:main:send-message-submit"
      session_id = SessionRoute.encode(session_key)
      {:ok, view, _html} = live(conn, ~p"/session/#{session_id}")

      # Submit message form - this should trigger the send-message event
      # Even though gateway is disconnected, the form should handle the event
      view
      |> element("#chat-message-form")
      |> render_submit(%{chat: %{message: "Test message"}})

      # Event should be processed without error
      # (specific behavior depends on gateway connection state)
    end

    test "empty message submission", %{conn: conn} do
      session_key = "agent:main:send-message-empty"
      session_id = SessionRoute.encode(session_key)
      {:ok, view, _html} = live(conn, ~p"/session/#{session_id}")

      # Submit empty message
      view
      |> element("#chat-message-form")
      |> render_submit(%{chat: %{message: ""}})

      # Should handle empty message gracefully
    end
  end

  describe "new-session event" do
    test "new-session button exists", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Verify the new session button exists
      assert has_element?(view, "#header-new-session-button")
    end

    test "new-session click event", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Trigger new session creation - should handle without errors
      render_click(view, "new-session")

      # The view should handle this event gracefully
      # (specific behavior depends on gateway connection)
    end
  end

  describe "delete-session event" do
    test "delete button exists in session menu", %{conn: conn} do
      session_key = "agent:main:delete-test"
      session_id = SessionRoute.encode(session_key)
      {:ok, view, _html} = live(conn, ~p"/session/#{session_id}")

      # Delete button should be present in the menu
      rendered = render(view)
      assert rendered =~ "Delete session"
      assert rendered =~ "phx-click=\"delete-session\""
    end

    test "delete-session event handling", %{conn: conn} do
      session_key = "agent:main:delete-event-test"
      session_id = SessionRoute.encode(session_key)
      {:ok, view, _html} = live(conn, ~p"/session/#{session_id}")

      # Simulate delete event - should handle gracefully
      send(view.pid, :delete_session_timeout)

      # Event should be processed without errors
    end
  end

  describe "model/thinking/verbosity change events" do
    test "model selection form exists", %{conn: conn} do
      session_key = "agent:main:model-form-test"
      session_id = SessionRoute.encode(session_key)
      {:ok, view, _html} = live(conn, ~p"/session/#{session_id}")

      # Verify model selection form exists
      assert has_element?(view, "#session-menu-model-form")
      assert has_element?(view, "#session-menu-model-select")
    end

    test "thinking level form change", %{conn: conn} do
      session_key = "agent:main:thinking-change-test"
      session_id = SessionRoute.encode(session_key)
      {:ok, view, _html} = live(conn, ~p"/session/#{session_id}")

      # Trigger thinking level change - should handle without errors
      view
      |> element("#session-menu-thinking-form")
      |> render_change(%{session_thinking: %{thinking_level: "high"}})

      # Event should be processed
    end

    test "verbosity level form change", %{conn: conn} do
      session_key = "agent:main:verbosity-change-test"
      session_id = SessionRoute.encode(session_key)
      {:ok, view, _html} = live(conn, ~p"/session/#{session_id}")

      # Trigger verbosity level change - should handle without errors
      view
      |> element("#session-menu-verbosity-form")
      |> render_change(%{session_verbosity: %{verbose_level: "full"}})

      # Event should be processed
    end
  end

  describe "gateway disconnect/reconnect display" do
    test "handles gateway state events", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Test various gateway states - should handle all without errors
      send(view.pid, {:openclaw_gateway, :disconnected, %{}})
      send(view.pid, {:openclaw_gateway, :connecting, %{}})
      send(view.pid, {:openclaw_gateway, :connected, %{}})

      # All events should be processed without crashes
    end

    test "shows disconnected state in UI", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Should show some indication of gateway state
      rendered = render(view)
      # The gateway is disconnected during tests, so some error should be visible
      assert rendered =~ "not_connected" or rendered =~ "disconnected" or
               rendered =~ "Gateway disconnected"
    end
  end
end
