defmodule Seqex.Sequencer do
  @moduledoc """
  Simple implementation of a Sequencer, using GenServer to use messages as the trigger for the next note in the
  sequence.

  # Example

  Here's some example usage with `Midiex`.

      iex> output_port = Enum.find(Midiex.ports(), fn port -> port.direction == :output end)
      iex> connection = Midiex.open(output_port)
      iex> sequence = [60, 64, 67, 71]
      iex> {:ok, sequencer} = GenServer.start_link(#{__MODULE__}, %{sequence: sequence, conn: connection})
      iex> #{__MODULE__}.play(sequencer)
  """

  use GenServer

  alias Seqex.MIDI

  @type notes :: [non_neg_integer()]
  @type state :: %{
          sequence: notes(),
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

  # Stops the previous note(s) in the sequence and plays the next one(s), scheduling another cast to the GenServer to
  # trigger the one(s) after.
  @impl true
  def handle_info(:play, %{playing?: true, sequence: sequence, conn: conn, position: position} = state) do
    # TODO: Improve this to use that sweet sweet math I just seem to be able to remember right now :melt:
    current_notes = List.flatten([Enum.at(sequence, position)])

    next_position =
      case position == length(sequence) - 1 do
        true -> 0
        false -> position + 1
      end

    # Determines the interval between notes taking into consideration the sequencer's BPM.
    interval = div(@minute_in_milliseconds, state.bpm)

    MIDI.note_off(conn, previous_notes(state))
    MIDI.note_on(conn, current_notes)
    Process.send_after(self(), :play, interval)

    {:noreply, Map.put(state, :position, next_position)}
  end

  # When `:playing?` is set to `false`, the message should be ignored, as it is likely it is being called after the
  # `:stop` message was processed but this `:play` message was already scheduled.
  def handle_info(:play, %{playing?: false} = state), do: {:noreply, state}

  # Simply returns whether the sequencer is playing or not, useful in order to avoid sending the `:play` message
  # again, to avoid the sequencer acting weird.
  @impl true
  def handle_call(:is_playing?, _from, state), do: {:reply, state.playing?, state}

  # Stops the sequencer. In order to make sure no note is left hanging this will send a `note_off` message to all of
  # the possible note values in the MIDI specification. This should probably be updated to actually save the current
  # position in the GenServer's state, so that, when the sequencer is stopped we can just send the `note_off` message
  # to the note in that position in the sequence.
  @impl true
  def handle_cast(:stop, %{conn: conn} = state) do
    0..127
    |> Enum.each(fn note -> MIDI.note_off(conn, note) end)
    |> then(fn _ -> {:noreply, Map.put(state, :playing?, false)} end)
  end

  # Toggles the `:playing?` boolean in the state, effectively stopping or starting the sequencer.
  def handle_cast(:toggle_playing, state), do: {:noreply, Map.put(state, :playing?, !state.playing?)}

  def handle_cast({:update_bpm, bpm}, state), do: {:noreply, Map.put(state, :bpm, bpm)}

  # Updating the `:sequence` in the sequencer's state also means both: 
  #
  # 1. Updating the `:position` to 0, in order to make sure that, if the new
  # sequence is smaller than the previous one, we don't get an exception by trying to access an
  # element out of bounds.
  # 2. Stopping the last played note as we're resetting the position, so it's
  # likely that the next time the `:play` message runs it won't stop the
  # previously played note, as the sequence of notes might have changed as well as
  # the position has changed.
  def handle_cast({:update_sequence, sequence}, state) do 
    MIDI.note_off(state.conn, previous_notes(state))

    state
    |> Map.put(:sequence, sequence)
    |> Map.put(:position, 0)
    |> then(fn updated_state -> {:noreply, updated_state} end)
  end

  # Finds the notes that were previously played in the sequence, to make sure we stop them before
  # playing the next ones.
  defp previous_notes(%{sequence: sequence, position: position} = _state) do
    previous_position = if position == 0, do: length(sequence) - 1, else: position - 1

    # We're inserting the note or list of notes into a list and then calling `List.flatten/1` to
    # make sure this function always return a list of notes, even if the sequence only has single
    # notes.
    sequence
    |> Enum.at(previous_position)
    |> then(fn notes -> List.flatten([notes]) end)
  end

  # --------------------------------------------------------------------------------------------------------------------
  # Client Definition
  # --------------------------------------------------------------------------------------------------------------------

  @doc """
  Starts playing the sequencer.
  """
  @spec play(pid()) :: :ok
  def play(sequencer) do 
    if GenServer.call(sequencer, :is_playing?) == false do
      GenServer.cast(sequencer, :toggle_playing)
      Process.send(sequencer, :play, [])
    end
  end

  @doc """
  Stops the sequencer, turning off every note. 
  The GenServer is not stopped, so you can still call `play/1` with the same PID.
  """
  @spec stop(pid()) :: :ok
  def stop(sequencer) do 
    GenServer.cast(sequencer, :toggle_playing)
    GenServer.cast(sequencer, :stop)
  end

  @doc """
  Kills the sequencer by calling `GenServer.stop/1`.
  """
  @spec kill(pid()) :: :ok
  def kill(sequencer) do
    __MODULE__.stop(sequencer)
    GenServer.stop(sequencer)
  end

  @doc """
  Updates the beats per minutes of the `sequencer` to the ones in `bpm`.
  """
  @spec update_bpm(pid(), non_neg_integer()) :: :ok
  def update_bpm(sequencer, bpm), do: GenServer.cast(sequencer, {:update_bpm, bpm})

  @doc """
  Updates the sequence used by the `sequencer` to the ones in `sequence`.
  """
  @spec update_sequence(pid(), notes()) :: :ok
  def update_sequence(sequencer, sequence), do: GenServer.cast(sequencer, {:update_sequence, sequence})
end
