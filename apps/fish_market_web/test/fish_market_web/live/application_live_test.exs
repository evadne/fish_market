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
end
