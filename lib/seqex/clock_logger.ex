defmodule Seqex.ClockLogger do
  @moduledoc """
  Module used to test receiving MIDI Clock messages from the `Seqex.Clock` module or other external clock sources.
  Since this expects a resolution of 24 PPQ, this GenServer will listen to incoming MIDI Clock messages, and every 24
  messages it will calculate the BPM.

  # Usage

  ```
  # 1. Start Clock.
  {:ok, clock} = Seqex.Clock.start_link()

  # 2. Start Clock Logger.
  {:ok, logger} = Seqex.ClockLogger.start_link()

  # 3. Subscribe the Clock Logger to the Clock.
  Seqex.Clock.subscribe(clock, logger)
  ```
  """

  use GenServer

  require Logger

  defmodule State do
    @type t :: %__MODULE__{}
    defstruct timestamps: []
  end

  @clock_message Midiex.Message.clock()
  @minute_in_nanoseconds 60_000_000_000

  @impl true
  @spec init(Keyword.t()) :: {:ok, State.t()}
  def init(_args), do: {:ok, %State{timestamps: []}}

  @impl true
  @spec handle_cast(binary(), State.t()) :: {:noreply, State.t()}
  def handle_cast(@clock_message, %State{timestamps: timestamps} = state) do
    # If there's already 23 timestamps in the list of timestamps, that means the GenServer has just received the last
    # MIDI Clock message to complete the 24 PPQ, calculate BPM and empty the list of timestamps, otherwise just save
    # it to the list of timestamps.
    case length(timestamps) do
      23 ->
        [System.os_time() | timestamps]
        |> Enum.chunk_every(2)
        |> Enum.map(fn [later, earlier] -> later - earlier end)
        |> then(fn intervals -> Enum.sum(intervals) / length(intervals) end)
        |> then(fn average_interval -> @minute_in_nanoseconds / average_interval / 24 end)
        |> then(fn bpm -> Logger.info("BPM #{bpm}") end)

        {:noreply, %State{state | timestamps: []}}

      _ ->
        {:noreply, %State{state | timestamps: [System.os_time() | timestamps]}}
    end
  end

  def start_link, do: GenServer.start_link(__MODULE__, [])
end
