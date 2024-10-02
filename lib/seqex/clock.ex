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

  @type state :: [
          subscribers: [pid() | %Midiex.OutConn{}],
          interval: non_neg_integer,
          bpm: non_neg_integer
        ]

  @pulses_per_quarter 24
  @minute_in_microseconds 60_000_000

  @impl true
  @spec init(Keyword.t()) :: {:ok, state()}
  def init(args) do
    subscribers = Keyword.get(args, :subscribers)
    bpm = Keyword.get(args, :bpm)
    interval = trunc(@minute_in_microseconds / (bpm * @pulses_per_quarter))

    # Schedule the first `:clock` message to this own GenServer.
    MicroTimer.send_after(interval, :clock)

    {:ok, [subscribers: subscribers, bpm: bpm, interval: interval]}
  end

  @impl true
  @spec handle_info(:clock, state()) :: {:noreply, state()}
  def handle_info(:clock, state) do
    # Send MIDI Clock message to all subscribers, be it output connections or other GenServers.
    Enum.each(state[:subscribers], fn
      %Midiex.OutConn{} = connection -> MIDI.clock(connection)
      pid when is_pid(pid) -> GenServer.cast(pid, Midiex.Message.clock())
    end)

    # Schedule next clock pulse.
    MicroTimer.send_after(state[:interval], :clock)

    {:noreply, state}
  end

  @impl true
  @spec handle_cast({:bpm, non_neg_integer()}, state) :: {:noreply, state()}
  def handle_cast({:bpm, bpm}, state) do
    # Update BPM and interval but do not schedule next clock pulse, the next scheduled clock will already
    # respect the new values.
    interval = trunc(@minute_in_microseconds / (bpm * @pulses_per_quarter))

    {:noreply, Keyword.merge(state, bpm: bpm, interval: interval)}
  end

  # ------
  # Client
  # ------

  @spec start_link(subscribers :: [pid() | %Midiex.OutConn{}], bpm :: non_neg_integer) :: {:ok, pid()}
  def start_link(subscribers, bpm \\ 120)

  def start_link(subscribers, bpm) when is_list(subscribers),
    do: GenServer.start_link(__MODULE__, subscribers: subscribers, bpm: bpm)

  def start_link(subscriber, bpm), do: start_link([subscriber], bpm)

  @spec update_bpm(pid(), non_neg_integer()) :: :ok
  def update_bpm(clock, bpm), do: GenServer.cast(clock, {:bpm, bpm})
end
