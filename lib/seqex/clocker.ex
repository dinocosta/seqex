defmodule Seqex.Clocker do
  @moduledoc """
  Simple module that listens to MIDI Clock messages, expected to be at 24 PPQ and every 24 messages
  calculates the BPM and displays it.

  Since there's currently no easy way to create a custom listener with `Midiex`, this module can simply be used while
  relying on `Midiex.Listener` to forward the input messages to this GenServer, like so:

  ```elixir
  # Fetch input port that we want to listen to.
  port = Midiex.ports(:input) |> List.first()

  # Start Clocker GenServer.
  {:ok, clocker} = #{__MODULE__}.create(port)
  ```

  It's also worth noting that this implementation expects the timestamps to be in microseconds, at least that is what
  `Midiex` was returning at the time of writing.
  """

  use GenServer

  @minute_in_microseconds 60_000_000

  @typep state :: %{
           # List of timestamps for when the clock message was received.
           timestamps: [non_neg_integer()]
         }

  # Server
  @impl true
  @spec init(term()) :: {:ok, state()}
  def init(%{input: input}) do
    clocker_pid = self()
    {:ok, listener} = Midiex.Listener.start_link(port: input)
    Midiex.Listener.add_handler(listener, fn message -> GenServer.cast(clocker_pid, {:message, message}) end)
    {:ok, %{timestamps: []}}
  end

  @impl true
  @spec handle_cast({:message, %Midiex.MidiMessage{}}, state()) :: {:noreply, state()}
  def handle_cast({:message, %Midiex.MidiMessage{data: [248], timestamp: timestamp}}, state) do
    if length(state.timestamps) == 24 do
      state.timestamps
      |> Enum.chunk_every(2)
      |> Enum.map(fn [latest, earliest] -> latest - earliest end)
      |> then(fn differences -> Enum.sum(differences) / 12 end)
      |> then(fn average -> IO.inspect("Average #{average} | BPM #{calculate_bpm(average)}") end)
      |> then(fn _ -> {:noreply, %{state | timestamps: []}} end)
    else
      {:noreply, Map.update!(state, :timestamps, fn values -> [timestamp | values] end)}
    end
  end

  def handle_cast(_message, state), do: {:noreply, state}

  # Client
  @spec create(%Midiex.MidiPort{direction: :input}) :: {:ok, pid()}
  def create(input), do: GenServer.start_link(__MODULE__, %{input: input})

  # Assume that the `interval` argument is the average interval between MIDI Clock messages in microseconds,
  # that is why we divide the value by `1000`, so we can get its value in milliseconds.
  # We could also divide 60_000_000 and the result would be the same
  @spec calculate_bpm(non_neg_integer()) :: float()
  defp calculate_bpm(interval), do: @minute_in_microseconds / interval / 24
end
