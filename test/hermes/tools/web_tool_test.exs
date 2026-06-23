defmodule Hermes.Tools.WebToolTest do
  use ExUnit.Case, async: true

  alias Hermes.Tools.WebTool

  describe "extract/2 SSRF guard" do
    test "blocks localhost URLs" do
      result = WebTool.extract(%{"url" => "http://localhost:4000/admin"}, %{})

      decoded = result
      assert decoded["success"] == false
      assert decoded["error"] =~ "blocked_host"
    end

    test "blocks loopback IP URLs" do
      result = WebTool.extract(%{"url" => "http://127.0.0.1:8080/"}, %{})
      assert result["success"] == false
      assert result["error"] =~ "blocked_host"
    end

    test "blocks IPv6 loopback" do
      result = WebTool.extract(%{"url" => "http://[::1]:8080/"}, %{})
      assert result["success"] == false
      assert result["error"] =~ "blocked_host"
    end

    test "blocks cloud metadata endpoint" do
      result = WebTool.extract(%{"url" => "http://169.254.169.254/latest/meta-data/"}, %{})
      assert result["success"] == false
      assert result["error"] =~ "blocked_host"
    end

    test "blocks link-local addresses" do
      result = WebTool.extract(%{"url" => "http://169.254.1.1/"}, %{})
      assert result["success"] == false
      assert result["error"] =~ "blocked_host"
    end

    test "blocks private 10.x range" do
      result = WebTool.extract(%{"url" => "http://10.0.0.1/"}, %{})
      assert result["success"] == false
      assert result["error"] =~ "blocked_host"
    end

    test "blocks private 192.168.x range" do
      result = WebTool.extract(%{"url" => "http://192.168.1.1/"}, %{})
      assert result["success"] == false
      assert result["error"] =~ "blocked_host"
    end

    test "blocks private 172.16-31.x range" do
      result = WebTool.extract(%{"url" => "http://172.16.0.1/"}, %{})
      assert result["success"] == false
      assert result["error"] =~ "blocked_host"
    end

    test "blocks non-http schemes" do
      result = WebTool.extract(%{"url" => "file:///etc/passwd"}, %{})
      assert result["success"] == false
      assert result["error"] =~ "blocked_scheme"
    end

    test "blocks ftp scheme" do
      result = WebTool.extract(%{"url" => "ftp://example.com/file"}, %{})
      assert result["success"] == false
      assert result["error"] =~ "blocked_scheme"
    end

    test "blocks URLs with userinfo" do
      result = WebTool.extract(%{"url" => "http://user:pass@example.com/"}, %{})
      assert result["success"] == false
      assert result["error"] =~ "blocked_userinfo"
    end

    test "blocks 0.0.0.0" do
      result = WebTool.extract(%{"url" => "http://0.0.0.0:8080/"}, %{})
      assert result["success"] == false
      assert result["error"] =~ "blocked_host"
    end

    test "returns error for missing url" do
      result = WebTool.extract(%{"url" => ""}, %{})
      assert result["success"] == false
      assert result["error"] =~ "url is required"
    end

    test "allows valid external https URL" do
      # The SSRF guard should NOT block a legitimate external URL.
      # Whether it actually fetches depends on network availability.
      result = WebTool.extract(%{"url" => "https://example.com/"}, %{})

      # If it reached the fetch stage, it either succeeded (network available)
      # or failed with a transport error — but never with an SSRF block.
      if result["success"] == false do
        refute result["error"] =~ "blocked_host"
        refute result["error"] =~ "blocked_scheme"
        refute result["error"] =~ "blocked_userinfo"
      end
    end
  end

  describe "extract/2 edge cases" do
    test "handles non-binary url" do
      result = WebTool.extract(%{"url" => 12345}, %{})
      assert result["success"] == false
    end

    test "handles missing url key" do
      result = WebTool.extract(%{}, %{})
      assert result["success"] == false
      assert result["error"] =~ "url is required"
    end
  end
end
