defmodule KafkaEx.ServerKayrock do
  @moduledoc """
  Kayrock-compatible KafkaEx.Server implementation

  This implementation attemps to keep as much Kafka 'business logic' as possible
  out of the server implementation, with the motivation that this should make
  the client easier to maintain as the Kafka protocol evolves.

  This implementation does, however, include implementations of all of the
  legacy KafkaEx.Server `handle_call` clauses so that it can be compatible with
  the legacy KafkaEx API.
  """

  alias KafkaEx.NetworkClient

  alias KafkaEx.New.Adapter
  alias KafkaEx.New.Broker
  alias KafkaEx.New.ClusterMetadata

  alias KafkaEx.ServerKayrock.State

  use GenServer

  @doc """
  Start the server in a supervision tree
  """
  @spec start_link(KafkaEx.worker_init(), atom) :: GenServer.on_start()
  def start_link(args, name \\ __MODULE__)

  def start_link(args, :no_name) do
    GenServer.start_link(__MODULE__, [args, nil])
  end

  def start_link(args, name) do
    GenServer.start_link(__MODULE__, [args, name], name: name)
  end

  @doc """
  Make a
  """
  @spec kayrock_call(
          KafkaEx.New.KafkaExAPI.client(),
          map,
          KafkaEx.New.ClusterMetadata.node_selector(),
          pos_integer | nil
        ) :: {:ok, term} | {:error, term}
  def kayrock_call(
        server,
        request,
        node_selector,
        timeout \\ nil
      ) do
    GenServer.call(
      server,
      {:kayrock_request, request, node_selector},
      timeout_val(timeout)
    )
  end

  require Logger
  alias KafkaEx.NetworkClient

  # Default from GenServer
  @default_call_timeout 5_000
  @client_id "kafka_ex"
  @retry_count 3
  @metadata_update_interval 30_000
  @consumer_group_update_interval 30_000
  @sync_timeout 1_000

  @impl true
  def init([args, name]) do
    name = name || self()
    uris = Keyword.get(args, :uris, [])

    metadata_update_interval =
      Keyword.get(args, :metadata_update_interval, @metadata_update_interval)

    consumer_group_update_interval =
      Keyword.get(
        args,
        :consumer_group_update_interval,
        @consumer_group_update_interval
      )

    allow_auto_topic_creation =
      Keyword.get(args, :allow_auto_topic_creation, true)

    use_ssl = Keyword.get(args, :use_ssl, false)
    ssl_options = Keyword.get(args, :ssl_options, [])

    brokers =
      Enum.into(Enum.with_index(uris), %{}, fn {{host, port}, ix} ->
        {ix + 1,
         %Broker{
           host: host,
           port: port,
           socket: NetworkClient.create_socket(host, port, ssl_options, use_ssl)
         }}
      end)

    check_brokers_sockets!(brokers)

    consumer_group = Keyword.get(args, :consumer_group)

    unless KafkaEx.valid_consumer_group?(consumer_group) do
      raise KafkaEx.InvalidConsumerGroupError, consumer_group
    end

    state = %State{
      metadata_update_interval: metadata_update_interval,
      consumer_group_update_interval: consumer_group_update_interval,
      consumer_group_for_auto_commit: consumer_group,
      worker_name: name,
      ssl_options: ssl_options,
      use_ssl: use_ssl,
      api_versions: %{},
      cluster_metadata: %ClusterMetadata{brokers: brokers},
      allow_auto_topic_creation: allow_auto_topic_creation
    }

    {ok_or_err, api_versions, state} = get_api_versions(state)

    if ok_or_err == :error do
      sleep_for_reconnect()
      raise "Brokers sockets are closed"
    end

    :no_error = Kayrock.ErrorCode.code_to_atom(api_versions.error_code)

    state = State.ingest_api_versions(state, api_versions)

    state =
      try do
        update_metadata(state)
      rescue
        e ->
          sleep_for_reconnect()
          Kernel.reraise(e, System.stacktrace())
      end

    {:ok, _} =
      :timer.send_interval(state.metadata_update_interval, :update_metadata)

    {:ok, state}
  end

  @impl true
  def handle_call(:cluster_metadata, _from, state) do
    {:reply, {:ok, state.cluster_metadata}, state}
  end

  def handle_call(:correlation_id, _from, state) do
    {:reply, {:ok, state.correlation_id}, state}
  end

  def handle_call(:update_metadata, _from, state) do
    updated_state = update_metadata(state)
    {:reply, {:ok, updated_state.cluster_metadata}, updated_state}
  end

  def handle_call(
        {:set_consumer_group_for_auto_commit, consumer_group},
        _from,
        state
      ) do
    if KafkaEx.valid_consumer_group?(consumer_group) do
      {:reply, :ok, %{state | consumer_group_for_auto_commit: consumer_group}}
    else
      {:reply, {:error, :invalid_consumer_group}, state}
    end
  end

  def handle_call({:topic_metadata, topics, allow_topic_creation}, _from, state) do
    allow_auto_topic_creation = state.allow_auto_topic_creation

    updated_state =
      update_metadata(
        %{state | allow_auto_topic_creation: allow_topic_creation},
        topics
      )

    topic_metadata = State.topics_metadata(updated_state, topics)

    {:reply, {:ok, topic_metadata},
     %{updated_state | allow_auto_topic_creation: allow_auto_topic_creation}}
  end

  def handle_call({:offset, topic, partition, time}, _from, state) do
    request = Adapter.list_offsets_request(topic, partition, time)

    {response, updated_state} =
      kayrock_network_request(
        request,
        {:topic_partition, topic, partition},
        state
      )

    adapted_response =
      case response do
        {:ok, api_response} ->
          Adapter.list_offsets_response(api_response)

        other ->
          other
      end

    {:reply, adapted_response, updated_state}
  end

  def handle_call({:produce, produce_request}, _from, state) do
    produce_request =
      default_partitioner().assign_partition(
        produce_request,
        Adapter.metadata_response(state.cluster_metadata)
      )

    {request, topic, partition} = Adapter.produce_request(produce_request)

    {response, updated_state} =
      kayrock_network_request(
        request,
        {:topic_partition, topic, partition},
        state
      )

    response =
      case response do
        {:ok, :ok} -> {:ok, :ok}
        {:ok, val} -> {:ok, Adapter.produce_response(val)}
        _ -> response
      end

    {:reply, response, updated_state}
  end

  def handle_call({:kayrock_request, request, node_selector}, _from, state) do
    {response, updated_state} =
      kayrock_network_request(request, node_selector, state)

    {:reply, response, updated_state}
  end

  def handle_call({:metadata, topic}, _from, state) do
    updated_state = update_metadata(state, [topic])

    {:reply, Adapter.metadata_response(updated_state.cluster_metadata),
     updated_state}
  end

  def handle_call({:fetch, fetch_request}, _from, state) do
    allow_auto_topic_creation = state.allow_auto_topic_creation

    true = consumer_group_if_auto_commit?(fetch_request.auto_commit, state)
    {request, topic, partition} = Adapter.fetch_request(fetch_request)

    {response, updated_state} =
      kayrock_network_request(
        request,
        {:topic_partition, topic, partition},
        %{state | allow_auto_topic_creation: false}
      )

    {response, state_out} =
      case response do
        {:ok, resp} ->
          {adapted_resp, last_offset} = Adapter.fetch_response(resp)

          state_out =
            if fetch_request.auto_commit do
              consumer_group = state.consumer_group_for_auto_commit

              commit_request = %Kayrock.OffsetCommit.V0.Request{
                group_id: consumer_group,
                topics: [
                  %{
                    topic: topic,
                    partitions: [
                      %{partition: partition, offset: last_offset, metadata: ""}
                    ]
                  }
                ]
              }

              {_, updated_state} =
                kayrock_network_request(
                  commit_request,
                  {:consumer_group, consumer_group},
                  updated_state
                )

              updated_state
            else
              updated_state
            end

          {adapted_resp, state_out}

        {:error, :no_broker} ->
          {:topic_not_found, updated_state}

        _ ->
          {response, updated_state}
      end

    {:reply, response,
     %{state_out | allow_auto_topic_creation: allow_auto_topic_creation}}
  end

  def handle_call({:join_group, request, network_timeout}, _from, state) do
    sync_timeout = config_sync_timeout(network_timeout)
    {request, consumer_group} = Adapter.join_group_request(request)

    {response, updated_state} =
      kayrock_network_request(
        request,
        {:consumer_group, consumer_group},
        state,
        sync_timeout
      )

    case response do
      {:ok, resp} ->
        {:reply, Adapter.join_group_response(resp), updated_state}

      _ ->
        {:reply, response, updated_state}
    end
  end

  def handle_call({:sync_group, request, network_timeout}, _from, state) do
    sync_timeout = config_sync_timeout(network_timeout)
    {request, consumer_group} = Adapter.sync_group_request(request)

    {response, updated_state} =
      kayrock_network_request(
        request,
        {:consumer_group, consumer_group},
        state,
        sync_timeout
      )

    case response do
      {:ok, resp} ->
        {:reply, Adapter.sync_group_response(resp), updated_state}

      _ ->
        {:reply, response, updated_state}
    end
  end

  def handle_call({:leave_group, request, network_timeout}, _from, state) do
    sync_timeout = config_sync_timeout(network_timeout)
    {request, consumer_group} = Adapter.leave_group_request(request)

    {response, updated_state} =
      kayrock_network_request(
        request,
        {:consumer_group, consumer_group},
        state,
        sync_timeout
      )

    case response do
      {:ok, resp} ->
        {:reply, Adapter.leave_group_response(resp), updated_state}

      _ ->
        {:reply, response, updated_state}
    end
  end

  def handle_call({:heartbeat, request, network_timeout}, _from, state) do
    sync_timeout = config_sync_timeout(network_timeout)
    {request, consumer_group} = Adapter.heartbeat_request(request)

    {response, updated_state} =
      kayrock_network_request(
        request,
        {:consumer_group, consumer_group},
        state,
        sync_timeout
      )

    case response do
      {:ok, resp} ->
        {:reply, Adapter.heartbeat_response(resp), updated_state}

      _ ->
        {:reply, response, updated_state}
    end
  end

  def handle_call({:create_topics, requests, network_timeout}, _from, state) do
    request =
      Adapter.create_topics_request(
        requests,
        config_sync_timeout(network_timeout)
      )

    {response, updated_state} =
      kayrock_network_request(request, :controller, state)

    case response do
      {:ok, resp} ->
        {:reply, Adapter.create_topics_response(resp), updated_state}

      _ ->
        {:reply, response, updated_state}
    end
  end

  def handle_call({:delete_topics, topics, network_timeout}, _from, state) do
    request =
      Adapter.delete_topics_request(
        topics,
        config_sync_timeout(network_timeout)
      )

    {response, updated_state} =
      kayrock_network_request(request, :controller, state)

    case response do
      {:ok, resp} ->
        {:reply, Adapter.delete_topics_response(resp),
         State.remove_topics(updated_state, topics)}

      _ ->
        {:reply, response, updated_state}
    end
  end

  def handle_call({:api_versions}, _from, state) do
    {:reply, Adapter.api_versions(state.api_versions), state}
  end

  def handle_call(:consumer_group, _from, state) do
    {:reply, state.consumer_group_for_auto_commit, state}
  end

  def handle_call({:offset_fetch, offset_fetch}, _from, state) do
    unless consumer_group?(state) do
      raise KafkaEx.ConsumerGroupRequiredError, offset_fetch
    end

    {request, consumer_group} =
      Adapter.offset_fetch_request(
        offset_fetch,
        state.consumer_group_for_auto_commit
      )

    {response, updated_state} =
      kayrock_network_request(request, {:consumer_group, consumer_group}, state)

    response =
      case response do
        {:ok, resp} -> Adapter.offset_fetch_response(resp)
        _ -> response
      end

    {:reply, response, updated_state}
  end

  def handle_call({:offset_commit, offset_commit_request}, _from, state) do
    unless consumer_group?(state) do
      raise KafkaEx.ConsumerGroupRequiredError, offset_commit_request
    end

    {request, consumer_group} =
      Adapter.offset_commit_request(
        offset_commit_request,
        state.consumer_group_for_auto_commit
      )

    {response, updated_state} =
      kayrock_network_request(request, {:consumer_group, consumer_group}, state)

    response =
      case response do
        {:ok, resp} -> Adapter.offset_commit_response(resp)
        _ -> response
      end

    {:reply, response, updated_state}
  end

  @impl true
  def handle_info(:update_metadata, state) do
    {:noreply, update_metadata(state)}
  end

  @impl true
  def terminate(reason, state) do
    Logger.log(
      :debug,
      "Shutting down worker #{inspect(state.worker_name)}, " <>
        "reason: #{inspect(reason)}"
    )

    Enum.each(State.brokers(state), fn broker ->
      NetworkClient.close_socket(broker.socket)
    end)
  end

  defp update_metadata(state, topics \\ []) do
    # make sure we update metadata about known topics
    known_topics = ClusterMetadata.known_topics(state.cluster_metadata)
    topics = Enum.uniq(known_topics ++ topics)

    {updated_state, response} =
      retrieve_metadata(
        state,
        config_sync_timeout(),
        topics
      )

    case response do
      nil ->
        updated_state

      _ ->
        new_cluster_metadata =
          ClusterMetadata.from_metadata_v1_response(response)

        {updated_cluster_metadata, brokers_to_close} =
          ClusterMetadata.merge_brokers(
            updated_state.cluster_metadata,
            new_cluster_metadata
          )

        for broker <- brokers_to_close do
          Logger.log(
            :debug,
            "Closing connection to broker #{broker.node_id}: #{
              inspect(broker.host)
            } on port #{inspect(broker.port)}"
          )

          NetworkClient.close_socket(broker.socket)
        end

        updated_state =
          State.update_brokers(
            %{updated_state | cluster_metadata: updated_cluster_metadata},
            &maybe_connect_broker(&1, state)
          )

        updated_state
    end
  end

  defp maybe_connect_broker(broker, state) do
    case Broker.connected?(broker) do
      true ->
        broker

      false ->
        %{
          broker
          | socket:
              NetworkClient.create_socket(
                broker.host,
                broker.port,
                state.ssl_options,
                state.use_ssl
              )
        }
    end
  end

  defp retrieve_metadata(
         state,
         sync_timeout,
         topics
       ) do
    retrieve_metadata(
      state,
      sync_timeout,
      topics,
      @retry_count,
      0
    )
  end

  defp retrieve_metadata(
         state,
         _sync_timeout,
         topics,
         0,
         error_code
       ) do
    Logger.log(
      :error,
      "Metadata request for topics #{inspect(topics)} failed " <>
        "with error_code #{inspect(error_code)}"
    )

    {state, nil}
  end

  defp retrieve_metadata(
         state,
         sync_timeout,
         topics,
         retry,
         _error_code
       ) do
    # default to version 4 of the metdata protocol because this one treats an
    # empty list of topics as 'no topics'.  note this limits us to kafka 0.11+
    api_version = State.max_supported_api_version(state, :metadata, 4)

    metadata_request = %{
      Kayrock.Metadata.get_request_struct(api_version)
      | topics: topics,
        allow_auto_topic_creation: state.allow_auto_topic_creation
    }

    {{ok_or_err, response}, state_out} =
      kayrock_network_request(metadata_request, :any, state)

    case ok_or_err do
      :ok ->
        # THIS WILL PROBABLY NOT WORK
        case Enum.find(
               response.topic_metadata,
               &(&1.error_code ==
                   Kayrock.ErrorCode.atom_to_code!(:leader_not_available))
             ) do
          nil ->
            # HERE update state
            {state_out, response}

          topic_metadata ->
            :timer.sleep(300)

            retrieve_metadata(
              state,
              sync_timeout,
              topics,
              retry - 1,
              topic_metadata.error_code
            )
        end

      _ ->
        message =
          "Unable to fetch metadata from any brokers. Timeout is #{sync_timeout}."

        Logger.log(:error, message)
        raise message
        {state_out, nil}
    end
  end

  defp sleep_for_reconnect() do
    Process.sleep(Application.get_env(:kafka_ex, :sleep_for_reconnect, 400))
  end

  defp check_brokers_sockets!(brokers) do
    any_socket_opened =
      brokers
      |> Enum.map(fn {_, %Broker{socket: socket}} -> !is_nil(socket) end)
      |> Enum.reduce(&(&1 || &2))

    if !any_socket_opened do
      sleep_for_reconnect()
      raise "Brokers sockets are not opened"
    end
  end

  defp client_request(request, state) do
    %{
      request
      | client_id: @client_id,
        correlation_id: state.correlation_id
    }
  end

  # gets the broker for a given partition, updating metadata if necessary
  # returns {broker, maybe_updated_state}
  defp broker_for_partition_with_update(state, topic, partition) do
    case State.select_broker(state, {:topic_partition, topic, partition}) do
      {:error, _} ->
        updated_state = update_metadata(state, [topic])

        case State.select_broker(
               updated_state,
               {:topic_partition, topic, partition}
             ) do
          {:error, _} ->
            {nil, updated_state}

          {:ok, broker} ->
            {broker, updated_state}
        end

      {:ok, broker} ->
        {broker, state}
    end
  end

  defp broker_for_consumer_group_with_update(state, consumer_group) do
    case State.select_broker(state, {:consumer_group, consumer_group}) do
      {:error, _} ->
        updated_state = update_consumer_group_coordinator(state, consumer_group)

        case State.select_broker(
               updated_state,
               {:consumer_group, consumer_group}
             ) do
          {:error, _} ->
            {nil, updated_state}

          {:ok, broker} ->
            {broker, updated_state}
        end

      {:ok, broker} ->
        {broker, state}
    end
  end

  defp update_consumer_group_coordinator(state, consumer_group) do
    request = %Kayrock.FindCoordinator.V1.Request{
      coordinator_key: consumer_group,
      coordinator_type: 0
    }

    {response, updated_state} = kayrock_network_request(request, :any, state)

    case response do
      {:ok,
       %Kayrock.FindCoordinator.V1.Response{
         error_code: 0,
         coordinator: coordinator
       }} ->
        State.put_consumer_group_coordinator(
          updated_state,
          consumer_group,
          coordinator.node_id
        )

      error ->
        Logger.warn(
          "Unable to find consumer group coordinator for " <>
            "#{inspect(consumer_group)}: Error " <>
            "#{Kayrock.ErrorCode.code_to_atom(error)}"
        )

        updated_state
    end
  end

  defp first_broker_response(request, brokers, timeout) do
    Enum.find_value(brokers, fn broker ->
      if Broker.connected?(broker) do
        try_broker(broker, request, timeout)
      end
    end)
  end

  defp try_broker(broker, request, timeout) do
    Logger.debug(fn -> "SENDING TO #{inspect(broker)}" end)

    case NetworkClient.send_sync_request(broker, request, timeout) do
      {:error, error} ->
        Logger.debug(fn -> "GOT ERROR #{inspect(error)}" end)
        nil

      response ->
        response
    end
  end

  defp timeout_val(nil) do
    Application.get_env(:kafka_ex, :sync_timeout, @default_call_timeout)
  end

  defp timeout_val(timeout) when is_integer(timeout), do: timeout

  defp config_sync_timeout(timeout \\ nil) do
    timeout || Application.get_env(:kafka_ex, :sync_timeout, @sync_timeout)
  end

  defp default_partitioner do
    Application.get_env(:kafka_ex, :partitioner, KafkaEx.DefaultPartitioner)
  end

  defp consumer_group_if_auto_commit?(true, state), do: consumer_group?(state)
  defp consumer_group_if_auto_commit?(false, _state), do: true

  # note within the genserver state, we've already validated the
  # consumer group, so it can only be either :no_consumer_group or a
  # valid binary consumer group name
  defp consumer_group?(%State{
         consumer_group_for_auto_commit: :no_consumer_group
       }) do
    false
  end

  defp consumer_group?(_), do: true

  defp get_api_versions(state, request_version \\ 0) do
    request = Kayrock.ApiVersions.get_request_struct(request_version)

    {{ok_or_error, response}, state_out} =
      kayrock_network_request(request, :any, state)

    {ok_or_error, response, state_out}
  end

  defp kayrock_network_request(
         request,
         node_selector,
         state,
         network_timeout \\ nil
       ) do
    # produce request have an acks field and if this is 0 then we do not want to
    # wait for a response from the broker
    synchronous =
      case Map.get(request, :acks) do
        0 -> false
        _ -> true
      end

    network_timeout = config_sync_timeout(network_timeout)

    {sender, updated_state} =
      get_sender(node_selector, state, network_timeout, synchronous)

    case sender do
      :no_broker ->
        {{:error, :no_broker}, updated_state}

      _ ->
        Logger.debug(fn -> "SEND: " <> inspect(request, limit: :infinity) end)
        Logger.debug(fn -> inspect(updated_state) end)

        response =
          run_client_request(
            client_request(request, updated_state),
            sender,
            synchronous
          )

        Logger.debug(fn -> "RECV: " <> inspect(response, limit: :infinity) end)
        {response, State.increment_correlation_id(updated_state)}
    end
  end

  defp run_client_request(
         %{client_id: client_id, correlation_id: correlation_id} =
           client_request,
         sender,
         synchronous
       )
       when not is_nil(client_id) and not is_nil(correlation_id) do
    wire_request = Kayrock.Request.serialize(client_request)

    case(sender.(wire_request)) do
      {:error, reason} ->
        {:error, reason}

      data ->
        if synchronous do
          {:ok, deserialize(data, client_request)}
        else
          data
        end
    end
  end

  defp get_sender(:any, state, network_timeout, _synchronous) do
    {fn wire_request ->
       first_broker_response(
         wire_request,
         State.brokers(state),
         network_timeout
       )
     end, state}
  end

  defp get_sender(:controller, state, network_timeout, _synchronous) do
    {:ok, broker} = State.select_broker(state, :controller)

    {fn wire_request ->
       NetworkClient.send_sync_request(
         broker,
         wire_request,
         network_timeout
       )
     end, state}
  end

  defp get_sender(
         {:topic_partition, topic, partition},
         state,
         network_timeout,
         synchronous
       ) do
    {broker, updated_state} =
      broker_for_partition_with_update(
        state,
        topic,
        partition
      )

    if broker do
      if synchronous do
        {fn wire_request ->
           NetworkClient.send_sync_request(
             broker,
             wire_request,
             network_timeout
           )
         end, updated_state}
      else
        {fn wire_request ->
           NetworkClient.send_async_request(broker, wire_request)
         end, updated_state}
      end
    else
      {:no_broker, updated_state}
    end
  end

  defp get_sender(
         {:consumer_group, consumer_group},
         state,
         network_timeout,
         _synchronous
       ) do
    {broker, updated_state} =
      broker_for_consumer_group_with_update(
        state,
        consumer_group
      )

    {fn wire_request ->
       NetworkClient.send_sync_request(
         broker,
         wire_request,
         network_timeout
       )
     end, updated_state}
  end

  defp deserialize(data, request) do
    try do
      deserializer = Kayrock.Request.response_deserializer(request)
      {resp, _} = deserializer.(data)
      resp
    rescue
      _ ->
        Logger.error(
          "Failed to parse a response from the server: " <>
            inspect(data, limit: :infinity) <>
            " for request #{inspect(request, limit: :infinity)}"
        )

        Kernel.reraise(
          "Parse error during #{inspect(request)} response deserializer. " <>
            "Couldn't parse: #{inspect(data)}",
          System.stacktrace()
        )
    end
  end
end
