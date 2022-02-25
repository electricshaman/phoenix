defmodule Phoenix.Integration.WebsocketClient do
  use GenServer

  alias Phoenix.Socket.Message

  @doc """
  Starts the WebSocket server for given ws URL. Received Socket.Message's
  are forwarded to the sender pid
  """
  def start_link(sender, url, serializer, headers \\ []) do
    :crypto.start()
    :ssl.start()

    GenServer.start_link(__MODULE__, {sender, url, serializer, headers}, debug: [:trace])
  end

  @doc """
  Closes the socket
  """
  def close({conn, ref, sock} = _client) do
    {:ok, sock, data} = Mint.WebSocket.encode(sock, :close)
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    {:ok, conn} = Mint.HTTP.close(conn)
    {conn, ref, sock}
  end

  @doc """
  Sends an event to the WebSocket server per the message protocol.
  """
  def send_event(server_pid, topic, event, msg) do
    send(server_pid, {:send, %Message{topic: topic, event: event, payload: msg}})
  end

  @doc """
  Sends a low-level text message to the client.
  """
  def send_message(client, msg) do
    # send(server_pid, {:send, msg})
    {conn, ref, _sock} = client
    {:ok, sock, data} = encode(client, {:text, msg})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    {:ok, conn, sock}
  end

  @doc """
  Sends a control frame to the client.
  """
  def send_control_frame(server_pid, opcode, msg \\ :none) do
    send(server_pid, {:control, opcode, msg})
  end

  @doc """
  Sends a heartbeat event
  """
  def send_heartbeat(server_pid) do
    send_event(server_pid, "phoenix", "heartbeat", %{})
  end

  @doc """
  Sends join event to the WebSocket server per the Message protocol
  """
  def join(server_pid, topic, msg) do
    send_event(server_pid, topic, "phx_join", msg)
  end

  @doc """
  Sends leave event to the WebSocket server per the Message protocol
  """
  def leave(server_pid, topic, msg) do
    send_event(server_pid, topic, "phx_leave", msg)
  end

  @doc false
  def init({sender, url, serializer, extra_headers}) do
    {:ok, client} = connect(url, extra_headers)

    ## Use different initial join_ref from ref to
    ## make sure the server is not coupling them.
    {:ok,
     %{
       sender: sender,
       serializer: serializer,
       client: client,
       topics: %{},
       join_ref: 11,
       ref: 1
     }}
  end

  def connect(url, extra_headers \\ []) when is_binary(url) do
    {:ok, uri} = uri_new(url)

    http_scheme =
      case String.to_existing_atom(uri.scheme) do
        :ws -> :http
        :wss -> :https
        other -> other
      end

    ws_scheme =
      case http_scheme do
        :http -> :ws
        :https -> :wss
      end

    {:ok, conn} = Mint.HTTP.connect(http_scheme, uri.host, uri.port)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(ws_scheme, conn, uri.path, extra_headers)

    receive do
      reply ->
        {:ok, conn, resp} = Mint.WebSocket.stream(conn, reply)

        upgraded =
          Enum.reduce(resp, %{}, fn
            {:status, ^ref, code}, res -> Map.put(res, :status, code)
            {:headers, ^ref, headers}, res -> Map.put(res, :headers, headers)
            _other, res -> res
          end)

        {:ok, conn, sock} = Mint.WebSocket.new(conn, ref, upgraded[:status], upgraded[:headers])
        {:ok, {conn, ref, sock}}
    end
  end

  def decode({_conn, _ref, sock} = _client, data) do
    Mint.WebSocket.decode(sock, data)
  end

  def encode({_conn, _ref, sock} = _client, data) do
    Mint.WebSocket.encode(sock, data)
  end

  def uri_new(url) do
    # URI.new for elixir < 1.13.0.
    case :uri_string.parse(url) do
      %{} = map ->
        {:ok, Map.merge(%URI{}, map)}

      {:error, :invalid_uri, term} ->
        {:error, Kernel.to_string(term)}
    end
  end

  def handle_info({:send, msg}, %{serializer: :noop} = state) do
    send(state.sender, {:text, msg})
    {:noreply, state}
  end

  def handle_info({:text, msg}, %{serializer: :noop} = state) do
    send(state.sender, {:text, msg})
    {:noreply, state}
  end

  def handle_info({:text, msg}, state) do
    send(state.sender, state.serializer.decode!(msg, opcode: :text))
    {:noreply, state}
  end

  def handle_info({:binary, data}, state) do
    send(state.sender, binary_decode(data))
    {:noreply, state}
  end

  def handle_info({:control, opcode, msg}, state) when opcode in [:ping, :pong] do
    send(state.sender, {:control, opcode, msg})
    {:noreply, state}
  end

  def handle_info({:control, opcode, msg}, %{serializer: :noop} = state) do
    case msg do
      :none ->
        send(state.sender, opcode)
        {:noreply, state}

      _ ->
        send(state.sender, {opcode, msg})
        {:noreply, state}
    end
  end

  def handle_info(
        {:send, %Message{payload: {:binary, _}} = msg},
        %{ref: ref} = state
      ) do
    {join_ref, state} = join_ref_for(msg, state)
    msg = Map.merge(msg, %{ref: to_string(ref), join_ref: to_string(join_ref)})
    {:reply, {:binary, binary_encode_push!(msg)}, put_in(state.ref, ref + 1)}
  end

  def handle_info({:tcp, _, _} = msg, state) do
    {:ok, conn, responses} = Mint.WebSocket.stream(state.conn, msg)
    # WIP
    {:noreply, state}
  end

  def handle_info({:send, %Message{} = msg}, %{ref: ref} = state) do
    {join_ref, state} = join_ref_for(msg, state)
    msg = Map.merge(msg, %{ref: to_string(ref), join_ref: to_string(join_ref)})
    {:reply, {:text, encode!(msg, state)}, put_in(state.ref, ref + 1)}
  end

  def handle_info(:close, state) do
    {:close, <<>>, "done"}
    {:stop, :close, state}
  end

  def handle_info(msg, state) do
    {:noreply, state}
  end

  defp join_ref_for(
         %{topic: topic, event: "phx_join"},
         %{topics: topics, join_ref: join_ref} = state
       ) do
    topics = Map.put(topics, topic, join_ref)
    {join_ref, %{state | topics: topics, join_ref: join_ref + 1}}
  end

  defp join_ref_for(%{topic: topic}, %{topics: topics} = state) do
    {Map.get(topics, topic), state}
  end

  @doc false
  def websocket_terminate(_reason, _conn_state, _state) do
    :ok
  end

  defp encode!(map, state) do
    {:socket_push, :text, chardata} = state.serializer.encode!(map)
    IO.chardata_to_string(chardata)
  end

  defp binary_encode_push!(%Message{payload: {:binary, data}} = msg) do
    ref = to_string(msg.ref)
    join_ref = to_string(msg.join_ref)
    join_ref_size = byte_size(join_ref)
    ref_size = byte_size(ref)
    topic_size = byte_size(msg.topic)
    event_size = byte_size(msg.event)

    <<
      0::size(8),
      join_ref_size::size(8),
      ref_size::size(8),
      topic_size::size(8),
      event_size::size(8),
      join_ref::binary-size(join_ref_size),
      ref::binary-size(ref_size),
      msg.topic::binary-size(topic_size),
      msg.event::binary-size(event_size),
      data::binary
    >>
  end

  # push
  defp binary_decode(<<
         0::size(8),
         join_ref_size::size(8),
         topic_size::size(8),
         event_size::size(8),
         join_ref::binary-size(join_ref_size),
         topic::binary-size(topic_size),
         event::binary-size(event_size),
         data::binary
       >>) do
    %Message{join_ref: join_ref, topic: topic, event: event, payload: {:binary, data}}
  end

  # reply
  defp binary_decode(<<
         1::size(8),
         join_ref_size::size(8),
         ref_size::size(8),
         topic_size::size(8),
         status_size::size(8),
         join_ref::binary-size(join_ref_size),
         ref::binary-size(ref_size),
         topic::binary-size(topic_size),
         status::binary-size(status_size),
         data::binary
       >>) do
    payload = %{"status" => status, "response" => {:binary, data}}
    %Message{join_ref: join_ref, ref: ref, topic: topic, event: "phx_reply", payload: payload}
  end
end
