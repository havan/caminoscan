defmodule Explorer.Chain.Transaction.Schema do
  @moduledoc false

  alias Explorer.Chain.{
    Address,
    Block,
    Data,
    Hash,
    InternalTransaction,
    Log,
    TokenTransfer,
    TransactionAction,
    Wei
  }

  alias Explorer.Chain.Transaction.{Fork, Status}
  alias Explorer.Chain.Zkevm.BatchTransaction

  @chain_type_fields (case Application.compile_env(:explorer, :chain_type) do
                        "suave" ->
                          elem(
                            quote do
                              belongs_to(
                                :execution_node,
                                Address,
                                foreign_key: :execution_node_hash,
                                references: :hash,
                                type: Hash.Address
                              )

                              field(:wrapped_type, :integer)
                              field(:wrapped_nonce, :integer)
                              field(:wrapped_gas, :decimal)
                              field(:wrapped_gas_price, Wei)
                              field(:wrapped_max_priority_fee_per_gas, Wei)
                              field(:wrapped_max_fee_per_gas, Wei)
                              field(:wrapped_value, Wei)
                              field(:wrapped_input, Data)
                              field(:wrapped_v, :decimal)
                              field(:wrapped_r, :decimal)
                              field(:wrapped_s, :decimal)
                              field(:wrapped_hash, Hash.Full)

                              belongs_to(
                                :wrapped_to_address,
                                Address,
                                foreign_key: :wrapped_to_address_hash,
                                references: :hash,
                                type: Hash.Address
                              )
                            end,
                            2
                          )

                        "polygon_zkevm" ->
                          elem(
                            quote do
                              has_one(:zkevm_batch_transaction, BatchTransaction, foreign_key: :hash, references: :hash)
                              has_one(:zkevm_batch, through: [:zkevm_batch_transaction, :batch], references: :hash)

                              has_one(:zkevm_sequence_transaction,
                                through: [:zkevm_batch, :sequence_transaction],
                                references: :hash
                              )

                              has_one(:zkevm_verify_transaction,
                                through: [:zkevm_batch, :verify_transaction],
                                references: :hash
                              )
                            end,
                            2
                          )

                        _ ->
                          []
                      end)

  defmacro generate do
    quote do
      @primary_key false
      typed_schema "transactions" do
        field(:hash, Hash.Full, primary_key: true)
        field(:block_number, :integer)
        field(:block_consensus, :boolean)
        field(:block_timestamp, :utc_datetime_usec)
        field(:cumulative_gas_used, :decimal)
        field(:earliest_processing_start, :utc_datetime_usec)
        field(:error, :string)
        field(:gas, :decimal)
        field(:gas_price, Wei)
        field(:gas_used, :decimal)
        field(:index, :integer)
        field(:created_contract_code_indexed_at, :utc_datetime_usec)
        field(:input, Data)
        field(:nonce, :integer) :: non_neg_integer() | nil
        field(:r, :decimal)
        field(:s, :decimal)
        field(:status, Status)
        field(:v, :decimal)
        field(:value, Wei)
        field(:revert_reason, :string)
        field(:max_priority_fee_per_gas, Wei)
        field(:max_fee_per_gas, Wei)
        field(:type, :integer)
        field(:has_error_in_internal_txs, :boolean)
        field(:has_token_transfers, :boolean, virtual: true)

        # stability virtual fields
        field(:transaction_fee_log, :any, virtual: true)
        field(:transaction_fee_token, :any, virtual: true)

        # A transient field for deriving old block hash during transaction upserts.
        # Used to force refetch of a block in case a transaction is re-collated
        # in a different block. See: https://github.com/blockscout/blockscout/issues/1911
        field(:old_block_hash, Hash.Full)

        timestamps()

        belongs_to(:block, Block, foreign_key: :block_hash, references: :hash, type: Hash.Full)
        has_many(:forks, Fork, foreign_key: :hash, references: :hash)

        belongs_to(
          :from_address,
          Address,
          foreign_key: :from_address_hash,
          references: :hash,
          type: Hash.Address
        )

        has_many(:internal_transactions, InternalTransaction, foreign_key: :transaction_hash, references: :hash)
        has_many(:logs, Log, foreign_key: :transaction_hash, references: :hash)

        has_many(:token_transfers, TokenTransfer, foreign_key: :transaction_hash, references: :hash)

        has_many(:transaction_actions, TransactionAction,
          foreign_key: :hash,
          preload_order: [asc: :log_index],
          references: :hash
        )

        belongs_to(
          :to_address,
          Address,
          foreign_key: :to_address_hash,
          references: :hash,
          type: Hash.Address
        )

        has_many(:uncles, through: [:forks, :uncle], references: :hash)

        belongs_to(
          :created_contract_address,
          Address,
          foreign_key: :created_contract_address_hash,
          references: :hash,
          type: Hash.Address
        )

        unquote_splicing(@chain_type_fields)
      end
    end
  end
end

