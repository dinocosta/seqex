defmodule Seqex.Arpeggiator do
  @moduledoc """
  Simple implementation of an arpeggiator, using GenServer to use messages as the trigger for the next note in the
  chord.

  # Example

  Here's some example usage with `Midiex`.

      iex> output_port = Enum.find(Midiex.ports(), fn port -> port.direction == :output end)
      iex> connection = Midiex.open(output_port)
      iex> notes = [60, 64, 67, 71]
      iex> {:ok, arpeggiator} = GenServer.start_link(#{__MODULE__}, %{notes: notes, conn: connection})
      iex> #{__MODULE__}.play(arpeggiator)
  """

  use GenServer

  alias Seqex.MIDI

  # TODO:
  # [ ] - Build interface with LiveView which can be shared between multiple clients and one host
  # [ ] - Investigate whether MIDI messages support specifying a duration, that
  #       way we don't need to actually send the `note_off` message.

  @type notes :: [non_neg_integer()]
  @type state :: %{
          notes: notes(),
          conn: %Midiex.OutConn{},
          bpm: non_neg_integer(),
          playing?: boolean(),
          position: non_neg_integer()
        }

  @minute_in_milliseconds 60_000

  # --------------------------------------------------------------------------------------------------------------------
  # Server Definition
  # --------------------------------------------------------------------------------------------------------------------

  @impl true
  @spec init(state()) :: {:ok, state()}
  def init(state) do
    state
    |> Map.put_new(:bpm, 120)
    |> Map.put(:playing?, false)
    |> Map.put(:position, 0)
    |> then(fn state -> {:ok, state} end)
  end

  # Stops the previous note in the list of notes and plays another one, scheduling another cast to the GenServer to
  # trigger the next note..
  @impl true
  def handle_info(:play, %{playing?: true, notes: notes, conn: conn, position: position} = state) do
    # TODO: Improve this to use that sweet sweet math I just seem to be able to remember right now :melt:
    previous_note =
      if position == 0,
        do: Enum.at(notes, length(notes) - 1),
        else: Enum.at(notes, position - 1)

    current_note = Enum.at(notes, position)

    next_position =
      case position == length(notes) - 1 do
        true -> 0
        false -> position + 1
      end

    # Determines the interval between notes taking into consideration the arpeggiator's BPM.
    interval = div(@minute_in_milliseconds, state.bpm)

    MIDI.note_off(conn, previous_note)
    MIDI.note_on(conn, current_note)
    Process.send_after(self(), :play, interval)

    {:noreply, Map.put(state, :position, next_position)}
  end

  # When `:playing?` is set to `false`, the message should be ignored, as it is likely it is being called after the
  # `:stop` message was processed but this `:play` message was already scheduled.
  def handle_info(:play, %{playing?: false} = state), do: {:noreply, state}

  # Simply returns whether the arpeggiator is playing or not, useful in order to avoid sending the `:play` message
  # again, to avoid the arpeggiator acting weird.
  @impl true
  def handle_call(:is_playing?, _from, state), do: {:reply, state.playing?, state}

  # Stops the arpeggiator. In order to make sure no note is left hanging this will send a `note_off` message to all of
  # the possible note values in the MIDI specification. This should probably be updated to actually save the current
  # position in the GenServer's state, so that, when the arpeggiator is stopped we can just send the `note_off` message
  # to the note in that position of the list of notes.
  @impl true
  def handle_cast(:stop, %{conn: conn} = state) do
    0..127
    |> Enum.each(fn note -> MIDI.note_off(conn, note) end)
    |> then(fn _ -> {:noreply, Map.put(state, :playing?, false)} end)
  end

  def handle_cast({:set_bpm, bpm}, state), do: {:noreply, Map.put(state, :bpm, bpm)}

  # Toggles the `:playing?` boolean in the state, effectively stopping or starting the arpeggiator.
  def handle_cast(:toggle_playing, state), do: {:noreply, Map.put(state, :playing?, !state.playing?)}

  # --------------------------------------------------------------------------------------------------------------------
  # Client Definition
  # --------------------------------------------------------------------------------------------------------------------

  @doc """
  Starts playing the arpeggiator.
  """
  @spec play(pid()) :: :ok
  def play(pid) do 
    if GenServer.call(pid, :is_playing?) == false do
      GenServer.cast(pid, :toggle_playing)
      Process.send(pid, :play, [])
    end
  end

  @doc """
  Stops the arpeggiator, turning off every note. 
  The GenServer is not stopped, so you can still call `play/1` with the same PID.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) do 
    GenServer.cast(pid, :toggle_playing)
    GenServer.cast(pid, :stop)
  end

  @doc """
  Kills the arpeggiator by calling `GenServer.stop/1`.
  """
  @spec kill(pid()) :: :ok
  def kill(pid) do
    __MODULE__.stop(pid)
    GenServer.stop(pid)
  end

  def update_bpm(pid, bpm), do: GenServer.cast(pid, {:set_bpm, bpm})
end
