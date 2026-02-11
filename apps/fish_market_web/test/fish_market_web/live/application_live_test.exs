defmodule FishMarketWeb.ApplicationLiveTest do
  use FishMarketWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders application shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#application-live")
    assert has_element?(view, "#page-sidebar")
    assert has_element?(view, "#page-header")
    assert has_element?(view, "#session-content")
  end

  test "renders application shell for session route", %{conn: conn} do
    session_key = "agent:main:cron:43e27541-d0e5-4f9f-815e-807bffe5cd95"
    {:ok, view, _html} = live(conn, ~p"/session/#{session_key}")

    assert has_element?(view, "#application-live")
    assert has_element?(view, "#page-sidebar")
    assert has_element?(view, "#session-content")
  end
end
