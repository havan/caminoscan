defmodule Explorer.Chain.Token.Schema do
  @moduledoc false

  alias Explorer.Chain.{Address, Hash}

  if Application.compile_env(:explorer, Explorer.Chain.BridgedToken)[:enabled] do
    @bridged_field [
      quote do
        field(:bridged, :boolean)
      end
    ]
  else
    @bridged_field []
  end

  defmacro generate do
    quote do
      @primary_key false
      typed_schema "tokens" do
        field(:name, :string)
        field(:symbol, :string)
        field(:total_supply, :decimal)
        field(:decimals, :decimal)
        field(:type, :string, null: false)
        field(:cataloged, :boolean)
        field(:holder_count, :integer)
        field(:skip_metadata, :boolean)
        field(:total_supply_updated_at_block, :integer)
        field(:fiat_value, :decimal)
        field(:circulating_market_cap, :decimal)
        field(:icon_url, :string)
        field(:is_verified_via_admin_panel, :boolean)

        belongs_to(
          :contract_address,
          Address,
          foreign_key: :contract_address_hash,
          primary_key: true,
          references: :hash,
          type: Hash.Address,
          null: false
        )

        unquote_splicing(@bridged_field)

        timestamps()
      end
    end
  end
end

defmodule Explorer.Chain.Token do
  @moduledoc """
  Represents a token.

  ## Token Indexing

  The following types of tokens are indexed:

  * ERC-20
  * ERC-721
  * ERC-1155

  ## Token Specifications

  * [ERC-20](https://github.com/ethereum/EIPs/blob/master/EIPS/eip-20.md)
  * [ERC-721](https://github.com/ethereum/EIPs/blob/master/EIPS/eip-721.md)
  * [ERC-777](https://github.com/ethereum/EIPs/blob/master/EIPS/eip-777.md)
  * [ERC-1155](https://github.com/ethereum/EIPs/blob/master/EIPS/eip-1155.md)
  """

  use Explorer.Schema

  require Explorer.Chain.Token.Schema

  import Ecto.{Changeset, Query}

  alias Ecto.Changeset
  alias Explorer.{Chain, SortingHelper}
  alias Explorer.Chain.{BridgedToken, Search, Token}
  alias Explorer.SmartContract.Helper

  @default_sorting [
    desc_nulls_last: :circulating_market_cap,
    desc_nulls_last: :fiat_value,
    desc_nulls_last: :holder_count,
    asc: :name,
    asc: :contract_address_hash
  ]

  @derive {Poison.Encoder,
           except: [
             :__meta__,
             :contract_address,
             :inserted_at,
             :updated_at
           ]}

  @derive {Jason.Encoder,
           except: [
             :__meta__,
             :contract_address,
             :inserted_at,
             :updated_at
           ]}

  @typedoc """
  * `name` - Name of the token
  * `symbol` - Trading symbol of the token
  * `total_supply` - The total supply of the token
  * `decimals` - Number of decimal places the token can be subdivided to
  * `type` - Type of token
  * `cataloged` - Flag for if token information has been cataloged
  * `contract_address` - The `t:Address.t/0` of the token's contract
  * `contract_address_hash` - Address hash foreign key
  * `holder_count` - the number of `t:Explorer.Chain.Address.t/0` (except the burn address) that have a
    `t:Explorer.Chain.CurrentTokenBalance.t/0` `value > 0`.  Can be `nil` when data not migrated.
  * `fiat_value` - The price of a token in a configured currency (USD by default).
  * `circulating_market_cap` - The circulating market cap of a token in a configured currency (USD by default).
  * `icon_url` - URL of the token's icon.
  * `is_verified_via_admin_panel` - is token verified via admin panel.
  """
  Explorer.Chain.Token.Schema.generate()

  @required_attrs ~w(contract_address_hash type)a
  @optional_attrs ~w(cataloged decimals name symbol total_supply skip_metadata total_supply_updated_at_block updated_at fiat_value circulating_market_cap icon_url is_verified_via_admin_panel)a

  @doc false
  def changeset(%Token{} = token, params \\ %{}) do
    additional_attrs = if BridgedToken.enabled?(), do: [:bridged], else: []

    token
    |> cast(params, @required_attrs ++ @optional_attrs ++ additional_attrs)
    |> validate_required(@required_attrs)
    |> trim_name()
    |> sanitize_token_input(:name)
    |> sanitize_token_input(:symbol)
    |> unique_constraint(:contract_address_hash)
  end

  defp trim_name(%Changeset{valid?: false} = changeset), do: changeset

  defp trim_name(%Changeset{valid?: true} = changeset) do
    case get_change(changeset, :name) do
      nil -> changeset
      name -> put_change(changeset, :name, String.trim(name))
    end
  end

  defp sanitize_token_input(%Changeset{valid?: false} = changeset, _), do: changeset

  defp sanitize_token_input(%Changeset{valid?: true} = changeset, key) do
    case get_change(changeset, key) do
      nil ->
        changeset

      property ->
        put_change(changeset, key, Helper.sanitize_input(property))
    end
  end

  @doc """
  Builds an `Ecto.Query` to fetch the cataloged tokens.

  These are tokens with cataloged field set to true and updated_at is earlier or equal than an hour ago.
  """
  def cataloged_tokens(minutes \\ 2880) do
    date_now = DateTime.utc_now()
    some_time_ago_date = DateTime.add(date_now, -:timer.minutes(minutes), :millisecond)

    from(
      token in __MODULE__,
      select: token.contract_address_hash,
      where: token.cataloged == true and token.updated_at <= ^some_time_ago_date
    )
  end

  def tokens_by_contract_address_hashes(contract_address_hashes) do
    from(token in __MODULE__, where: token.contract_address_hash in ^contract_address_hashes)
  end

  def base_token_query(type, sorting) do
    query = from(t in Token, preload: [:contract_address])

    query |> apply_filter(type) |> SortingHelper.apply_sorting(sorting, @default_sorting)
  end

  def default_sorting, do: @default_sorting

  @doc """
  Lists the top `t:__MODULE__.t/0`'s'.
  """
  @spec list_top(String.t() | nil, [
          Chain.paging_options()
          | {:sorting, SortingHelper.sorting_params()}
          | {:token_type, [String.t()]}
        ]) :: [Token.t()]
  def list_top(filter, options \\ []) do
    paging_options = Keyword.get(options, :paging_options, Chain.default_paging_options())
    token_type = Keyword.get(options, :token_type, nil)
    sorting = Keyword.get(options, :sorting, [])

    query = from(t in Token, preload: [:contract_address])

    sorted_paginated_query =
      query
      |> apply_filter(token_type)
      |> SortingHelper.apply_sorting(sorting, @default_sorting)
      |> SortingHelper.page_with_sorting(paging_options, sorting, @default_sorting)

    filtered_query =
      case filter && filter !== "" && Search.prepare_search_term(filter) do
        {:some, filter_term} ->
          sorted_paginated_query
          |> where(fragment("to_tsvector('english', symbol || ' ' || name) @@ to_tsquery(?)", ^filter_term))

        _ ->
          sorted_paginated_query
      end

    filtered_query
    |> Chain.select_repo(options).all()
  end

  defp apply_filter(query, empty_type) when empty_type in [nil, []], do: query

  defp apply_filter(query, token_types) when is_list(token_types) do
    from(t in query, where: t.type in ^token_types)
  end

  def get_by_contract_address_hash(hash, options) do
    Chain.select_repo(options).get_by(__MODULE__, contract_address_hash: hash)
  end
end