defmodule Explorer.Chain.Transaction do
  @moduledoc "Models a Web3 transaction."

  use Explorer.Schema

  require Logger
  require Explorer.Chain.Transaction.Schema

  alias ABI.FunctionSelector
  alias Ecto.Association.NotLoaded
  alias Ecto.Changeset
  alias Explorer.{Chain, Helper, PagingOptions, Repo, SortingHelper}

  alias Explorer.Chain.{
    Block.Reward,
    ContractMethod,
    Data,
    DenormalizationHelper,
    Hash,
    Log,
    SmartContract,
    SmartContract.Proxy,
    Token,
    TokenTransfer,
    Transaction,
    Wei
  }

  alias Explorer.SmartContract.SigProviderInterface

  @optional_attrs ~w(max_priority_fee_per_gas max_fee_per_gas block_hash block_number block_consensus block_timestamp created_contract_address_hash cumulative_gas_used earliest_processing_start
                     error gas_price gas_used index created_contract_code_indexed_at status to_address_hash revert_reason type has_error_in_internal_txs)a

  @suave_optional_attrs ~w(execution_node_hash wrapped_type wrapped_nonce wrapped_to_address_hash wrapped_gas wrapped_gas_price wrapped_max_priority_fee_per_gas wrapped_max_fee_per_gas wrapped_value wrapped_input wrapped_v wrapped_r wrapped_s wrapped_hash)a

  @required_attrs ~w(from_address_hash gas hash input nonce r s v value)a

  @empty_attrs ~w()a

  @typedoc """
  X coordinate module n in
  [Elliptic Curve Digital Signature Algorithm](https://en.wikipedia.org/wiki/Elliptic_Curve_Digital_Signature_Algorithm)
  (EDCSA)
  """
  @type r :: Decimal.t()

  @typedoc """
  Y coordinate module n in
  [Elliptic Curve Digital Signature Algorithm](https://en.wikipedia.org/wiki/Elliptic_Curve_Digital_Signature_Algorithm)
  (EDCSA)
  """
  @type s :: Decimal.t()

  @typedoc """
  The index of the transaction in its block.
  """
  @type transaction_index :: non_neg_integer()

  @typedoc """
  `t:standard_v/0` + `27`

  | `v`  | X      | Y    |
  |------|--------|------|
  | `27` | lower  | even |
  | `28` | lower  | odd  |
  | `29` | higher | even |
  | `30` | higher | odd  |

  **Note: that `29` and `30` are exceedingly rarely, and will in practice only ever be seen in specifically generated
  examples.**
  """
  @type v :: 27..30

  @typedoc """
  How much the sender is willing to pay in wei per unit of gas.
  """
  @type wei_per_gas :: Wei.t()

  @derive {Poison.Encoder,
           only: [
             :block_number,
             :block_timestamp,
             :cumulative_gas_used,
             :error,
             :gas,
             :gas_price,
             :gas_used,
             :index,
             :created_contract_code_indexed_at,
             :input,
             :nonce,
             :r,
             :s,
             :v,
             :status,
             :value,
             :revert_reason
           ]}

  @derive {Jason.Encoder,
           only: [
             :block_number,
             :block_timestamp,
             :cumulative_gas_used,
             :error,
             :gas,
             :gas_price,
             :gas_used,
             :index,
             :created_contract_code_indexed_at,
             :input,
             :nonce,
             :r,
             :s,
             :v,
             :status,
             :value,
             :revert_reason
           ]}

  @typedoc """
   * `block` - the block in which this transaction was mined/validated.  `nil` when transaction is pending or has only
     been collated into one of the `uncles` in one of the `forks`.
   * `block_hash` - `block` foreign key. `nil` when transaction is pending or has only been collated into one of the
     `uncles` in one of the `forks`.
   * `block_number` - Denormalized `block` `number`. `nil` when transaction is pending or has only been collated into
     one of the `uncles` in one of the `forks`.
   * `block_consensus` - consensus of the block where transaction collated.
   * `block_timestamp` - timestamp of the block where transaction collated.
   * `created_contract_address` - belongs_to association to `address` corresponding to `created_contract_address_hash`.
   * `created_contract_address_hash` - Denormalized `internal_transaction` `created_contract_address_hash`
     populated only when `to_address_hash` is nil.
   * `cumulative_gas_used` - the cumulative gas used in `transaction`'s `t:Explorer.Chain.Block.t/0` before
     `transaction`'s `index`.  `nil` when transaction is pending
   * `earliest_processing_start` - If the pending transaction fetcher was alive and received this transaction, we can
      be sure that this transaction did not start processing until after the last time we fetched pending transactions,
      so we annotate that with this field. If it is `nil`, that means we don't have a lower bound for when it started
      processing.
   * `error` - the `error` from the last `t:Explorer.Chain.InternalTransaction.t/0` in `internal_transactions` that
     caused `status` to be `:error`.  Only set after `internal_transactions_index_at` is set AND if there was an error.
     Also, `error` is set if transaction is replaced/dropped
   * `forks` - copies of this transactions that were collated into `uncles` not on the primary consensus of the chain.
   * `from_address` - the source of `value`
   * `from_address_hash` - foreign key of `from_address`
   * `gas` - Gas provided by the sender
   * `gas_price` - How much the sender is willing to pay for `gas`
   * `gas_used` - the gas used for just `transaction`.  `nil` when transaction is pending or has only been collated into
     one of the `uncles` in one of the `forks`.
   * `hash` - hash of contents of this transaction
   * `index` - index of this transaction in `block`.  `nil` when transaction is pending or has only been collated into
     one of the `uncles` in one of the `forks`.
   * `input`- data sent along with the transaction
   * `internal_transactions` - transactions (value transfers) created while executing contract used for this
     transaction
   * `created_contract_code_indexed_at` - when created `address` code was fetched by `Indexer`
   * `revert_reason` - revert reason of transaction

     | `status` | `contract_creation_address_hash` | `input`    | Token Transfer? | `internal_transactions_indexed_at`        | `internal_transactions` | Description                                                                                         |
     |----------|----------------------------------|------------|-----------------|-------------------------------------------|-------------------------|-----------------------------------------------------------------------------------------------------|
     | `:ok`    | `nil`                            | Empty      | Don't Care      | `inserted_at`                             | Unfetched               | Simple `value` transfer transaction succeeded.  Internal transactions would be same value transfer. |
     | `:ok`    | `nil`                            | Don't Care | `true`          | `inserted_at`                             | Unfetched               | Token transfer (from `logs`) that didn't happen during a contract creation.                         |
     | `:ok`    | Don't Care                       | Non-Empty  | Don't Care      | When `internal_transactions` are indexed. | Fetched                 | A contract call that succeeded.                                                                     |
     | `:error` | nil                              | Empty      | Don't Care      | When `internal_transactions` are indexed. | Fetched                 | Simple `value` transfer transaction failed. Internal transactions fetched for `error`.              |
     | `:error` | Don't Care                       | Non-Empty  | Don't Care      | When `internal_transactions` are indexed. | Fetched                 | A contract call that failed.                                                                        |
     | `nil`    | Don't Care                       | Don't Care | Don't Care      | When `internal_transactions` are indexed. | Depends                 | A pending post-Byzantium transaction will only know its status from receipt.                        |
     | `nil`    | Don't Care                       | Don't Care | Don't Care      | When `internal_transactions` are indexed. | Fetched                 | A pre-Byzantium transaction requires internal transactions to determine status.                     |
   * `logs` - events that occurred while mining the `transaction`.
   * `nonce` - the number of transaction made by the sender prior to this one
   * `r` - the R field of the signature. The (r, s) is the normal output of an ECDSA signature, where r is computed as
       the X coordinate of a point R, modulo the curve order n.
   * `s` - The S field of the signature.  The (r, s) is the normal output of an ECDSA signature, where r is computed as
       the X coordinate of a point R, modulo the curve order n.
   * `status` - whether the transaction was successfully mined or failed.  `nil` when transaction is pending or has only
     been collated into one of the `uncles` in one of the `forks`.
   * `to_address` - sink of `value`
   * `to_address_hash` - `to_address` foreign key
   * `uncles` - uncle blocks where `forks` were collated
   * `v` - The V field of the signature.
   * `value` - wei transferred from `from_address` to `to_address`
   * `revert_reason` - revert reason of transaction
   * `max_priority_fee_per_gas` - User defined maximum fee (tip) per unit of gas paid to validator for transaction prioritization.
   * `max_fee_per_gas` - Maximum total amount per unit of gas a user is willing to pay for a transaction, including base fee and priority fee.
   * `type` - New transaction type identifier introduced in EIP 2718 (Berlin HF)
   * `has_error_in_internal_txs` - shows if the internal transactions related to transaction have errors
   * `execution_node` - execution node address (used by Suave)
   * `execution_node_hash` - foreign key of `execution_node` (used by Suave)
   * `wrapped_type` - transaction type from the `wrapped` field (used by Suave)
   * `wrapped_nonce` - nonce from the `wrapped` field (used by Suave)
   * `wrapped_to_address` - target address from the `wrapped` field (used by Suave)
   * `wrapped_to_address_hash` - `wrapped_to_address` foreign key (used by Suave)
   * `wrapped_gas` - gas from the `wrapped` field (used by Suave)
   * `wrapped_gas_price` - gas_price from the `wrapped` field (used by Suave)
   * `wrapped_max_priority_fee_per_gas` - max_priority_fee_per_gas from the `wrapped` field (used by Suave)
   * `wrapped_max_fee_per_gas` - max_fee_per_gas from the `wrapped` field (used by Suave)
   * `wrapped_value` - value from the `wrapped` field (used by Suave)
   * `wrapped_input` - data from the `wrapped` field (used by Suave)
   * `wrapped_v` - V field of the signature from the `wrapped` field (used by Suave)
   * `wrapped_r` - R field of the signature from the `wrapped` field (used by Suave)
   * `wrapped_s` - S field of the signature from the `wrapped` field (used by Suave)
   * `wrapped_hash` - hash from the `wrapped` field (used by Suave)
  """
  Explorer.Chain.Transaction.Schema.generate()

  @doc """
  A pending transaction does not have a `block_hash`

      iex> changeset = Explorer.Chain.Transaction.changeset(
      ...>   %Transaction{},
      ...>   %{
      ...>     from_address_hash: "0xe8ddc5c7a2d2f0d7a9798459c0104fdf5e987aca",
      ...>     gas: 4700000,
      ...>     gas_price: 100000000000,
      ...>     hash: "0x3a3eb134e6792ce9403ea4188e5e79693de9e4c94e499db132be086400da79e6",
      ...>     input: "0x6060604052341561000f57600080fd5b336000806101000a81548173ffffffffffffffffffffffffffffffffffffffff021916908373ffffffffffffffffffffffffffffffffffffffff1602179055506102db8061005e6000396000f300606060405260043610610062576000357c0100000000000000000000000000000000000000000000000000000000900463ffffffff1680630900f01014610067578063445df0ac146100a05780638da5cb5b146100c9578063fdacd5761461011e575b600080fd5b341561007257600080fd5b61009e600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050610141565b005b34156100ab57600080fd5b6100b3610224565b6040518082815260200191505060405180910390f35b34156100d457600080fd5b6100dc61022a565b604051808273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390f35b341561012957600080fd5b61013f600480803590602001909190505061024f565b005b60008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff161415610220578190508073ffffffffffffffffffffffffffffffffffffffff1663fdacd5766001546040518263ffffffff167c010000000000000000000000000000000000000000000000000000000002815260040180828152602001915050600060405180830381600087803b151561020b57600080fd5b6102c65a03f1151561021c57600080fd5b5050505b5050565b60015481565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1681565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff1614156102ac57806001819055505b505600a165627a7a72305820a9c628775efbfbc17477a472413c01ee9b33881f550c59d21bee9928835c854b0029",
      ...>     nonce: 0,
      ...>     r: 0xAD3733DF250C87556335FFE46C23E34DBAFFDE93097EF92F52C88632A40F0C75,
      ...>     s: 0x72caddc0371451a58de2ca6ab64e0f586ccdb9465ff54e1c82564940e89291e3,
      ...>     v: 0x8d,
      ...>     value: 0
      ...>   }
      ...> )
      iex> changeset.valid?
      true

  A pending transaction does not have a `gas_price` (Erigon)

      iex> changeset = Explorer.Chain.Transaction.changeset(
      ...>   %Transaction{},
      ...>   %{
      ...>     from_address_hash: "0xe8ddc5c7a2d2f0d7a9798459c0104fdf5e987aca",
      ...>     gas: 4700000,
      ...>     hash: "0x3a3eb134e6792ce9403ea4188e5e79693de9e4c94e499db132be086400da79e6",
      ...>     input: "0x6060604052341561000f57600080fd5b336000806101000a81548173ffffffffffffffffffffffffffffffffffffffff021916908373ffffffffffffffffffffffffffffffffffffffff1602179055506102db8061005e6000396000f300606060405260043610610062576000357c0100000000000000000000000000000000000000000000000000000000900463ffffffff1680630900f01014610067578063445df0ac146100a05780638da5cb5b146100c9578063fdacd5761461011e575b600080fd5b341561007257600080fd5b61009e600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050610141565b005b34156100ab57600080fd5b6100b3610224565b6040518082815260200191505060405180910390f35b34156100d457600080fd5b6100dc61022a565b604051808273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390f35b341561012957600080fd5b61013f600480803590602001909190505061024f565b005b60008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff161415610220578190508073ffffffffffffffffffffffffffffffffffffffff1663fdacd5766001546040518263ffffffff167c010000000000000000000000000000000000000000000000000000000002815260040180828152602001915050600060405180830381600087803b151561020b57600080fd5b6102c65a03f1151561021c57600080fd5b5050505b5050565b60015481565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1681565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff1614156102ac57806001819055505b505600a165627a7a72305820a9c628775efbfbc17477a472413c01ee9b33881f550c59d21bee9928835c854b0029",
      ...>     nonce: 0,
      ...>     r: 0xAD3733DF250C87556335FFE46C23E34DBAFFDE93097EF92F52C88632A40F0C75,
      ...>     s: 0x72caddc0371451a58de2ca6ab64e0f586ccdb9465ff54e1c82564940e89291e3,
      ...>     v: 0x8d,
      ...>     value: 0
      ...>   }
      ...> )
      iex> changeset.valid?
      true

  A collated transaction MUST have an `index` so its position in the `block` is known and the `cumulative_gas_used` ane
  `gas_used` to know its fees.

  Post-Byzantium, the status must be present when a block is collated.

      iex> changeset = Explorer.Chain.Transaction.changeset(
      ...>   %Transaction{},
      ...>   %{
      ...>     block_hash: "0xe52d77084cab13a4e724162bcd8c6028e5ecfaa04d091ee476e96b9958ed6b47",
      ...>     block_number: 34,
      ...>     cumulative_gas_used: 0,
      ...>     from_address_hash: "0xe8ddc5c7a2d2f0d7a9798459c0104fdf5e987aca",
      ...>     gas: 4700000,
      ...>     gas_price: 100000000000,
      ...>     gas_used: 4600000,
      ...>     hash: "0x3a3eb134e6792ce9403ea4188e5e79693de9e4c94e499db132be086400da79e6",
      ...>     index: 0,
      ...>     input: "0x6060604052341561000f57600080fd5b336000806101000a81548173ffffffffffffffffffffffffffffffffffffffff021916908373ffffffffffffffffffffffffffffffffffffffff1602179055506102db8061005e6000396000f300606060405260043610610062576000357c0100000000000000000000000000000000000000000000000000000000900463ffffffff1680630900f01014610067578063445df0ac146100a05780638da5cb5b146100c9578063fdacd5761461011e575b600080fd5b341561007257600080fd5b61009e600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050610141565b005b34156100ab57600080fd5b6100b3610224565b6040518082815260200191505060405180910390f35b34156100d457600080fd5b6100dc61022a565b604051808273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390f35b341561012957600080fd5b61013f600480803590602001909190505061024f565b005b60008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff161415610220578190508073ffffffffffffffffffffffffffffffffffffffff1663fdacd5766001546040518263ffffffff167c010000000000000000000000000000000000000000000000000000000002815260040180828152602001915050600060405180830381600087803b151561020b57600080fd5b6102c65a03f1151561021c57600080fd5b5050505b5050565b60015481565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1681565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff1614156102ac57806001819055505b505600a165627a7a72305820a9c628775efbfbc17477a472413c01ee9b33881f550c59d21bee9928835c854b0029",
      ...>     nonce: 0,
      ...>     r: 0xAD3733DF250C87556335FFE46C23E34DBAFFDE93097EF92F52C88632A40F0C75,
      ...>     s: 0x72caddc0371451a58de2ca6ab64e0f586ccdb9465ff54e1c82564940e89291e3,
      ...>     status: :ok,
      ...>     v: 0x8d,
      ...>     value: 0
      ...>   }
      ...> )
      iex> changeset.valid?
      true

  But, pre-Byzantium the status cannot be known until the `Explorer.Chain.InternalTransaction` are checked for an
  `error`, so `status` is not required since we can't from the transaction data alone check if the chain is pre- or
  post-Byzantium.

      iex> changeset = Explorer.Chain.Transaction.changeset(
      ...>   %Transaction{},
      ...>   %{
      ...>     block_hash: "0xe52d77084cab13a4e724162bcd8c6028e5ecfaa04d091ee476e96b9958ed6b47",
      ...>     block_number: 34,
      ...>     cumulative_gas_used: 0,
      ...>     from_address_hash: "0xe8ddc5c7a2d2f0d7a9798459c0104fdf5e987aca",
      ...>     gas: 4700000,
      ...>     gas_price: 100000000000,
      ...>     gas_used: 4600000,
      ...>     hash: "0x3a3eb134e6792ce9403ea4188e5e79693de9e4c94e499db132be086400da79e6",
      ...>     index: 0,
      ...>     input: "0x6060604052341561000f57600080fd5b336000806101000a81548173ffffffffffffffffffffffffffffffffffffffff021916908373ffffffffffffffffffffffffffffffffffffffff1602179055506102db8061005e6000396000f300606060405260043610610062576000357c0100000000000000000000000000000000000000000000000000000000900463ffffffff1680630900f01014610067578063445df0ac146100a05780638da5cb5b146100c9578063fdacd5761461011e575b600080fd5b341561007257600080fd5b61009e600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050610141565b005b34156100ab57600080fd5b6100b3610224565b6040518082815260200191505060405180910390f35b34156100d457600080fd5b6100dc61022a565b604051808273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390f35b341561012957600080fd5b61013f600480803590602001909190505061024f565b005b60008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff161415610220578190508073ffffffffffffffffffffffffffffffffffffffff1663fdacd5766001546040518263ffffffff167c010000000000000000000000000000000000000000000000000000000002815260040180828152602001915050600060405180830381600087803b151561020b57600080fd5b6102c65a03f1151561021c57600080fd5b5050505b5050565b60015481565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1681565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff1614156102ac57806001819055505b505600a165627a7a72305820a9c628775efbfbc17477a472413c01ee9b33881f550c59d21bee9928835c854b0029",
      ...>     nonce: 0,
      ...>     r: 0xAD3733DF250C87556335FFE46C23E34DBAFFDE93097EF92F52C88632A40F0C75,
      ...>     s: 0x72caddc0371451a58de2ca6ab64e0f586ccdb9465ff54e1c82564940e89291e3,
      ...>     v: 0x8d,
      ...>     value: 0
      ...>   }
      ...> )
      iex> changeset.valid?
      true

  The `error` can only be set with a specific error message when `status` is `:error`

      iex> changeset = Explorer.Chain.Transaction.changeset(
      ...>   %Transaction{},
      ...>   %{
      ...>     block_hash: "0xe52d77084cab13a4e724162bcd8c6028e5ecfaa04d091ee476e96b9958ed6b47",
      ...>     block_number: 34,
      ...>     cumulative_gas_used: 0,
      ...>     error: "Out of gas",
      ...>     gas: 4700000,
      ...>     gas_price: 100000000000,
      ...>     gas_used: 4600000,
      ...>     hash: "0x3a3eb134e6792ce9403ea4188e5e79693de9e4c94e499db132be086400da79e6",
      ...>     index: 0,
      ...>     input: "0x6060604052341561000f57600080fd5b336000806101000a81548173ffffffffffffffffffffffffffffffffffffffff021916908373ffffffffffffffffffffffffffffffffffffffff1602179055506102db8061005e6000396000f300606060405260043610610062576000357c0100000000000000000000000000000000000000000000000000000000900463ffffffff1680630900f01014610067578063445df0ac146100a05780638da5cb5b146100c9578063fdacd5761461011e575b600080fd5b341561007257600080fd5b61009e600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050610141565b005b34156100ab57600080fd5b6100b3610224565b6040518082815260200191505060405180910390f35b34156100d457600080fd5b6100dc61022a565b604051808273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390f35b341561012957600080fd5b61013f600480803590602001909190505061024f565b005b60008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff161415610220578190508073ffffffffffffffffffffffffffffffffffffffff1663fdacd5766001546040518263ffffffff167c010000000000000000000000000000000000000000000000000000000002815260040180828152602001915050600060405180830381600087803b151561020b57600080fd5b6102c65a03f1151561021c57600080fd5b5050505b5050565b60015481565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1681565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff1614156102ac57806001819055505b505600a165627a7a72305820a9c628775efbfbc17477a472413c01ee9b33881f550c59d21bee9928835c854b0029",
      ...>     nonce: 0,
      ...>     r: 0xAD3733DF250C87556335FFE46C23E34DBAFFDE93097EF92F52C88632A40F0C75,
      ...>     s: 0x72caddc0371451a58de2ca6ab64e0f586ccdb9465ff54e1c82564940e89291e3,
      ...>     v: 0x8d,
      ...>     value: 0
      ...>   }
      ...> )
      iex> changeset.valid?
      false
      iex> Keyword.get_values(changeset.errors, :error)
      [{"can't be set when status is not :error", []}]

      iex> changeset = Explorer.Chain.Transaction.changeset(
      ...>   %Transaction{},
      ...>   %{
      ...>     block_hash: "0xe52d77084cab13a4e724162bcd8c6028e5ecfaa04d091ee476e96b9958ed6b47",
      ...>     block_number: 34,
      ...>     cumulative_gas_used: 0,
      ...>     error: "Out of gas",
      ...>     from_address_hash: "0xe8ddc5c7a2d2f0d7a9798459c0104fdf5e987aca",
      ...>     gas: 4700000,
      ...>     gas_price: 100000000000,
      ...>     gas_used: 4600000,
      ...>     hash: "0x3a3eb134e6792ce9403ea4188e5e79693de9e4c94e499db132be086400da79e6",
      ...>     index: 0,
      ...>     input: "0x6060604052341561000f57600080fd5b336000806101000a81548173ffffffffffffffffffffffffffffffffffffffff021916908373ffffffffffffffffffffffffffffffffffffffff1602179055506102db8061005e6000396000f300606060405260043610610062576000357c0100000000000000000000000000000000000000000000000000000000900463ffffffff1680630900f01014610067578063445df0ac146100a05780638da5cb5b146100c9578063fdacd5761461011e575b600080fd5b341561007257600080fd5b61009e600480803573ffffffffffffffffffffffffffffffffffffffff16906020019091905050610141565b005b34156100ab57600080fd5b6100b3610224565b6040518082815260200191505060405180910390f35b34156100d457600080fd5b6100dc61022a565b604051808273ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff16815260200191505060405180910390f35b341561012957600080fd5b61013f600480803590602001909190505061024f565b005b60008060009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff161415610220578190508073ffffffffffffffffffffffffffffffffffffffff1663fdacd5766001546040518263ffffffff167c010000000000000000000000000000000000000000000000000000000002815260040180828152602001915050600060405180830381600087803b151561020b57600080fd5b6102c65a03f1151561021c57600080fd5b5050505b5050565b60015481565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1681565b6000809054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff163373ffffffffffffffffffffffffffffffffffffffff1614156102ac57806001819055505b505600a165627a7a72305820a9c628775efbfbc17477a472413c01ee9b33881f550c59d21bee9928835c854b0029",
      ...>     nonce: 0,
      ...>     r: 0xAD3733DF250C87556335FFE46C23E34DBAFFDE93097EF92F52C88632A40F0C75,
      ...>     s: 0x72caddc0371451a58de2ca6ab64e0f586ccdb9465ff54e1c82564940e89291e3,
      ...>     status: :error,
      ...>     v: 0x8d,
      ...>     value: 0
      ...>   }
      ...> )
      iex> changeset.valid?
      true

  """
  def changeset(%__MODULE__{} = transaction, attrs \\ %{}) do
    attrs_to_cast =
      @required_attrs ++
        @optional_attrs ++
        if Application.get_env(:explorer, :chain_type) == "suave", do: @suave_optional_attrs, else: @empty_attrs

    transaction
    |> cast(attrs, attrs_to_cast)
    |> validate_required(@required_attrs)
    |> validate_collated()
    |> validate_error()
    |> validate_status()
    |> check_collated()
    |> check_error()
    |> check_status()
    |> foreign_key_constraint(:block_hash)
    |> unique_constraint(:hash)
  end

  @spec block_timestamp(t()) :: DateTime.t()
  def block_timestamp(%{block_number: nil, inserted_at: time}), do: time
  def block_timestamp(%{block_timestamp: time}) when not is_nil(time), do: time
  def block_timestamp(%{block: %{timestamp: time}}), do: time

  def preload_token_transfers(query, address_hash) do
    token_transfers_query =
      from(
        tt in TokenTransfer,
        where:
          tt.token_contract_address_hash == ^address_hash or tt.to_address_hash == ^address_hash or
            tt.from_address_hash == ^address_hash,
        order_by: [asc: tt.log_index],
        preload: [:token, [from_address: :names], [to_address: :names]]
      )

    preload(query, [tt], token_transfers: ^token_transfers_query)
  end

  def decoded_revert_reason(transaction, revert_reason, options \\ []) do
    hex =
      case revert_reason do
        "0x" <> hex_part ->
          hex_part

        hex ->
          hex
      end

    process_hex_revert_reason(hex, transaction, options)
  end

  defp process_hex_revert_reason(hex_revert_reason, %__MODULE__{to_address: smart_contract, hash: hash}, options) do
    case Integer.parse(hex_revert_reason, 16) do
      {number, ""} ->
        binary_revert_reason = :binary.encode_unsigned(number)

        {result, _, _} =
          decoded_input_data(
            %Transaction{
              to_address: smart_contract,
              hash: hash,
              input: %Data{bytes: binary_revert_reason}
            },
            options
          )

        result

      _ ->
        hex_revert_reason
    end
  end

  # Because there is no contract association, we know the contract was not verified
  @spec decoded_input_data(
          NotLoaded.t() | Transaction.t(),
          boolean(),
          [Chain.api?()],
          full_abi_acc,
          methods_acc
        ) ::
          {error_type | success_type, full_abi_acc, methods_acc}
        when full_abi_acc: map(),
             methods_acc: map(),
             error_type: {:error, any()} | {:error, :contract_not_verified | :contract_verified, list()},
             success_type: {:ok | binary(), any()} | {:ok, binary(), binary(), list()}
  def decoded_input_data(tx, skip_sig_provider? \\ false, options, full_abi_acc \\ %{}, methods_acc \\ %{})

  def decoded_input_data(%__MODULE__{to_address: nil}, _, _, full_abi_acc, methods_acc),
    do: {{:error, :no_to_address}, full_abi_acc, methods_acc}

  def decoded_input_data(%NotLoaded{}, _, _, full_abi_acc, methods_acc),
    do: {{:error, :not_loaded}, full_abi_acc, methods_acc}

  def decoded_input_data(%__MODULE__{input: %{bytes: bytes}}, _, _, full_abi_acc, methods_acc)
      when bytes in [nil, <<>>],
      do: {{:error, :no_input_data}, full_abi_acc, methods_acc}

  if not Application.compile_env(:explorer, :decode_not_a_contract_calls) do
    def decoded_input_data(%__MODULE__{to_address: %{contract_code: nil}}, _, _, full_abi_acc, methods_acc),
      do: {{:error, :not_a_contract_call}, full_abi_acc, methods_acc}
  end

  def decoded_input_data(
        %__MODULE__{
          to_address: %{smart_contract: nil},
          input: input,
          hash: hash
        },
        skip_sig_provider?,
        options,
        full_abi_acc,
        methods_acc
      ) do
    decoded_input_data(
      %__MODULE__{
        to_address: %NotLoaded{},
        input: input,
        hash: hash
      },
      skip_sig_provider?,
      options,
      full_abi_acc,
      methods_acc
    )
  end

  def decoded_input_data(
        %__MODULE__{
          to_address: %{smart_contract: %NotLoaded{}},
          input: input,
          hash: hash
        },
        skip_sig_provider?,
        options,
        full_abi_acc,
        methods_acc
      ) do
    decoded_input_data(
      %__MODULE__{
        to_address: %NotLoaded{},
        input: input,
        hash: hash
      },
      skip_sig_provider?,
      options,
      full_abi_acc,
      methods_acc
    )
  end

  def decoded_input_data(
        %__MODULE__{
          to_address: %NotLoaded{},
          input: %{bytes: <<method_id::binary-size(4), _::binary>> = data} = input,
          hash: hash
        },
        skip_sig_provider?,
        options,
        full_abi_acc,
        methods_acc
      ) do
    {methods, methods_acc} =
      method_id
      |> check_methods_cache(methods_acc, options)

    candidates =
      methods
      |> Enum.flat_map(fn candidate ->
        case do_decoded_input_data(data, %SmartContract{abi: [candidate.abi], address_hash: nil}, hash, options, %{}) do
          {{:ok, _, _, _} = decoded, _} -> [decoded]
          _ -> []
        end
      end)

    {{:error, :contract_not_verified,
      if(candidates == [], do: decode_function_call_via_sig_provider(input, hash, skip_sig_provider?), else: candidates)},
     full_abi_acc, methods_acc}
  end

  def decoded_input_data(%__MODULE__{to_address: %NotLoaded{}}, _, _, full_abi_acc, methods_acc) do
    {{:error, :contract_not_verified, []}, full_abi_acc, methods_acc}
  end

  def decoded_input_data(
        %__MODULE__{
          input: %{bytes: data} = input,
          to_address: %{smart_contract: smart_contract},
          hash: hash
        },
        skip_sig_provider?,
        options,
        full_abi_acc,
        methods_acc
      ) do
    case do_decoded_input_data(data, smart_contract, hash, options, full_abi_acc) do
      # In some cases transactions use methods of some unpredictable contracts, so we can try to look up for method in a whole DB
      {{:error, :could_not_decode}, full_abi_acc} ->
        case decoded_input_data(
               %__MODULE__{
                 to_address: %NotLoaded{},
                 input: input,
                 hash: hash
               },
               skip_sig_provider?,
               options,
               full_abi_acc,
               methods_acc
             ) do
          {{:error, :contract_not_verified, []}, full_abi_acc, methods_acc} ->
            {decode_function_call_via_sig_provider_wrapper(input, hash, skip_sig_provider?), full_abi_acc, methods_acc}

          {{:error, :contract_not_verified, candidates}, full_abi_acc, methods_acc} ->
            {{:error, :contract_verified, candidates}, full_abi_acc, methods_acc}

          {_, full_abi_acc, methods_acc} ->
            {{:error, :could_not_decode}, full_abi_acc, methods_acc}
        end

      {output, full_abi_acc} ->
        {output, full_abi_acc, methods_acc}
    end
  end

  defp decode_function_call_via_sig_provider_wrapper(input, hash, skip_sig_provider?) do
    case decode_function_call_via_sig_provider(input, hash, skip_sig_provider?) do
      [] ->
        {:error, :could_not_decode}

      result ->
        {:error, :contract_verified, result}
    end
  end

  defp do_decoded_input_data(data, smart_contract, hash, options, full_abi_acc) do
    {full_abi, full_abi_acc} = check_full_abi_cache(smart_contract, full_abi_acc, options)

    {with(
       {:ok, {selector, values}} <- find_and_decode(full_abi, data, hash),
       {:ok, mapping} <- selector_mapping(selector, values, hash),
       identifier <- Base.encode16(selector.method_id, case: :lower),
       text <- function_call(selector.function, mapping),
       do: {:ok, identifier, text, mapping}
     ), full_abi_acc}
  end

  defp decode_function_call_via_sig_provider(%{bytes: data} = input, hash, skip_sig_provider?) do
    with true <- SigProviderInterface.enabled?(),
         false <- skip_sig_provider?,
         {:ok, result} <- SigProviderInterface.decode_function_call(input),
         true <- is_list(result),
         false <- Enum.empty?(result),
         abi <- [result |> List.first() |> Map.put("outputs", []) |> Map.put("type", "function")],
         {{:ok, _, _, _} = candidate, _} <-
           do_decoded_input_data(data, %SmartContract{abi: abi, address_hash: nil}, hash, [], %{}) do
      [candidate]
    else
      _ ->
        []
    end
  end

  defp check_methods_cache(method_id, methods_acc, options) do
    if Map.has_key?(methods_acc, method_id) do
      {methods_acc[method_id], methods_acc}
    else
      candidates_query = ContractMethod.find_contract_method_query(method_id, 1)

      result =
        candidates_query
        |> Chain.select_repo(options).all()

      {result, Map.put(methods_acc, method_id, result)}
    end
  end

  defp check_full_abi_cache(%{address_hash: address_hash} = smart_contract, full_abi_acc, options) do
    if !is_nil(address_hash) && Map.has_key?(full_abi_acc, address_hash) do
      {full_abi_acc[address_hash], full_abi_acc}
    else
      full_abi = Proxy.combine_proxy_implementation_abi(smart_contract, options)

      {full_abi, Map.put(full_abi_acc, address_hash, full_abi)}
    end
  end

  def get_method_name(
        %__MODULE__{
          input: %{bytes: <<method_id::binary-size(4), _::binary>>}
        } = transaction
      ) do
    if transaction.created_contract_address_hash do
      nil
    else
      case decoded_input_data(
             %__MODULE__{
               to_address: %NotLoaded{},
               input: transaction.input,
               hash: transaction.hash
             },
             true,
             []
           ) do
        {{:error, :contract_not_verified, [{:ok, _method_id, decoded_func, _}]}, _, _} ->
          parse_method_name(decoded_func)

        {{:error, :contract_not_verified, []}, _, _} ->
          "0x" <> Base.encode16(method_id, case: :lower)

        _ ->
          "Transfer"
      end
    end
  end

  def get_method_name(_), do: "Transfer"

  def parse_method_name(method_desc, need_upcase \\ true) do
    method_desc
    |> String.split("(")
    |> Enum.at(0)
    |> upcase_first(need_upcase)
  end

  defp upcase_first(string, false), do: string

  defp upcase_first(<<first::utf8, rest::binary>>, true), do: String.upcase(<<first::utf8>>) <> rest

  defp function_call(name, mapping) do
    text =
      mapping
      |> Stream.map(fn {name, type, _} -> [type, " ", name] end)
      |> Enum.intersperse(", ")

    IO.iodata_to_binary([name, "(", text, ")"])
  end

  defp find_and_decode(abi, data, hash) do
    with {%FunctionSelector{}, _mapping} = result <-
           abi
           |> ABI.parse_specification()
           |> ABI.find_and_decode(data) do
      {:ok, result}
    end
  rescue
    e ->
      Logger.warn(fn ->
        [
          "Could not decode input data for transaction: ",
          Hash.to_iodata(hash),
          Exception.format(:error, e, __STACKTRACE__)
        ]
      end)

      {:error, :could_not_decode}
  end

  defp selector_mapping(selector, values, hash) do
    types = Enum.map(selector.types, &FunctionSelector.encode_type/1)

    mapping = Enum.zip([selector.input_names, types, values])

    {:ok, mapping}
  rescue
    e ->
      Logger.warn(fn ->
        [
          "Could not decode input data for transaction: ",
          Hash.to_iodata(hash),
          Exception.format(:error, e, __STACKTRACE__)
        ]
      end)

      {:error, :could_not_decode}
  end

  @doc """
  Produces a list of queries starting from the given one and adding filters for
  transactions that are linked to the given address_hash through a direction.
  """
  def matching_address_queries_list(query, :from, address_hashes) when is_list(address_hashes) do
    [where(query, [t], t.from_address_hash in ^address_hashes)]
  end

  def matching_address_queries_list(query, :to, address_hashes) when is_list(address_hashes) do
    [
      where(query, [t], t.to_address_hash in ^address_hashes),
      where(query, [t], t.created_contract_address_hash in ^address_hashes)
    ]
  end

  def matching_address_queries_list(query, _direction, address_hashes) when is_list(address_hashes) do
    [
      where(query, [t], t.from_address_hash in ^address_hashes),
      where(query, [t], t.to_address_hash in ^address_hashes),
      where(query, [t], t.created_contract_address_hash in ^address_hashes)
    ]
  end

  def matching_address_queries_list(query, :from, address_hash) do
    [where(query, [t], t.from_address_hash == ^address_hash)]
  end

  def matching_address_queries_list(query, :to, address_hash) do
    [
      where(query, [t], t.to_address_hash == ^address_hash),
      where(query, [t], t.created_contract_address_hash == ^address_hash)
    ]
  end

  def matching_address_queries_list(query, _direction, address_hash) do
    [
      where(query, [t], t.from_address_hash == ^address_hash),
      where(query, [t], t.to_address_hash == ^address_hash),
      where(query, [t], t.created_contract_address_hash == ^address_hash)
    ]
  end

  def not_pending_transactions(query) do
    where(query, [t], not is_nil(t.block_number))
  end

  def not_dropped_or_replaced_transactions(query) do
    where(query, [t], is_nil(t.error) or t.error != "dropped/replaced")
  end

  @collated_fields ~w(block_number cumulative_gas_used gas_used index)a

  @collated_message "can't be blank when the transaction is collated into a block"
  @collated_field_to_check Enum.into(@collated_fields, %{}, fn collated_field ->
                             {collated_field, :"collated_#{collated_field}}"}
                           end)

  defp check_collated(%Changeset{} = changeset) do
    check_constraints(changeset, @collated_field_to_check, @collated_message)
  end

  @error_message "can't be set when status is not :error"

  defp check_error(%Changeset{} = changeset) do
    check_constraint(changeset, :error, message: @error_message, name: :error)
  end

  @status_message "can't be set when the block_hash is unknown"

  defp check_status(%Changeset{} = changeset) do
    check_constraint(changeset, :status, message: @status_message, name: :status)
  end

  defp check_constraints(%Changeset{} = changeset, field_to_name, message)
       when is_map(field_to_name) and is_binary(message) do
    Enum.reduce(field_to_name, changeset, fn {field, name}, acc_changeset ->
      check_constraint(
        acc_changeset,
        field,
        message: message,
        name: name
      )
    end)
  end

  defp validate_collated(%Changeset{} = changeset) do
    case Changeset.get_field(changeset, :block_hash) do
      %Hash{} -> Enum.reduce(@collated_fields, changeset, &validate_collated/2)
      nil -> changeset
    end
  end

  defp validate_collated(field, %Changeset{} = changeset) when is_atom(field) do
    case Changeset.get_field(changeset, field) do
      nil -> Changeset.add_error(changeset, field, @collated_message)
      _ -> changeset
    end
  end

  defp validate_error(%Changeset{} = changeset) do
    if Changeset.get_field(changeset, :status) != :error and Changeset.get_field(changeset, :error) != nil do
      Changeset.add_error(changeset, :error, @error_message)
    else
      changeset
    end
  end

  defp validate_status(%Changeset{} = changeset) do
    if Changeset.get_field(changeset, :block_hash) == nil and
         Changeset.get_field(changeset, :status) != nil do
      Changeset.add_error(changeset, :status, @status_message)
    else
      changeset
    end
  end

  @doc """
  Builds an `Ecto.Query` to fetch transactions with token transfers from the give address hash.

  The results will be ordered by block number and index DESC.
  """
  def transactions_with_token_transfers(address_hash, token_hash) do
    query = transactions_with_token_transfers_query(address_hash, token_hash)
    preloads = DenormalizationHelper.extend_block_preload([:from_address, :to_address, :created_contract_address])

    from(
      t in subquery(query),
      order_by: [desc: t.block_number, desc: t.index],
      preload: ^preloads
    )
  end

  defp transactions_with_token_transfers_query(address_hash, token_hash) do
    from(
      t in Transaction,
      inner_join: tt in TokenTransfer,
      on: t.hash == tt.transaction_hash,
      where: tt.token_contract_address_hash == ^token_hash,
      where: tt.from_address_hash == ^address_hash or tt.to_address_hash == ^address_hash,
      distinct: :hash
    )
  end

  def transactions_with_token_transfers_direction(direction, address_hash) do
    query = transactions_with_token_transfers_query_direction(direction, address_hash)
    preloads = DenormalizationHelper.extend_block_preload([:from_address, :to_address, :created_contract_address])

    from(
      t in subquery(query),
      order_by: [desc: t.block_number, desc: t.index],
      preload: ^preloads
    )
  end

  defp transactions_with_token_transfers_query_direction(:from, address_hash) do
    from(
      t in Transaction,
      inner_join: tt in TokenTransfer,
      on: t.hash == tt.transaction_hash,
      where: tt.from_address_hash == ^address_hash,
      distinct: :hash
    )
  end

  defp transactions_with_token_transfers_query_direction(:to, address_hash) do
    from(
      t in Transaction,
      inner_join: tt in TokenTransfer,
      on: t.hash == tt.transaction_hash,
      where: tt.to_address_hash == ^address_hash,
      distinct: :hash
    )
  end

  defp transactions_with_token_transfers_query_direction(_, address_hash) do
    from(
      t in Transaction,
      inner_join: tt in TokenTransfer,
      on: t.hash == tt.transaction_hash,
      where: tt.from_address_hash == ^address_hash or tt.to_address_hash == ^address_hash,
      distinct: :hash
    )
  end

  @doc """
  Builds an `Ecto.Query` to fetch transactions with the specified block_number
  """
  def transactions_with_block_number(block_number) do
    from(
      t in Transaction,
      where: t.block_number == ^block_number
    )
  end

  @doc """
  Builds an `Ecto.Query` to fetch the last nonce from the given address hash.

  The last nonce value means the total of transactions that the given address has sent through the
  chain. Also, the query uses the last `block_number` to get the last nonce because this column is
  indexed in DB, then the query is faster than ordering by last nonce.
  """
  def last_nonce_by_address_query(address_hash) do
    from(
      t in Transaction,
      select: t.nonce,
      where: t.from_address_hash == ^address_hash,
      order_by: [desc: :block_number],
      limit: 1
    )
  end

  @doc """
  Returns true if the transaction is a Rootstock REMASC transaction.
  """
  @spec rootstock_remasc_transaction?(Explorer.Chain.Transaction.t()) :: boolean
  def rootstock_remasc_transaction?(%__MODULE__{to_address_hash: to_address_hash}) do
    case Hash.Address.cast(Application.get_env(:explorer, __MODULE__)[:rootstock_remasc_address]) do
      {:ok, address} -> address == to_address_hash
      _ -> false
    end
  end

  @doc """
  Returns true if the transaction is a Rootstock bridge transaction.
  """
  @spec rootstock_bridge_transaction?(Explorer.Chain.Transaction.t()) :: boolean
  def rootstock_bridge_transaction?(%__MODULE__{to_address_hash: to_address_hash}) do
    case Hash.Address.cast(Application.get_env(:explorer, __MODULE__)[:rootstock_bridge_address]) do
      {:ok, address} -> address == to_address_hash
      _ -> false
    end
  end

  @api_true [api?: true]
  @transaction_fee_event_signature "0x99e7b0ba56da2819c37c047f0511fd2bf6c9b4e27b4a979a19d6da0f74be8155"
  @transaction_fee_event_abi [
    %{
      "anonymous" => false,
      "inputs" => [
        %{
          "indexed" => false,
          "internalType" => "address",
          "name" => "token",
          "type" => "address"
        },
        %{
          "indexed" => false,
          "internalType" => "uint256",
          "name" => "totalFee",
          "type" => "uint256"
        },
        %{
          "indexed" => false,
          "internalType" => "address",
          "name" => "validator",
          "type" => "address"
        },
        %{
          "indexed" => false,
          "internalType" => "uint256",
          "name" => "validatorFee",
          "type" => "uint256"
        },
        %{
          "indexed" => false,
          "internalType" => "address",
          "name" => "dapp",
          "type" => "address"
        },
        %{
          "indexed" => false,
          "internalType" => "uint256",
          "name" => "dappFee",
          "type" => "uint256"
        }
      ],
      "name" => "TransactionFee",
      "type" => "event"
    }
  ]

  def maybe_prepare_stability_fees(transactions) do
    if Application.get_env(:explorer, :chain_type) == "stability" do
      maybe_prepare_stability_fees_inner(transactions)
    else
      transactions
    end
  end

  defp maybe_prepare_stability_fees_inner(transactions) when is_list(transactions) do
    {transactions, _tokens_acc} =
      Enum.map_reduce(transactions, %{}, fn transaction, tokens_acc ->
        case Log.fetch_log_by_tx_hash_and_first_topic(transaction.hash, @transaction_fee_event_signature, @api_true) do
          fee_log when not is_nil(fee_log) ->
            {:ok, _selector, mapping} = Log.find_and_decode(@transaction_fee_event_abi, fee_log, transaction.hash)

            [{"token", "address", false, token_address_hash}, _, _, _, _, _] = mapping

            {token, new_tokens_acc} = check_tokens_acc(bytes_to_address_hash(token_address_hash), tokens_acc)

            {%Transaction{transaction | transaction_fee_log: mapping, transaction_fee_token: token}, new_tokens_acc}

          _ ->
            {transaction, tokens_acc}
        end
      end)

    transactions
  end

  defp maybe_prepare_stability_fees_inner(transaction) do
    [transaction] = maybe_prepare_stability_fees_inner([transaction])
    transaction
  end

  defp check_tokens_acc(token_address_hash, tokens_acc) do
    if Map.has_key?(tokens_acc, token_address_hash) do
      {tokens_acc[token_address_hash], tokens_acc}
    else
      token = Token.get_by_contract_address_hash(token_address_hash, @api_true)

      {token, Map.put(tokens_acc, token_address_hash, token)}
    end
  end

  def bytes_to_address_hash(bytes), do: %Hash{byte_count: 20, bytes: bytes}

  @doc """
  Fetches the transactions related to the address with the given hash, including
  transactions that only have the address in the `token_transfers` related table
  and rewards for block validation.

  This query is divided into multiple subqueries intentionally in order to
  improve the listing performance.

  The `token_transfers` table tends to grow exponentially, and the query results
  with a `transactions` `join` statement takes too long.

  To solve this the `transaction_hashes` are fetched in a separate query, and
  paginated through the `block_number` already present in the `token_transfers`
  table.

  ## Options

    * `:necessity_by_association` - use to load `t:association/0` as `:required` or `:optional`.  If an association is
      `:required`, and the `t:Explorer.Chain.Transaction.t/0` has no associated record for that association, then the
      `t:Explorer.Chain.Transaction.t/0` will not be included in the page `entries`.
    * `:paging_options` - a `t:Explorer.PagingOptions.t/0` used to specify the `:page_size` and
      `:key` (a tuple of the lowest/oldest `{block_number, index}`) and. Results will be the transactions older than
      the `block_number` and `index` that are passed.

  """
  @spec address_to_transactions_with_rewards(Hash.Address.t(), [
          Chain.paging_options() | Chain.necessity_by_association_option()
        ]) :: [__MODULE__.t()]
  def address_to_transactions_with_rewards(address_hash, options \\ []) when is_list(options) do
    paging_options = Keyword.get(options, :paging_options, Chain.default_paging_options())

    case Application.get_env(:block_scout_web, BlockScoutWeb.Chain)[:has_emission_funds] &&
           Keyword.get(options, :direction) != :from &&
           Reward.address_has_rewards?(address_hash) &&
           Reward.get_validator_payout_key_by_mining_from_db(address_hash, options) do
      %{payout_key: block_miner_payout_address}
      when not is_nil(block_miner_payout_address) and address_hash == block_miner_payout_address ->
        transactions_with_rewards_results(address_hash, options, paging_options)

      _ ->
        address_to_transactions_without_rewards(address_hash, options)
    end
  end

  defp transactions_with_rewards_results(address_hash, options, paging_options) do
    blocks_range = address_to_transactions_tasks_range_of_blocks(address_hash, options)

    rewards_task =
      Task.async(fn -> Reward.fetch_emission_rewards_tuples(address_hash, paging_options, blocks_range, options) end)

    [rewards_task | address_to_transactions_tasks(address_hash, options, true)]
    |> wait_for_address_transactions()
    |> Enum.sort_by(fn item ->
      case item do
        {%Reward{} = emission_reward, _} ->
          {-emission_reward.block.number, 1}

        item ->
          process_item(item)
      end
    end)
    |> Enum.dedup_by(fn item ->
      case item do
        {%Reward{} = emission_reward, _} ->
          {emission_reward.block_hash, emission_reward.address_hash, emission_reward.address_type}

        transaction ->
          transaction.hash
      end
    end)
    |> Enum.take(paging_options.page_size)
  end

  @doc false
  def address_to_transactions_tasks_range_of_blocks(address_hash, options) do
    extremums_list =
      address_hash
      |> transactions_block_numbers_at_address(options)
      |> Enum.map(fn query ->
        extremum_query =
          from(
            q in subquery(query),
            select: %{min_block_number: min(q.block_number), max_block_number: max(q.block_number)}
          )

        extremum_query
        |> Repo.one!()
      end)

    extremums_list
    |> Enum.reduce(%{min_block_number: nil, max_block_number: 0}, fn %{
                                                                       min_block_number: min_number,
                                                                       max_block_number: max_number
                                                                     },
                                                                     extremums_result ->
      current_min_number = Map.get(extremums_result, :min_block_number)
      current_max_number = Map.get(extremums_result, :max_block_number)

      extremums_result
      |> process_extremums_result_against_min_number(current_min_number, min_number)
      |> process_extremums_result_against_max_number(current_max_number, max_number)
    end)
  end

  defp transactions_block_numbers_at_address(address_hash, options) do
    direction = Keyword.get(options, :direction)

    options
    |> address_to_transactions_tasks_query(true)
    |> not_pending_transactions()
    |> select([t], t.block_number)
    |> matching_address_queries_list(direction, address_hash)
  end

  defp process_extremums_result_against_min_number(extremums_result, current_min_number, min_number)
       when is_number(current_min_number) and
              not (is_number(min_number) and min_number > 0 and min_number < current_min_number) do
    extremums_result
  end

  defp process_extremums_result_against_min_number(extremums_result, _current_min_number, min_number) do
    extremums_result
    |> Map.put(:min_block_number, min_number)
  end

  defp process_extremums_result_against_max_number(extremums_result, current_max_number, max_number)
       when is_number(max_number) and max_number > 0 and max_number > current_max_number do
    extremums_result
    |> Map.put(:max_block_number, max_number)
  end

  defp process_extremums_result_against_max_number(extremums_result, _current_max_number, _max_number) do
    extremums_result
  end

  defp process_item(item) do
    block_number = if item.block_number, do: -item.block_number, else: 0
    index = if item.index, do: -item.index, else: 0
    {block_number, index}
  end

  @spec address_to_transactions_without_rewards(
          Hash.Address.t(),
          [
            Chain.paging_options()
            | Chain.necessity_by_association_option()
            | {:sorting, SortingHelper.sorting_params()}
          ],
          boolean()
        ) :: [__MODULE__.t()]
  def address_to_transactions_without_rewards(address_hash, options, old_ui? \\ true) do
    paging_options = Keyword.get(options, :paging_options, Chain.default_paging_options())

    address_hash
    |> address_to_transactions_tasks(options, old_ui?)
    |> wait_for_address_transactions()
    |> Enum.sort(compare_custom_sorting(Keyword.get(options, :sorting, [])))
    |> Enum.dedup_by(& &1.hash)
    |> Enum.take(paging_options.page_size)
  end

  defp address_to_transactions_tasks(address_hash, options, old_ui?) do
    direction = Keyword.get(options, :direction)
    necessity_by_association = Keyword.get(options, :necessity_by_association, %{})
    old_ui? = old_ui? || is_tuple(Keyword.get(options, :paging_options, Chain.default_paging_options()).key)

    options
    |> address_to_transactions_tasks_query(false, old_ui?)
    |> not_dropped_or_replaced_transactions()
    |> Chain.join_associations(necessity_by_association)
    |> put_has_token_transfers_to_tx(old_ui?)
    |> matching_address_queries_list(direction, address_hash)
    |> Enum.map(fn query -> Task.async(fn -> Chain.select_repo(options).all(query) end) end)
  end

  @doc """
  Returns the address to transactions tasks query based on provided options.
  Boolean `only_mined?` argument specifies if only mined transactions should be returned,
  boolean `old_ui?` argument specifies if the query is for the old UI, i.e. is query dynamically sorted or no.
  """
  @spec address_to_transactions_tasks_query(keyword, boolean, boolean) :: Ecto.Query.t()
  def address_to_transactions_tasks_query(options, only_mined? \\ false, old_ui? \\ true)

  def address_to_transactions_tasks_query(options, only_mined?, true) do
    from_block = Chain.from_block(options)
    to_block = Chain.to_block(options)

    options
    |> Keyword.get(:paging_options, Chain.default_paging_options())
    |> fetch_transactions(from_block, to_block, !only_mined?)
  end

  def address_to_transactions_tasks_query(options, _only_mined?, false) do
    from_block = Chain.from_block(options)
    to_block = Chain.to_block(options)
    paging_options = Keyword.get(options, :paging_options, Chain.default_paging_options())
    sorting_options = Keyword.get(options, :sorting, [])

    fetch_transactions_with_custom_sorting(paging_options, from_block, to_block, sorting_options)
  end

  @doc """
  Waits for the address transactions tasks to complete and returns the transactions flattened
  in case of success or raises an error otherwise.
  """
  @spec wait_for_address_transactions([Task.t()]) :: [__MODULE__.t()]
  def wait_for_address_transactions(tasks) do
    tasks
    |> Task.yield_many(:timer.seconds(20))
    |> Enum.flat_map(fn {_task, res} ->
      case res do
        {:ok, result} ->
          result

        {:exit, reason} ->
          raise "Query fetching address transactions terminated: #{inspect(reason)}"

        nil ->
          raise "Query fetching address transactions timed out."
      end
    end)
  end

  defp compare_custom_sorting([{order, :value}]) do
    fn a, b ->
      case Decimal.compare(Wei.to(a.value, :wei), Wei.to(b.value, :wei)) do
        :eq -> compare_default_sorting(a, b)
        :gt -> order == :desc
        :lt -> order == :asc
      end
    end
  end

  defp compare_custom_sorting([{:dynamic, :fee, order, _dynamic_fee}]) do
    fn a, b ->
      nil_case =
        case order do
          :desc_nulls_last -> Decimal.new("-inf")
          :asc_nulls_first -> Decimal.new("inf")
        end

      a_fee = a |> Chain.fee(:wei) |> elem(1) || nil_case
      b_fee = b |> Chain.fee(:wei) |> elem(1) || nil_case

      case Decimal.compare(a_fee, b_fee) do
        :eq -> compare_default_sorting(a, b)
        :gt -> order == :desc_nulls_last
        :lt -> order == :asc_nulls_first
      end
    end
  end

  defp compare_custom_sorting([]), do: &compare_default_sorting/2

  defp compare_default_sorting(a, b) do
    case {
      compare(a.block_number, b.block_number),
      compare(a.index, b.index),
      DateTime.compare(a.inserted_at, b.inserted_at),
      compare(Hash.to_integer(a.hash), Hash.to_integer(b.hash))
    } do
      {:lt, _, _, _} -> false
      {:eq, :lt, _, _} -> false
      {:eq, :eq, :lt, _} -> false
      {:eq, :eq, :eq, :gt} -> false
      _ -> true
    end
  end

  defp compare(a, b) do
    cond do
      a < b -> :lt
      a > b -> :gt
      true -> :eq
    end
  end

  @doc """
  Creates a query to fetch transactions taking into account paging_options (possibly nil),
  from_block (may be nil), to_block (may be nil) and boolean `with_pending?` that indicates if pending transactions should be included
  into the query.
  """
  @spec fetch_transactions(PagingOptions.t() | nil, non_neg_integer | nil, non_neg_integer | nil, boolean()) ::
          Ecto.Query.t()
  def fetch_transactions(paging_options \\ nil, from_block \\ nil, to_block \\ nil, with_pending? \\ false) do
    __MODULE__
    |> order_for_transactions(with_pending?)
    |> Chain.where_block_number_in_period(from_block, to_block)
    |> handle_paging_options(paging_options)
  end

  @default_sorting [
    desc: :block_number,
    desc: :index,
    desc: :inserted_at,
    asc: :hash
  ]

  @doc """
  Creates a query to fetch transactions taking into account paging_options (possibly nil),
  from_block (may be nil), to_block (may be nil) and sorting_params.
  """
  @spec fetch_transactions_with_custom_sorting(
          PagingOptions.t() | nil,
          non_neg_integer | nil,
          non_neg_integer | nil,
          SortingHelper.sorting_params()
        ) :: Ecto.Query.t()
  def fetch_transactions_with_custom_sorting(paging_options, from_block, to_block, sorting) do
    query = from(transaction in __MODULE__)

    query
    |> Chain.where_block_number_in_period(from_block, to_block)
    |> SortingHelper.apply_sorting(sorting, @default_sorting)
    |> SortingHelper.page_with_sorting(paging_options, sorting, @default_sorting)
  end

  defp order_for_transactions(query, true) do
    query
    |> order_by([transaction],
      desc: transaction.block_number,
      desc: transaction.index,
      desc: transaction.inserted_at,
      asc: transaction.hash
    )
  end

  defp order_for_transactions(query, _) do
    query
    |> order_by([transaction], desc: transaction.block_number, desc: transaction.index)
  end

  @doc """
  Updates the provided query with necessary `where`s and `limit`s to take into account paging_options (may be nil).
  """
  @spec handle_paging_options(Ecto.Query.t() | atom, nil | Explorer.PagingOptions.t()) :: Ecto.Query.t()
  def handle_paging_options(query, nil), do: query

  def handle_paging_options(query, %PagingOptions{key: nil, page_size: nil}), do: query

  def handle_paging_options(query, paging_options) do
    query
    |> page_transaction(paging_options)
    |> limit(^paging_options.page_size)
  end

  @doc """
  Updates the provided query with necessary `where`s to take into account paging_options.
  """
  @spec page_transaction(Ecto.Query.t() | atom, Explorer.PagingOptions.t()) :: Ecto.Query.t()
  def page_transaction(query, %PagingOptions{key: nil}), do: query

  def page_transaction(query, %PagingOptions{is_pending_tx: true} = options),
    do: page_pending_transaction(query, options)

  def page_transaction(query, %PagingOptions{key: {block_number, index}, is_index_in_asc_order: true}) do
    where(
      query,
      [transaction],
      transaction.block_number < ^block_number or
        (transaction.block_number == ^block_number and transaction.index > ^index)
    )
  end

  def page_transaction(query, %PagingOptions{key: {block_number, index}}) do
    where(
      query,
      [transaction],
      transaction.block_number < ^block_number or
        (transaction.block_number == ^block_number and transaction.index < ^index)
    )
  end

  def page_transaction(query, %PagingOptions{key: {index}}) do
    where(query, [transaction], transaction.index < ^index)
  end

  @doc """
  Updates the provided query with necessary `where`s to take into account paging_options.
  """
  @spec page_pending_transaction(Ecto.Query.t() | atom, Explorer.PagingOptions.t()) :: Ecto.Query.t()
  def page_pending_transaction(query, %PagingOptions{key: nil}), do: query

  def page_pending_transaction(query, %PagingOptions{key: {inserted_at, hash}}) do
    where(
      query,
      [transaction],
      (is_nil(transaction.block_number) and
         (transaction.inserted_at < ^inserted_at or
            (transaction.inserted_at == ^inserted_at and transaction.hash > ^hash))) or
        not is_nil(transaction.block_number)
    )
  end

  @doc """
  Adds a `has_token_transfers` field to the query via `select_merge` if second argument is `false` and returns
  the query untouched otherwise.
  """
  @spec put_has_token_transfers_to_tx(Ecto.Query.t() | atom, boolean) :: Ecto.Query.t()
  def put_has_token_transfers_to_tx(query, true), do: query

  def put_has_token_transfers_to_tx(query, false) do
    from(tx in query,
      select_merge: %{
        has_token_transfers:
          fragment(
            "(SELECT transaction_hash FROM token_transfers WHERE transaction_hash = ? LIMIT 1) IS NOT NULL",
            tx.hash
          )
      }
    )
  end

  @doc """
  Return the dynamic that calculates the fee for transactions.
  """
  @spec dynamic_fee :: Ecto.Query.dynamic_expr()
  def dynamic_fee do
    dynamic([tx], tx.gas_price * fragment("COALESCE(?, ?)", tx.gas_used, tx.gas))
  end

  @doc """
  Returns next page params based on the provided transaction.
  """
  @spec address_transactions_next_page_params(Explorer.Chain.Transaction.t()) :: %{
          required(String.t()) => Decimal.t() | Wei.t() | non_neg_integer | DateTime.t() | Hash.t()
        }
  def address_transactions_next_page_params(
        %__MODULE__{block_number: block_number, index: index, inserted_at: inserted_at, hash: hash, value: value} = tx
      ) do
    %{
      "fee" => tx |> Chain.fee(:wei) |> elem(1),
      "value" => value,
      "block_number" => block_number,
      "index" => index,
      "inserted_at" => inserted_at,
      "hash" => hash
    }
  end

  @suave_bid_event "0x83481d5b04dea534715acad673a8177a46fc93882760f36bdc16ccac439d504e"

  @spec suave_parse_allowed_peekers(Ecto.Schema.has_many(Log.t())) :: [String.t()]
  def suave_parse_allowed_peekers(%NotLoaded{}), do: []

  def suave_parse_allowed_peekers(logs) do
    suave_bid_contracts =
      Application.get_all_env(:explorer)[Transaction][:suave_bid_contracts]
      |> String.split(",")
      |> Enum.map(fn sbc -> String.downcase(String.trim(sbc)) end)

    bid_event =
      Enum.find(logs, fn log ->
        sanitize_log_first_topic(log.first_topic) == @suave_bid_event &&
          Enum.member?(suave_bid_contracts, String.downcase(Hash.to_string(log.address_hash)))
      end)

    if is_nil(bid_event) do
      []
    else
      [_bid_id, _decryption_condition, allowed_peekers] =
        Helper.decode_data(bid_event.data, [{:bytes, 16}, {:uint, 64}, {:array, :address}])

      Enum.map(allowed_peekers, fn peeker ->
        "0x" <> Base.encode16(peeker, case: :lower)
      end)
    end
  end

  defp sanitize_log_first_topic(first_topic) do
    if is_nil(first_topic) do
      ""
    else
      sanitized =
        if is_binary(first_topic) do
          first_topic
        else
          Hash.to_string(first_topic)
        end

      String.downcase(sanitized)
    end
  end
end
