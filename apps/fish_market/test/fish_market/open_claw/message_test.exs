defmodule FishMarket.OpenClaw.MessageTest do
  use ExUnit.Case, async: true

  alias FishMarket.OpenClaw.Message

  test "preview_text falls back to tool call summary when extracted text is blank" do
    message = %{
      "role" => "assistant",
      "content" => [
        %{"type" => "text", "text" => "\n\n"},
        %{
          "type" => "toolCall",
          "name" => "exec",
          "arguments" => %{"command" => "echo hi"}
        }
      ]
    }

    assert Message.extract_text(message) == ""
    assert Message.preview_text(message) == "tool call: exec"
  end
end
