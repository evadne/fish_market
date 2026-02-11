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
end
