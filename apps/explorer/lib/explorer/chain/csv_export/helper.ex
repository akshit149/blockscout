# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Chain.CsvExport.Helper do
  @moduledoc """
  CSV export helper functions.
  """

  alias Explorer.Chain.Block
  alias Explorer.Chain.Block.Reader.General, as: BlockGeneralReader
  alias Explorer.Chain.Hash.Full, as: Hash
  alias Explorer.PagingOptions
  alias NimbleCSV.RFC4180

  import Ecto.Query,
    only: [
      where: 3
    ]

  @page_size 150
  @default_paging_options %PagingOptions{page_size: @page_size}

  # Leading characters that spreadsheet applications (Excel, Google Sheets,
  # LibreOffice) read as the start of a formula rather than literal text.
  @formula_trigger_prefixes ["=", "+", "-", "@"]

  def dump_to_stream(items) do
    items
    |> Stream.map(&neutralize_formula_cells/1)
    |> RFC4180.dump_to_stream()
  end

  # Exported rows can contain attacker-controlled text - most notably a
  # token's on-chain name or symbol, which anyone can set to anything when
  # deploying a contract, or a transaction's revert reason, which anyone can
  # set when writing a contract. A cell starting with =, +, -, or @ is
  # prefixed with a leading apostrophe, the standard mitigation for CSV
  # (formula) injection: spreadsheet applications render the cell as literal
  # text starting with the original character, and plain CSV readers ignore
  # the apostrophe entirely.
  #
  # Only string cells are considered. Every other value (an integer, a
  # Decimal, a DateTime, nil, ...) is produced by our own code, not by
  # attacker-supplied text, and is left untouched - in particular, a negative
  # Decimal or integer legitimately renders with a leading "-" and must not be
  # turned into a text cell.
  defp neutralize_formula_cells(row) when is_list(row) do
    Enum.map(row, &neutralize_cell/1)
  end

  defp neutralize_cell(cell) when is_binary(cell) do
    if String.starts_with?(cell, @formula_trigger_prefixes) do
      "'" <> cell
    else
      cell
    end
  end

  defp neutralize_cell(cell), do: cell

  def page_size, do: @page_size

  def default_paging_options, do: @default_paging_options

  @spec limit() :: integer()
  def limit, do: Application.get_env(:explorer, :csv_export_limit)

  @spec paging_options() :: Explorer.PagingOptions.t()
  def paging_options, do: %PagingOptions{page_size: limit()}

  @doc """
  Returns a tuple containing the minimum block number from the `from_period` and the maximum block number from the `to_period`.

  ## Parameters

  - `from_period`: The starting period, which can be an ISO8601 timestamp or a date string, from which to calculate the minimum block number.
  - `to_period`: The ending period, which can be an ISO8601 timestamp or a date string, from which to calculate the maximum block number.

  ## Returns

  - A tuple `{from_block, to_block}` where `from_block` is the minimum block number from the `from_period` and `to_block` is the maximum block number from the `to_period`.
    A missing (`nil` or empty) period yields `nil` for the corresponding bound, meaning "no bound".

  ## Examples

    iex> block_from_period("2023-01-01T00:00:00Z", "2023-12-31T23:59:59Z")
    {1000, 2000}

    iex> block_from_period("2023-01-01", "2023-12-31")
    {1000, 2000}

    iex> block_from_period(nil, "")
    {nil, nil}

  """
  @spec block_from_period(String.t() | nil, String.t() | nil) ::
          {Block.block_number() | nil, Block.block_number() | nil}
  def block_from_period(from_period, to_period) do
    from_block = convert_date_string_to_block(from_period, :after, :from)
    to_block = convert_date_string_to_block(to_period, :before, :to)

    {from_block, to_block}
  end

  @spec convert_date_string_to_block(String.t() | nil, :before | :after, :from | :to) :: integer() | nil
  defp convert_date_string_to_block(nil, _direction, _range_type), do: nil
  defp convert_date_string_to_block("", _direction, _range_type), do: nil

  defp convert_date_string_to_block(date_string, direction, range_type) do
    with {:ok, timestamp, _utc_offset} <- date_string_to_timestamp(date_string, range_type),
         {:ok, block} <- BlockGeneralReader.timestamp_to_block_number(timestamp, direction, true) do
      block
    else
      _ -> 0
    end
  end

  @spec date_string_to_timestamp(String.t(), :from | :to) ::
          {:ok, DateTime.t(), Calendar.utc_offset()} | {:error, atom()}
  defp date_string_to_timestamp(date_string, range_type) do
    date_string
    |> Date.from_iso8601()
    |> case do
      {:ok, _date} ->
        range_time =
          case range_type do
            :from -> "T00:00:00Z"
            :to -> "T23:59:59Z"
          end

        date_string <> range_time

      _ ->
        date_string
    end
    |> DateTime.from_iso8601()
  end

  def where_address_hash(query, address_hash, filter_type, filter_value) do
    if filter_type == "address" do
      case filter_value do
        "to" -> where_address_hash_to(query, address_hash)
        "from" -> where_address_hash_from(query, address_hash)
        _ -> where_address_hash_all(query, address_hash)
      end
    else
      where_address_hash_all(query, address_hash)
    end
  end

  defp where_address_hash_to(query, address_hash) do
    query
    |> where(
      [item],
      item.to_address_hash == ^address_hash
    )
  end

  defp where_address_hash_from(query, address_hash) do
    query
    |> where(
      [item],
      item.from_address_hash == ^address_hash
    )
  end

  defp where_address_hash_all(query, address_hash) do
    query
    |> where(
      [item],
      item.to_address_hash == ^address_hash or
        item.from_address_hash == ^address_hash or
        item.token_contract_address_hash == ^address_hash
    )
  end

  @spec supported_filters(String.t()) :: [String.t()]
  def supported_filters(type) do
    case type do
      "internal-transactions" -> ["address"]
      "transactions" -> ["address"]
      "token-transfers" -> ["address"]
      "logs" -> ["topic"]
      _ -> []
    end
  end

  @spec supported_address_filter_values() :: [String.t()]
  def supported_address_filter_values do
    ["to", "from"]
  end

  @spec valid_filter?(String.t(), String.t(), String.t()) :: boolean()
  def valid_filter?(filter_type, filter_value, item_type) do
    valid_filter_type?(filter_type, filter_value, item_type) && valid_filter_value?(filter_type, filter_value)
  end

  defp valid_filter_type?(filter_type, filter_value, item_type) do
    filter_type in supported_filters(item_type) && filter_value && filter_value !== ""
  end

  defp valid_filter_value?(filter_type, filter_value) do
    case filter_type do
      "address" ->
        filter_value in supported_address_filter_values()

      # todo: topic filter is unused, consider removing
      "topic" ->
        case Hash.cast(filter_value) do
          {:ok, _} -> true
          _ -> false
        end

      _ ->
        true
    end
  end

  @spec async_enabled?() :: boolean()
  def async_enabled? do
    Application.get_env(:explorer, Explorer.Chain.CsvExport)[:async?]
  end
end
