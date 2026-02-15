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

  # Group 1: Message edge cases

  describe "timestamp normalization" do
    test "converts seconds to milliseconds" do
      message = %{"timestamp" => 1_703_275_200}
      assert Message.timestamp_ms(message) == 1_703_275_200_000
    end

    test "preserves millisecond timestamps" do
      message = %{"timestamp" => 1_703_275_200_000}
      assert Message.timestamp_ms(message) == 1_703_275_200_000
    end

    test "handles ISO 8601 timestamps" do
      message = %{"timestamp" => "2023-12-22T16:00:00Z"}
      assert Message.timestamp_ms(message) == 1_703_260_800_000
    end

    test "returns nil for nil timestamp" do
      message = %{"timestamp" => nil}
      assert Message.timestamp_ms(message) == nil
    end

    test "returns nil for zero timestamp" do
      message = %{"timestamp" => 0}
      assert Message.timestamp_ms(message) == nil
    end

    test "uses ts field as fallback" do
      message = %{"ts" => 1_703_275_200}
      assert Message.timestamp_ms(message) == 1_703_275_200_000
    end

    test "handles invalid ISO 8601 format" do
      message = %{"timestamp" => "not-a-date"}
      assert Message.timestamp_ms(message) == nil
    end
  end

  describe "multi-part content extraction" do
    test "extracts mixed text + thinking + tool_call content" do
      message = %{
        "role" => "assistant",
        "content" => [
          %{"type" => "text", "text" => "Let me help you with that."},
          %{"type" => "text", "text" => "<thinking>I need to analyze this.</thinking>"},
          %{
            "type" => "toolCall",
            "name" => "exec",
            "arguments" => %{"command" => "ls -la"}
          },
          %{"type" => "text", "text" => "Here's the result."}
        ]
      }

      extracted = Message.extract_text(message)
      assert extracted == "Let me help you with that.\n\nHere's the result."
    end

    test "strips thinking tags from assistant messages" do
      message = %{
        "role" => "assistant",
        "content" => [
          %{"type" => "text", "text" => "Start<thinking>internal thoughts</thinking>End"}
        ]
      }

      assert Message.extract_text(message) == "StartEnd"
    end

    test "handles nested thinking tags (regex behavior)" do
      message = %{
        "role" => "assistant",
        "content" => [
          %{"type" => "text", "text" => "A<thinking>B<thinking>nested</thinking>C</thinking>D"}
        ]
      }

      # Regex will match the first complete thinking tag pair
      assert Message.extract_text(message) == "AC</thinking>D"
    end

    test "handles malformed thinking tags" do
      message = %{
        "role" => "assistant",
        "content" => [
          %{"type" => "text", "text" => "A<thinking>unclosed tag"}
        ]
      }

      # Should not strip unclosed thinking tags
      assert Message.extract_text(message) == "A<thinking>unclosed tag"
    end

    test "strips think tags as well" do
      message = %{
        "role" => "assistant",
        "content" => [
          %{"type" => "text", "text" => "Before<think>short form</think>After"}
        ]
      }

      assert Message.extract_text(message) == "BeforeAfter"
    end
  end

  describe "tool call name extraction" do
    test "extracts tool call names from content array when text is blank" do
      message = %{
        "role" => "assistant",
        "content" => [
          %{"type" => "text", "text" => "  \n  "},
          %{"type" => "toolCall", "name" => "exec"},
          %{"type" => "toolCall", "name" => "read_file"}
        ]
      }

      assert Message.preview_text(message) == "tool call: exec, read_file"
    end

    test "handles tool calls with mixed case types" do
      message = %{
        "role" => "assistant",
        "content" => [
          %{"type" => "ToolCall", "name" => "uppercase_type"},
          %{"type" => "tool_call", "name" => "underscore_type"}
        ]
      }

      assert Message.preview_text(message) == "tool call: uppercase_type, underscore_type"
    end

    test "falls back to (unnamed) for tool calls without names" do
      message = %{
        "role" => "assistant",
        "content" => [
          %{"type" => "toolCall", "arguments" => %{"command" => "test"}}
        ]
      }

      assert Message.preview_text(message) == "tool call: (unnamed)"
    end

    test "deduplicates repeated tool call names" do
      message = %{
        "role" => "assistant",
        "content" => [
          %{"type" => "toolCall", "name" => "exec"},
          %{"type" => "toolCall", "name" => "exec"},
          %{"type" => "toolCall", "name" => "read_file"}
        ]
      }

      assert Message.preview_text(message) == "tool call: exec, read_file"
    end
  end

  describe "role extraction defaults" do
    test "defaults to assistant for missing role" do
      message = %{"content" => "Hello"}
      assert Message.role(message) == "assistant"
    end

    test "defaults to assistant for nil role" do
      message = %{"role" => nil, "content" => "Hello"}
      assert Message.role(message) == "assistant"
    end

    test "defaults to assistant for non-string role" do
      message = %{"role" => 123, "content" => "Hello"}
      assert Message.role(message) == "assistant"
    end

    test "preserves valid role values" do
      message = %{"role" => "user", "content" => "Hello"}
      assert Message.role(message) == "user"
    end

    test "defaults to assistant for non-map input" do
      assert Message.role("not a map") == "assistant"
      assert Message.role(nil) == "assistant"
    end
  end
end
