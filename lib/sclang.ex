defmodule SCLang do
  use GenServer
  require Logger

  @command "sclang -i \'\'"

  def eval_sync(string) do
    # i am not sure if 0x0C is correct for this case
    ref = make_ref()
    ref_string = List.to_string(:erlang.ref_to_list(ref))

    GenServer.call(
      SCLang,
      {:eval, string <> "\n\"" <> ref_string <> "\".postln" <> <<0x0C>>, ref}
    )
  end

  def eval(string) do
    GenServer.cast(SCLang, string <> <<0x0C>>)
  end

  # GenServer API
  def start_link(log \\ true) do
    GenServer.start_link(__MODULE__, log, name: __MODULE__)
  end

  @impl true
  def init(log) do
    port = Port.open({:spawn, @command}, [:binary, :exit_status])
    {:ok, %{exit_status: nil, port: port, log: log, queries: %{}}}
  end

  @impl true
  def handle_cast(str, state) do
    send(state.port, {self(), {:command, str}})
    {:noreply, state}
  end

  @impl true
  def handle_call({:eval, data, id}, from, state) do
    queries = state.queries
    queries = Map.put(queries, id, from)
    # IO.puts("HC queries: #{inspect(queries)}")
    state = Map.put(state, :queries, queries)
    # IO.puts("HC handle_call #{inspect(data)} #{inspect(id)}")
    send(state.port, {self(), {:command, data}})
    {:noreply, state}
  end

  # This callback handles data incoming from the command's STDOUT
  @impl true
  def handle_info({_port, {:data, text_line}}, state) do
    latest_output = text_line |> String.trim()

    if String.contains?(latest_output, "#Ref<") do
      [ref_string | _] = Regex.run(~r/#Ref<[0-9\.]*>/, latest_output)
      ref = :erlang.list_to_ref(String.to_charlist(ref_string))
      {from, queries} = Map.pop(state.queries, ref)
      # IO.puts("#{inspect({from, queries})}")
      out_state = Map.put(state, :queries, queries)
      # to make sure sclang communication with the server has happend
      :timer.sleep(10)

      if(from == nil) do
        IO.puts("handle_info no match to ref_string: #{inspect(ref_string)}")
      else
        GenServer.reply(from, :ok)
      end

      {:noreply, out_state}
    else
      if state.log do
        IO.puts(
          "\n--------------SC-Lang--------------\n#{latest_output}\n-----------------------------------"
        )

        {:noreply, state}
      end
    end
  end

  # This callback tells us when the process exits
  @impl true
  def handle_info({_port, {:exit_status, status}}, state) do
    if state.log, do: Logger.info("SCLang exit status: #{status}")

    if status = 0 do
      {:stop, :normal, %{state | exit_status: status}}
    else
      {:stop, status, %{state | exit_status: status}}
    end
  end

  # no-op catch-all callback for unhandled messages
  @impl true
  def handle_info(msg, state) do
    if state.log, do: Logger.info("un-handled info from SCLang: #{inspect(msg)}")
    {:noreply, state}
  end
end
