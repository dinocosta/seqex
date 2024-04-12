defmodule Seqex.Sequencer do
  @moduledoc """
  Simple implementation of a Sequencer, using GenServer to use messages as the trigger for the next note in the
  sequence.

  # Example

  Here's some example usage with `Midiex`.

      iex> [port | _] = Midiex.ports(:output)
      iex> {:ok, sequencer} = #{__MODULE__}.start_link(port, sequence: [60, 64, 67, 71])
      iex> #{__MODULE__}.play(sequencer)
  """

  use GenServer

  alias Phoenix.PubSub
  alias Seqex.MIDI

  @type sequence :: [MIDI.note() | [MIDI.note()]]

  @type note_length :: :quarter | :eighth | :sixteenth | :thirty_second

  @typedoc """
  * `sequence` - List of notes, or chords, to be played in the sequence.
  * `bpm` - The sequencer's BPM.
  * `note_length` - Lenght of each note in the sequence. Defaults to `:quarter` and can be any of the following values:
    * `:quarter` - 1/4 of a beat.
    * `:eighth` - 1/8 of a beat.
    * `:sixteenth` - 1/16 of a beat.
    * `:thirty_second` - 1/32 of a beat.
  """
  @type option :: {:sequence, sequence()} | {:bpm, non_neg_integer()} | {:connection, %Midiex.OutConn{}}

  @typedoc """
  * `sequence` - List of notes, or chords, to be played in the sequence.
  * `conn` - The `%Midiex.OutConn{}` struct to be used to send the MIDI messages to.
  * `bpm` - The sequencer's BPM, increasing this value will make the sequencer play faster, while decreasing it will
    have the opposite effect.
  * `playing?` - Whether the sequencer is currently playing or not.
  * `notes_playing` - Used to keep track of the notes that are currently being played, so that we can stop them when
    the sequencer starts playing the notes in the next sep, when the sequencer is stopped or the sequence is updated.
  * `position` - The current position in the sequence.
  """
  @type state :: %{
          sequence: sequence(),
          conn: %Midiex.OutConn{},
          bpm: non_neg_integer(),
          note_length: note_length(),
          playing?: boolean(),
          notes_playing: [MIDI.note() | [MIDI.note()]],
          position: non_neg_integer()
        }

  @minute_in_milliseconds 60_000

  # Mapping between note length representation in atom and their decimal value, helpful when using it to calculate the
  # interval between notes.
  @note_lengths %{quarter: 1 / 4, eighth: 1 / 8, sixteenth: 1 / 16, thirty_second: 1 / 32}

  @default_initial_state %{
    sequence: [],
    bpm: 120,
    note_length: :quarter
  }

  # -------------------------------------------------------------------------------------------------------------------
  # Server Definition
  # -------------------------------------------------------------------------------------------------------------------

  @impl true
  @spec init(state()) :: {:ok, state()}
  def init(state) do
    state
    |> Map.put_new(:bpm, 120)
    |> Map.put(:playing?, false)
    |> Map.put(:position, 0)
    |> Map.put(:notes_playing, [])
    |> then(fn state -> {:ok, state} end)
  end

  # Stops the previous note(s) in the sequence and plays the next one(s), scheduling another cast to the GenServer to
  # trigger the one(s) after.
  @impl true
  def handle_info(:play, %{playing?: true, sequence: sequence, conn: conn, position: position} = state) do
    # TODO: Improve this to use that sweet sweet math I just seem to be able to remember right now :melt:
    # We're using the `|| []` bit to make sure we also support steps with empty notes (`nil`).
    current_notes = List.flatten([Enum.at(sequence, position) || []])

    next_position =
      case position == length(sequence) - 1 do
        true -> 0
        false -> position + 1
      end

    # Determines the interval between notes taking into consideration the sequencer's BPM.
    interval = round(div(@minute_in_milliseconds, state.bpm) * (@note_lengths[state.note_length] * 4))

    MIDI.note_off(conn, state.notes_playing)
    MIDI.note_on(conn, current_notes)
    Process.send_after(self(), :play, interval)

    # Broadcast any time the sequencer has moved to a different step, in case clients want to display the current step.
    PubSub.broadcast(Seqex.PubSub, topic(self()), {:step, position + 1})

    {:noreply, Map.merge(state, %{position: next_position, notes_playing: current_notes})}
  end

  # When `:playing?` is set to `false`, the message should be ignored, as it is likely it is being called after the
  # `:stop` message was processed but this `:play` message was already scheduled.
  def handle_info(:play, %{playing?: false} = state), do: {:noreply, state}

  # Simply returns whether the sequencer is playing or not, useful in order to avoid sending the `:play` message
  # again, to avoid the sequencer acting weird.
  @impl true
  def handle_call(:is_playing?, _from, state), do: {:reply, state.playing?, state}

  # Returns the current BPM of the sequencer.
  def handle_call(:bpm, _from, state), do: {:reply, state.bpm, state}

  # Returns the sequence of notes the sequencer is playing.
  def handle_call(:sequence, _from, state), do: {:reply, state.sequence, state}

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
  def handle_cast(:toggle_playing, state),
    do: {:noreply, Map.put(state, :playing?, !state.playing?)}

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
    # If the current position is bigger than the number of elements in the new sequence, let's go back to 0,
    # otherwise keep the current position so we avoid weirdly jumping back to the beginning of the sequence.
    position = if state.position >= length(sequence), do: 0, else: state.position

    state
    |> Map.put(:sequence, sequence)
    |> Map.put(:position, position)
    |> then(fn updated_state -> {:noreply, updated_state} end)
  end

  def handle_cast({:update_note_length, note_length}, state) do
    state
    |> Map.put(:note_length, note_length)
    |> then(fn updated_state -> {:noreply, updated_state} end)
  end

  # -------------------------------------------------------------------------------------------------------------------
  # Client Definition
  # -------------------------------------------------------------------------------------------------------------------

  @doc """
  Starts a new GenServer instance for the sequencer.
  You must provide the MIDI output port as the `output_port` argument.
  """
  @spec start_link(port_or_conn :: %Midiex.MidiPort{} | %Midiex.OutConn{}, options :: [option()]) :: {:ok, pid()}
  def start_link(port_or_conn, options \\ [])
  def start_link(%Midiex.MidiPort{} = port, options), do: start_link(Midiex.open(port), options)

  def start_link(%Midiex.OutConn{} = conn, options) do
    state =
      options
      |> Enum.into(%{})
      |> Map.take(Map.keys(@default_initial_state))
      |> Map.put(:conn, conn)
      |> then(fn options -> Map.merge(@default_initial_state, options) end)

    genserver_options = Enum.reject(options, fn {key, _value} -> key in Map.keys(@default_initial_state) end)

    GenServer.start_link(__MODULE__, state, genserver_options)
  end

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
  Since this function call broadcasts updates on the sequencer's PubSub topic, the `caller` argument can be used to
  define which process triggered this update and avoid sending the message to that process.
  """
  @spec update_bpm(pid(), non_neg_integer(), caller :: pid()) :: :ok
  def update_bpm(sequencer, bpm, caller \\ nil) do
    GenServer.cast(sequencer, {:update_bpm, bpm})

    case caller do
      nil -> PubSub.broadcast(Seqex.PubSub, topic(sequencer), {:bpm, bpm})
      pid -> PubSub.broadcast_from(Seqex.PubSub, pid, topic(sequencer), {:bpm, bpm})
    end
  end

  @doc """
  Updates the sequence used by the `sequencer` to the ones in `sequence`.
  Since this function call broadcasts updates on the sequencer's PubSub topic, the `caller` argument can be used to
  define which process triggered this update and avoid sending the message to that process.
  """
  @spec update_sequence(pid(), [MIDI.note() | [MIDI.note()]], caller :: pid()) :: :ok
  def update_sequence(sequencer, sequence, caller \\ nil) do
    GenServer.cast(sequencer, {:update_sequence, sequence})

    case caller do
      nil -> PubSub.broadcast(Seqex.PubSub, topic(sequencer), {:sequence, sequence})
      pid -> PubSub.broadcast_from(Seqex.PubSub, pid, topic(sequencer), {:sequence, sequence})
    end
  end

  @spec update_note_length(pid(), note_length(), caller :: pid() | nil) :: :ok | {:error, :invalid_note_length}
  def update_note_length(sequencer, note_length, caller \\ nil) do
    if note_length not in Map.keys(@note_lengths) do
      {:error, :invalid_note_length}
    else
      GenServer.cast(sequencer, {:update_note_length, note_length})

      case caller do
        nil -> PubSub.broadcast(Seqex.PubSub, topic(sequencer), {:note_length, note_length})
        pid -> PubSub.broadcast_from(Seqex.PubSub, pid, topic(sequencer), {:note_length, note_length})
      end
    end
  end

  @doc """
  Returns the sequencer's BPM.
  """
  @spec bpm(pid()) :: non_neg_integer()
  def bpm(sequencer), do: GenServer.call(sequencer, :bpm)

  @doc """
  Returns the sequencer's current sequence of notes.
  """
  @spec sequence(pid()) :: sequence()
  def sequence(sequencer), do: GenServer.call(sequencer, :sequence)

  @doc """
  Returns the PubSub topic the sequencer uses to broadcast update messages (updated bpm, updated sequence, etc.).
  """
  @spec topic(pid()) :: String.t()
  def topic(sequencer), do: "seqex.sequencer:#{inspect(sequencer)}"
end
