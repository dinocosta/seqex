defmodule Seqex.Clock do
  @moduledoc """
  Simple GenServer responsible for sending MIDI Clock messages to another GenServer or MIDI Connection.

  In order to have another GenServer listening to this GenServer's clock messages, you must implement the
  `handle_cast/2` and add a clause for the MIDI Clock message (`[248]`), like shown:

      ```
      @impl true
      def handle_cast([248], state) do
        # Handle MIDI Clock message.
        ...
      end
      ```

  ## Example

      iex> {:ok, sequencer} = GenServer.start_link(...)
      {:ok, sequencer_pid}

      iex> {:ok, clock} = Seqex.Clock.start_link(sequencer)
      {:ok, clock_pid}
  """

  use GenServer

  alias Seqex.MIDI

  @type subscriber :: pid() | %Midiex.OutConn{}
  @type cast_message :: {:bpm, non_neg_integer()} | {:subscribe, subscriber()} | {:unsubcribe, subscriber()}

  @type state :: [
          subscribers: [subscriber()],
          interval: non_neg_integer,
          bpm: non_neg_integer
        ]

  @type option :: {:bpm, non_neg_integer()} | {:subscribers, [subscriber()]} | {:name, String.t()}

  @pulses_per_quarter 24
  @minute_in_microseconds 60_000_000

  @impl true
  @spec init(Keyword.t()) :: {:ok, state()}
  def init(args) do
    subscribers = Keyword.get(args, :subscribers, [])
    bpm = Keyword.get(args, :bpm)
    interval = trunc(@minute_in_microseconds / (bpm * @pulses_per_quarter))

    # Schedule the first `:clock` message to this own GenServer.
    MicroTimer.send_after(interval, :clock)

    {:ok, [subscribers: subscribers, bpm: bpm, interval: interval]}
  end

  @impl true
  @spec handle_info(:clock, state()) :: {:noreply, state()}
  def handle_info(:clock, state) do
    # Schedule next clock pulse in order to try and reduce any impact caused by the time spent sending
    # the MIDI Clock messages.
    MicroTimer.send_after(state[:interval], :clock)

    # Send MIDI Clock message to all subscribers, be it output connections or other GenServers.
    Enum.each(state[:subscribers], fn
      %Midiex.OutConn{} = connection -> MIDI.clock(connection)
      pid when is_pid(pid) -> GenServer.cast(pid, Midiex.Message.clock())
    end)

    {:noreply, state}
  end

  @impl true
  @spec handle_cast(cast_message(), state) :: {:noreply, state()}
  def handle_cast({:bpm, bpm}, state) do
    # Update BPM and interval but do not schedule next clock pulse, the next scheduled clock will already
    # respect the new values.
    interval = trunc(@minute_in_microseconds / (bpm * @pulses_per_quarter))

    {:noreply, Keyword.merge(state, bpm: bpm, interval: interval)}
  end

  def handle_cast({:subscribe, subscriber}, state),
    do: {:noreply, Keyword.update!(state, :subscribers, fn subscribers -> [subscriber | subscribers] end)}

  def handle_cast({:unsubscribe, subscriber}, state),
    do: {:noreply, Keyword.update!(state, :subscribers, fn subscribers -> List.delete(subscribers, subscriber) end)}

  # ------
  # Client
  # ------

  @doc """
  Creates a new MIDI Clock GenServer, with a default tempo of 120 BPM.
  """
  @spec start_link() :: {:ok, pid()}
  def start_link, do: GenServer.start_link(__MODULE__, bpm: 120)

  @doc """
  Creates a new MIDI Clock GenServer with the provided options.
  Check `option()` for a list of all the allowed options. The tempo will default to 120 BPM, if not provided.
  """
  @spec start_link(options :: [option()]) :: {:ok, pid()}
  def start_link(options) do
    opts = Keyword.take(options, [:name])

    options
    |> Keyword.put_new(:bpm, 120)
    |> then(fn args -> GenServer.start_link(__MODULE__, args, opts) end)
  end

  def start_link(subscribers, bpm) when is_list(subscribers),
    do: GenServer.start_link(__MODULE__, subscribers: subscribers, bpm: bpm)

  def start_link(subscriber, bpm), do: start_link([subscriber], bpm)

  @doc """
  Updates the clock's BPM, effectively changing the interval between the MIDI Clock messages.
  """
  @spec update_bpm(clock :: pid(), bpm :: non_neg_integer()) :: :ok
  def update_bpm(clock, bpm), do: GenServer.cast(clock, {:bpm, bpm})

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
