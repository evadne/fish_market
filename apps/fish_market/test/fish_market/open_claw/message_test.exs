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

  test "preview_text returns raw assistant error message when present" do
    error_json =
      "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"},\"request_id\":\"req_123\"}"

    message = %{
      "role" => "assistant",
      "stopReason" => "error",
      "errorMessage" => error_json,
      "content" => []
    }

    assert Message.assistant_error?(message)
    assert Message.assistant_error_message(message) == error_json
    assert Message.preview_text(message) == error_json
  end
end
