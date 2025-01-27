defmodule Signet.RPC do
  @moduledoc """
  Excessively simple RPC client for Ethereum.
  """
  import Signet.Util, only: [to_wei: 1]

  defp ethereum_node(), do: Signet.Application.ethereum_node()
  defp http_client(), do: Signet.Application.http_client()

  @default_gas_price nil
  @default_base_fee nil
  @default_base_fee_buffer 1.20
  @default_priority_fee {0, :gwei}
  @default_gas_buffer 1.50

  defp headers(extra_headers) do
    [
      {"Accept", "application/json"},
      {"Content-Type", "application/json"}
    ] ++ extra_headers
  end

  defp get_body(method, params) do
    id = System.unique_integer([:positive])

    %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => id
    }
  end

  # See https://blog.soliditylang.org/2021/04/21/custom-errors/
  defp decode_error(<<error_hash::binary-size(4), error_data::binary()>>, errors) do
    all_errors = ["Panic(uint256)" | errors]

    case Enum.find(all_errors, fn error ->
           <<prefix::binary-size(4), _::binary()>> = Signet.Hash.keccak(error)
           prefix == error_hash
         end) do
      nil ->
        :not_found

      error_abi ->
        params = ABI.decode(error_abi, error_data)

        # From https://blog.soliditylang.org/2020/10/28/solidity-0.8.x-preview/
        case {error_abi, params} do
          {"Panic(uint256)", [0x01]} ->
            {:ok, "assertion failure", nil}

          {"Panic(uint256)", [0x11]} ->
            {:ok, "arithmetic error: overflow or underflow", nil}

          {"Panic(uint256)", [0x12]} ->
            {:ok, "failed to convert value to enum", nil}

          {"Panic(uint256)", [0x21]} ->
            {:ok, "popped from empty array", nil}

          {"Panic(uint256)", [0x32]} ->
            {:ok, "out-of-bounds array access", nil}

          {"Panic(uint256)", [0x41]} ->
            {:ok, "out of memory", nil}

          {"Panic(uint256)", [0x51]} ->
            {:ok, "called a zero-initialized variable of internal function type", nil}

          _ ->
            {:ok, error_abi, params}
        end
    end
  end

  defp decode_response(response, id, errors) do
    with {:ok, %{"jsonrpc" => "2.0", "result" => result, "id" => ^id}} <- Jason.decode(response) do
      {:ok, result}
    else
      {:ok,
       %{
         "jsonrpc" => "2.0",
         "error" => %{
           "code" => code,
           "data" => data_hex,
           "message" => message
         },
         "id" => ^id
       }} ->
        with {:ok, data} <- Signet.Util.decode_hex(data_hex),
             {:ok, error_abi, error_params} <- decode_error(data, errors) do
          # TODO: Try to clean up how this is shown, just a little.
          if is_nil(error_params) do
            {:error, "error #{code}: #{message} (#{error_abi})"}
          else
            {:error, "error #{code}: #{message} (#{error_abi}#{inspect(error_params)})"}
          end
        else
          _ ->
            {:error, "error #{code}: #{message} (#{data_hex})"}
        end

      {:ok,
       %{
         "jsonrpc" => "2.0",
         "error" => %{
           "code" => code,
           "message" => message
         },
         "id" => ^id
       }} ->
        {:error, "error #{code}: #{message}"}

      {:error, error} ->
        {:error, error}

      _ ->
        {:error, "invalid JSON-RPC response"}
    end
  end

  @doc """
  Simple RPC client for a JSON-RPC Ethereum node.

  ## Examples

      iex> Signet.RPC.send_rpc("net_version", [])
      {:ok, "3"}

      iex> Signet.RPC.send_rpc("get_balance", ["0x407d73d8a49eeb85d32cf465507dd71d507100c1", "latest"], ethereum_node: "http://example.com")
      {:ok, "0x0234c8a3397aab58"}
  """
  def send_rpc(method, params, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])
    decode = Keyword.get(opts, :decode, nil)
    errors = Keyword.get(opts, :errors, nil)
    timeout = Keyword.get(opts, :timeout, 30_000)
    url = Keyword.get(opts, :ethereum_node, ethereum_node())
    body = get_body(method, params)

    case http_client().post(url, Jason.encode!(body), headers(headers), recv_timeout: timeout) do
      {:ok, %HTTPoison.Response{status_code: code, body: resp_body}} when code in 200..299 ->
        with {:ok, result} <- decode_response(resp_body, body["id"], errors) do
          case decode do
            nil ->
              {:ok, result}

            :hex ->
              Signet.Util.decode_hex(result)

            :hex_unsigned ->
              with {:ok, bin} <- Signet.Util.decode_hex(result) do
                {:ok, :binary.decode_unsigned(bin)}
              end
          end
        end

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "error: #{inspect(reason)}"}
    end
  end

  @doc """
  RPC call to get account nonce.

  ## Examples

      iex> Signet.RPC.get_nonce(Signet.Util.decode_hex!("0x407d73d8a49eeb85d32cf465507dd71d507100c1"))
      {:ok, 4}
  """
  def get_nonce(account, opts \\ []) do
    block_number = Keyword.get(opts, :block_number, "latest")

    send_rpc(
      "eth_getTransactionCount",
      [Signet.Util.encode_hex(account), block_number],
      Keyword.merge(opts, decode: :hex_unsigned)
    )
  end

  @doc """
  RPC call to send a raw transaction.

  ## Examples

      iex> signer_proc = Signet.Test.Signer.start_signer()
      iex> {:ok, signed_trx} = Signet.Transaction.build_signed_trx(<<1::160>>, 5, {"baz(uint,address)", [50, :binary.decode_unsigned(<<1::160>>)]}, {50, :gwei}, 100_000, 0, chain_id: :goerli, signer: signer_proc)
      iex> {:ok, trx_id} = Signet.RPC.send_trx(signed_trx)
      iex> <<nonce::integer-size(8), gas_price::integer-size(64), gas_limit::integer-size(24), to::binary>> = trx_id
      iex> {nonce, gas_price, gas_limit, to}
      {5, 50000000000, 100000, <<1::160>>}
  """
  def send_trx(trx = %Signet.Transaction.V1{}, opts \\ []) do
    send_rpc(
      "eth_sendRawTransaction",
      [Signet.Util.encode_hex(Signet.Transaction.V1.encode(trx))],
      Keyword.merge(opts, decode: :hex)
    )
  end

  @doc ~S"""
  RPC call to call a transaction and preview results.

  ## Examples

      iex> Signet.Transaction.V1.new(1, {100, :gwei}, 100_000, <<1::160>>, {2, :wei}, <<1, 2, 3>>)
      iex> |> Signet.RPC.call_trx()
      {:ok, <<0x0c>>}

      iex> Signet.Transaction.V1.new(1, {100, :gwei}, 100_000, <<1::160>>, {2, :wei}, <<1, 2, 3>>)
      iex> |> Signet.RPC.call_trx(decode: :hex_unsigned)
      {:ok, 0x0c}

      iex> Signet.Transaction.V1.new(1, {100, :gwei}, 100_000, <<10::160>>, {2, :wei}, <<1, 2, 3>>)
      iex> |> Signet.RPC.call_trx()
      {:error, "error 3: execution reverted (0x3d738b2e)"}

      iex> errors = ["Unauthorized()", "BadNonce()", "NotEnoughSigners()", "NotActiveWithdrawalAddress()", "NotActiveOperator()", "DuplicateSigners()"]
      iex> Signet.Transaction.V1.new(1, {100, :gwei}, 100_000, <<10::160>>, {2, :wei}, <<1, 2, 3>>)
      iex> |> Signet.RPC.call_trx(errors: errors)
      {:error, "error 3: execution reverted (NotActiveOperator()[])"}

      iex> errors = ["Cool(uint256,string)"]
      iex> Signet.Transaction.V1.new(1, {100, :gwei}, 100_000, <<11::160>>, {2, :wei}, <<1, 2, 3>>)
      iex> |> Signet.RPC.call_trx(errors: errors)
      {:error, "error 3: execution reverted (Cool(uint256,string)[1, \"cat\"])"}
  """
  def call_trx(trx = %Signet.Transaction.V1{}, opts \\ []) do
    from = Keyword.get(opts, :from)
    block_number = Keyword.get(opts, :block_number, "latest")
    errors = Keyword.get(opts, :errors, [])

    send_rpc(
      "eth_call",
      [
        %{
          from: if(is_nil(from), do: nil, else: Signet.Util.encode_hex(from)),
          to: Signet.Util.encode_hex(trx.to),
          gas: Signet.Util.encode_hex(trx.gas_limit, true),
          gasPrice: Signet.Util.encode_hex(trx.gas_price, true),
          value: Signet.Util.encode_hex(trx.value, true),
          data: Signet.Util.encode_hex(trx.data, true)
        },
        block_number
      ],
      opts
      |> Keyword.put_new(:decode, :hex)
      |> Keyword.put_new(:errors, errors)
    )
  end

  @doc """
  RPC call to call to estimate gas used by a given call.

  ## Examples

      iex> Signet.Transaction.V1.new(1, {100, :gwei}, 100_000, <<1::160>>, {2, :wei}, <<1, 2, 3>>)
      iex> |> Signet.RPC.estimate_gas()
      {:ok, 0x0d}
  """
  def estimate_gas(trx = %Signet.Transaction.V1{}, opts \\ []) do
    from = Keyword.get(opts, :from)
    block_number = Keyword.get(opts, :block_number, "latest")

    send_rpc(
      "eth_estimateGas",
      [
        %{
          from: if(is_nil(from), do: nil, else: Signet.Util.encode_hex(from)),
          to: Signet.Util.encode_hex(trx.to),
          gasPrice: Signet.Util.encode_hex(trx.gas_price, true),
          value: Signet.Util.encode_hex(trx.value, true),
          data: Signet.Util.encode_hex(trx.data, true)
        },
        block_number
      ],
      Keyword.merge(opts, decode: :hex_unsigned)
    )
  end

  @doc """
  RPC call to call to get the current gas price.

  ## Examples

      iex> Signet.RPC.gas_price()
      {:ok, 1000000000}
  """
  def gas_price(opts \\ []) do
    send_rpc(
      "eth_gasPrice",
      [],
      Keyword.merge(opts, decode: :hex_unsigned)
    )
  end

  @doc """
  Helper function to work with other Signet modules to get a nonce, sign a transction, and transmit it to the network.

  If you need higher-level functionality, like manual nonce tracking, you may want to use the more granular function calls.

  Options:
    * `gas_price` - Set the base gas for the transaction, overrides all other gas prices listed below (default `nil`)
    * `base_fee` - Set the base price for the transaction, if nil, will use base gas price from `eth_gasPrice` call (default `nil`)
    * `base_fee_buffer` - Buffer for the gas price when estimating gas (default: 1.2 = 120%)
    * `priority_fee` - Additional gas to send as a priority fee. (default: `{0, :gwei}`)
    * `gas_limit` - Set the gas limit for the transaction (default: calls `eth_estimateGas`)
    * `gas_buffer` - Buffer if estimating gas limit (default: 1.5 = 150%)
    * `value` - Value to provide with transaction in wei (default: 0)
    * `nonce` - Nonce to send with transaction. (default: lookup via `eth_transactionCount`)
    * `verify` - Verify the function is likely to succeed before submitting (default: true)

    Note: if we don't `verify`, then `estimateGas` will likely fail if the transaction were to fail.
          To prevent this, `gas_limit` should always be supplied when `verify` is set to false.

    Note: Currently Signet uses pre-EIP-1559 signatures and thus gas prices are not broken out by
          base fee and priority fee.

  ## Examples

      iex> signer_proc = Signet.Test.Signer.start_signer()
      iex> {:ok, trx_id} = Signet.RPC.execute_trx(<<1::160>>, {"baz(uint,address)", [50, :binary.decode_unsigned(<<1::160>>)]}, gas_price: {50, :gwei}, value: 0, signer: signer_proc)
      iex> <<nonce::integer-size(8), gas_price::integer-size(64), gas_limit::integer-size(24), to::binary>> = trx_id
      iex> {nonce, gas_price, gas_limit, to}
      {4, 50000000000, 20, <<1::160>>}

      iex> signer_proc = Signet.Test.Signer.start_signer()
      iex> {:ok, trx_id} = Signet.RPC.execute_trx(<<1::160>>, {"baz(uint,address)", [50, <<1::160>> |> :binary.decode_unsigned]}, gas_price: {50, :gwei}, gas_limit: 100_000, value: 0, signer: signer_proc)
      iex> <<nonce::integer-size(8), gas_price::integer-size(64), gas_limit::integer-size(24), to::binary>> = trx_id
      iex> {nonce, gas_price, gas_limit, to}
      {4, 50000000000, 100000, <<1::160>>}

      iex> signer_proc = Signet.Test.Signer.start_signer()
      iex> {:ok, trx_id} = Signet.RPC.execute_trx(<<1::160>>, {"baz(uint,address)", [50, <<1::160>> |> :binary.decode_unsigned]}, gas_price: {50, :gwei}, gas_limit: 100_000, value: 0, nonce: 10, signer: signer_proc)
      iex> <<nonce::integer-size(8), gas_price::integer-size(64), gas_limit::integer-size(24), to::binary>> = trx_id
      iex> {nonce, gas_price, gas_limit, to}
      {10, 50000000000, 100000, <<1::160>>}

      iex> signer_proc = Signet.Test.Signer.start_signer()
      iex> Signet.RPC.execute_trx(<<10::160>>, {"baz(uint,address)", [50, <<1::160>> |> :binary.decode_unsigned]}, gas_price: {50, :gwei}, gas_limit: 100_000, value: 0, nonce: 10, signer: signer_proc)
      {:error, "error 3: execution reverted (0x3d738b2e)"}

      iex> # Set gas price directly
      iex> signer_proc = Signet.Test.Signer.start_signer()
      iex> {:ok, trx_id} = Signet.RPC.execute_trx(<<10::160>>, {"baz(uint,address)", [50, <<1::160>> |> :binary.decode_unsigned]}, gas_price: {50, :gwei}, gas_limit: 100_000, value: 0, nonce: 10, verify: false, signer: signer_proc)
      iex> <<nonce::integer-size(8), gas_price::integer-size(64), gas_limit::integer-size(24), to::binary>> = trx_id
      iex> {nonce, gas_price, gas_limit, to}
      {10, 50000000000, 100000, <<10::160>>}

      iex> # Default gas price
      iex> signer_proc = Signet.Test.Signer.start_signer()
      iex> {:ok, trx_id} = Signet.RPC.execute_trx(<<10::160>>, {"baz(uint,address)", [50, <<1::160>> |> :binary.decode_unsigned]}, gas_limit: 100_000, value: 0, nonce: 10, verify: false, signer: signer_proc)
      iex> <<nonce::integer-size(8), gas_price::integer-size(64), gas_limit::integer-size(24), to::binary>> = trx_id
      iex> {nonce, gas_price, gas_limit, to}
      {10, 1200000000, 100000, <<10::160>>}

      iex> # Set priority fee
      iex> signer_proc = Signet.Test.Signer.start_signer()
      iex> {:ok, trx_id} = Signet.RPC.execute_trx(<<10::160>>, {"baz(uint,address)", [50, <<1::160>> |> :binary.decode_unsigned]}, priority_fee: {3, :gwei}, gas_limit: 100_000, value: 0, nonce: 10, verify: false, signer: signer_proc)
      iex> <<nonce::integer-size(8), gas_price::integer-size(64), gas_limit::integer-size(24), to::binary>> = trx_id
      iex> {nonce, gas_price, gas_limit, to}
      {10, 4200000000, 100000, <<10::160>>}

      iex> # Set base fee and priority fee
      iex> signer_proc = Signet.Test.Signer.start_signer()
      iex> {:ok, trx_id} = Signet.RPC.execute_trx(<<10::160>>, {"baz(uint,address)", [50, <<1::160>> |> :binary.decode_unsigned]}, base_fee: {1, :gwei}, priority_fee: {3, :gwei}, gas_limit: 100_000, value: 0, nonce: 10, verify: false, signer: signer_proc)
      iex> <<nonce::integer-size(8), gas_price::integer-size(64), gas_limit::integer-size(24), to::binary>> = trx_id
      iex> {nonce, gas_price, gas_limit, to}
      {10, 4000000000, 100000, <<10::160>>}
  """
  def execute_trx(contract, call_data, opts \\ []) do
    {gas_price_user, opts} = Keyword.pop(opts, :gas_price, @default_gas_price)
    {base_fee_user, opts} = Keyword.pop(opts, :base_fee, @default_base_fee)
    {base_fee_buffer, opts} = Keyword.pop(opts, :base_fee_buffer, @default_base_fee_buffer)
    {priority_fee, opts} = Keyword.pop(opts, :priority_fee, @default_priority_fee)
    {gas_limit, opts} = Keyword.pop(opts, :gas_limit)
    {gas_buffer, opts} = Keyword.pop(opts, :gas_buffer, @default_gas_buffer)
    {value, opts} = Keyword.pop(opts, :value, 0)
    {nonce, opts} = Keyword.pop(opts, :nonce)
    {verify, opts} = Keyword.pop(opts, :verify, true)
    {signer, opts} = Keyword.pop(opts, :signer, Signet.Signer.Default)

    signer_address = Signet.Signer.address(signer)
    chain_id = Signet.Signer.chain_id(signer)
    opts = Keyword.put_new(opts, :from, signer_address)

    gas_price_result =
      case gas_price_user do
        nil ->
          # Base Price + Priority Fee
          base_fee_result =
            case base_fee_user do
              nil ->
                # Estimate base price
                with {:ok, base_fee_est} <- gas_price(opts) do
                  {:ok, ceil(base_fee_est * base_fee_buffer)}
                end

              val ->
                # User-specified base price
                {:ok, to_wei(val)}
            end

          # Add in Priority fee
          with {:ok, base_fee} <- base_fee_result do
            {:ok, base_fee + to_wei(priority_fee)}
          end

        els ->
          # User-specified total gas price
          {:ok, to_wei(els)}
      end

    estimate_and_verify = fn trx ->
      with {:ok, _} <- if(verify, do: call_trx(trx, opts), else: {:ok, nil}),
           {:ok, gas_limit} <-
             (case gas_limit do
                nil ->
                  with {:ok, limit} <- estimate_gas(trx, opts) do
                    {:ok, ceil(limit * gas_buffer)}
                  end

                els ->
                  {:ok, els}
              end) do
        {:ok, %{trx | gas_limit: gas_limit}}
      end
    end

    with {:ok, gas_price} <- gas_price_result,
         {:ok, nonce} <-
           if(!is_nil(nonce), do: {:ok, nonce}, else: get_nonce(signer_address, opts)),
         {:ok, trx} <-
           Signet.Transaction.build_signed_trx(
             contract,
             nonce,
             call_data,
             gas_price,
             gas_limit,
             value,
             signer: signer,
             chain_id: chain_id,
             callback: estimate_and_verify
           ),
         {:ok, tx_id} <- send_trx(trx, opts) do
      {:ok, tx_id}
    end
  end
end
