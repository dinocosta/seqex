defmodule Seqex.ExternalClock do
  @moduledoc """
  This modules works similar to the `Seqex.Clock` module, with the difference being the fact we no longer rely
  on having the GenServer sending a message to itself whenever the next clock should be sent. Instead, this module
  expects a `%Midiex.MidiPort{}` struct with `direction: :input` to be provided. The GenServer will then attach a
  Listener to the MIDI Input port and forward any MIDI Clock messages it receives to the GenServer's subscribers
  via `GenServer.cast` or `Midiex.send_msg`, depending on whether the subscriber is another GenServer (Seqex Sequencer)
  or a MIDI Output Connection (`%Midiex.OutConn{}`).

  ## Example

      # 1. Find a suitable MIDI Input Port.
      iex> input_port = Midiex.ports(:input) |> List.first()

      # 2. Start the External Clock GenServer.
      iex> {:ok, clock} = Seqex.ExternalClock.start_link(input_port)
  """

  use GenServer

  require Logger

  @type subscriber :: pid() | %Midiex.OutConn{}
  @type cast_message :: {:subscribe, subscriber()} | {:unsubcribe, subscriber()}
  @type state :: [subscribers: [subscriber()]]
  @type option :: {:name, String.t()} | {:subscribers, [subscriber()]}

  # Mapping between the message value sent by Midiex's Listener to the binary representation of that same message.
  @midi_messages %{
    248 => Midiex.Message.clock(),
    250 => Midiex.Message.start(),
    251 => <<0xFB>>,
    252 => Midiex.Message.stop()
  }

  @impl true
  @spec init(Keyword.t()) :: {:ok, state()}
  def init(args) do
    input_port = Keyword.get(args, :input_port)
    subscribers = Keyword.get(args, :subscribers, [])

    # Subscribe to all incoming MIDI messages from the MIDI Input Port.
    Midiex.subscribe(input_port)

    {:ok, [subscribers: subscribers]}
  end

  @impl true
  def handle_info(%Midiex.MidiMessage{data: [data]}, state) when is_map_key(@midi_messages, data) do
    Enum.each(state[:subscribers], fn
      %Midiex.OutConn{} = connection -> Midiex.send_msg(connection, @midi_messages[data])
      pid when is_pid(pid) -> GenServer.cast(pid, @midi_messages[data])
    end)

    {:noreply, state}
  end

  # Ignore all other MIDI messages.
  def handle_info(_midi_message, state), do: {:noreply, state}

  @impl true
  def handle_cast({:subscribe, subscriber}, state),
    do: {:noreply, Keyword.update!(state, :subscribers, fn subscribers -> [subscriber | subscribers] end)}

  def handle_cast({:unsubscribe, subscriber}, state),
    do: {:noreply, Keyword.update!(state, :subscribers, fn subscribers -> List.delete(subscribers, subscriber) end)}

  # ------
  # Client
  # ------

  @spec start_link(input_port :: %Midiex.MidiPort{direction: :input}) :: {:ok, pid()}
  def start_link(input_port), do: GenServer.start_link(__MODULE__, input_port: input_port)

  @spec start_link(input_port :: %Midiex.MidiPort{direction: :input}, [option()]) :: {:ok, pid()}
  def start_link(input_port, options) do
    opts = Keyword.take(options, [:name])
    subscribers = Keyword.get(options, :subscribers, [])

    GenServer.start_link(__MODULE__, [input_port: input_port, subscribers: subscribers], opts)
  end

  @doc """
  Add another GenServer or MIDI Device to the list of subscribers for the provided `clock`.
  """
  @spec subscribe(clock :: pid(), subscriber :: subscriber()) :: :ok
  def subscribe(clock, subscriber), do: GenServer.cast(clock, {:subscribe, subscriber})

  @doc """
  Remove GenServer or MIDI Device from the list of subscribers for the provided `clock`.
  """
  @spec unsubscribe(clock :: pid(), subscriber :: subscriber()) :: :ok
  def unsubscribe(clock, subscriber), do: GenServer.cast(clock, {:unsubscribe, subscriber})
end
