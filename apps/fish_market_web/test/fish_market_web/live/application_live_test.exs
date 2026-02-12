defmodule FishMarketWeb.ApplicationLiveTest do
  use FishMarketWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  alias FishMarketWeb.SessionRoute

  test "renders application shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#application-live")
    assert has_element?(view, "#page-sidebar")
    assert has_element?(view, "#page-header")
    assert has_element?(view, "#session-content")
    assert has_element?(view, "textarea#chat-message-input")
  end

  test "renders application shell for session route", %{conn: conn} do
    session_key = "agent:main:cron:43e27541-d0e5-4f9f-815e-807bffe5cd95"
    session_id = SessionRoute.encode(session_key)
    {:ok, view, _html} = live(conn, ~p"/session/#{session_id}")

    assert has_element?(view, "#application-live")
    assert has_element?(view, "#page-sidebar")
    assert has_element?(view, "#session-content")
  end

  test "rejects malformed session route token", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/session/k-YWdlbnQ6bWFpbjp")
  end

  test "shows streaming thinking chunks only when traces are enabled", %{conn: conn} do
    session_key = "agent:main:fm-thinking-test"
    session_id = SessionRoute.encode(session_key)
    conn = put_connect_params(conn, %{"show_traces" => false})
    {:ok, view, _html} = live(conn, ~p"/session/#{session_id}")

    send(view.pid, {:openclaw_event, "agent", thinking_payload(session_key, "run-1", "step 1")})
    visible_before_toggle? = has_element?(view, "#session-streaming-thinking")

    render_click(element(view, "#session-traces-toggle"))

    send(view.pid, {:openclaw_event, "agent", thinking_payload(session_key, "run-1", "step 2")})
    visible_after_toggle? = has_element?(view, "#session-streaming-thinking")
    assert visible_before_toggle? != visible_after_toggle?

    send(
      view.pid,
      {:openclaw_event, "agent", thinking_payload("agent:main:other", "run-1", "skip")}
    )

    assert has_element?(view, "#session-streaming-thinking") == visible_after_toggle?
  end

  test "appends repeated thinking deltas", %{conn: conn} do
    session_key = "agent:main:fm-thinking-repeat"
    session_id = SessionRoute.encode(session_key)
    conn = put_connect_params(conn, %{"show_traces" => true})
    {:ok, view, _html} = live(conn, ~p"/session/#{session_id}")

    send(view.pid, {:openclaw_event, "agent", thinking_payload(session_key, "run-1", "X")})
    assert has_element?(view, "#session-streaming-thinking", "X")

    send(view.pid, {:openclaw_event, "agent", thinking_payload(session_key, "run-1", "X")})
    assert has_element?(view, "#session-streaming-thinking", "XX")
  end

  defp thinking_payload(session_key, run_id, delta_text) do
    %{
      "sessionKey" => session_key,
      "stream" => "thinking",
      "runId" => run_id,
      "data" => %{"delta" => delta_text}
    }
  end
end
