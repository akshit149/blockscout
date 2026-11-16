# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Chain.CsvExport.HelperTest do
  use Explorer.DataCase, async: true

  alias Explorer.Chain.CsvExport.Helper
  alias NimbleCSV.RFC4180

  setup do
    original_config = Application.get_env(:explorer, Explorer.Chain.CsvExport)

    Application.put_env(:explorer, Explorer.Chain.CsvExport, [
      {:async?, false}
      | (original_config || []) |> Keyword.drop([:async?])
    ])

    on_exit(fn ->
      if original_config do
        Application.put_env(:explorer, Explorer.Chain.CsvExport, original_config)
      else
        Application.delete_env(:explorer, Explorer.Chain.CsvExport)
      end
    end)

    :ok
  end

  describe "block_from_period/2" do
    test "returns nil bounds when periods are missing or empty" do
      assert Helper.block_from_period(nil, nil) == {nil, nil}
      assert Helper.block_from_period("", "") == {nil, nil}
      assert Helper.block_from_period(nil, "") == {nil, nil}
    end

    test "resolves only the provided bound and leaves the other unbounded" do
      insert(:block, number: 100, timestamp: ~U[2023-01-02 12:00:00Z])

      assert {100, nil} = Helper.block_from_period("2023-01-01", nil)
      assert {nil, 100} = Helper.block_from_period("", "2023-01-03")
    end
  end

  describe "valid_filter?/3" do
    test "returns true for valid address filter to" do
      assert Helper.valid_filter?("address", "to", "transactions") == true
      assert Helper.valid_filter?("address", "to", "token-transfers") == true
      assert Helper.valid_filter?("address", "to", "internal-transactions") == true
    end

    test "returns true for valid address filter from" do
      assert Helper.valid_filter?("address", "from", "transactions") == true
    end

    test "returns false for invalid filter type" do
      assert Helper.valid_filter?("invalid", "to", "transactions") == false
    end

    test "returns false for invalid filter value for address" do
      assert Helper.valid_filter?("address", "invalid", "transactions") == false
    end

    test "returns false for nil or empty filter value" do
      refute Helper.valid_filter?("address", nil, "transactions")
      refute Helper.valid_filter?("address", "", "transactions")
    end
  end

  describe "supported_filters/1" do
    test "returns correct filters for each type" do
      assert Helper.supported_filters("internal-transactions") == ["address"]
      assert Helper.supported_filters("transactions") == ["address"]
      assert Helper.supported_filters("token-transfers") == ["address"]
      assert Helper.supported_filters("logs") == ["topic"]
      assert Helper.supported_filters("unknown") == []
    end
  end

  describe "async_enabled?/0" do
    test "returns config value" do
      Application.put_env(:explorer, Explorer.Chain.CsvExport, [async?: false] ++ [])
      assert Helper.async_enabled?() == false

      Application.put_env(:explorer, Explorer.Chain.CsvExport, [async?: true] ++ [])
      assert Helper.async_enabled?() == true
    end
  end

  describe "dump_to_stream/1" do
    test "produces CSV-formatted stream" do
      rows = [["a", "b", "c"], ["1", "2", "3"]]
      stream = Helper.dump_to_stream(rows)

      result = stream |> Enum.to_list() |> Enum.join("")
      assert result =~ "a,b,c"
      assert result =~ "1,2,3"
    end

    test "neutralizes cells that would be read as a spreadsheet formula" do
      # Exported CSVs can contain attacker-controlled strings, such as a
      # token's on-chain name or symbol, which anyone can set to anything
      # when deploying a contract. Spreadsheet applications (Excel, Google
      # Sheets, LibreOffice) treat a cell starting with =, +, -, or @ as a
      # formula rather than literal text, so such a value must not reach the
      # file unneutralized. A leading apostrophe is the standard mitigation:
      # spreadsheet software renders it as literal text starting with the
      # original character, and plain CSV readers ignore it entirely.
      #
      # Parsing the output back into fields (rather than matching on raw
      # bytes) is deliberate: a neutralized cell like "'=1+1" still contains
      # the substring "=1+1", so a raw substring check can't tell a
      # neutralized cell from an unneutralized one.
      rows = [["=1+1", "+1+1", "-1+1", "@SUM(1+1)", "safe value", "123"]]

      [fields] =
        rows
        |> Helper.dump_to_stream()
        |> Enum.to_list()
        |> IO.iodata_to_binary()
        |> RFC4180.parse_string(skip_headers: false)

      assert fields == ["'=1+1", "'+1+1", "'-1+1", "'@SUM(1+1)", "safe value", "123"]
    end
  end
end
