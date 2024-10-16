defmodule Seqex.ClockSequencer do
  @moduledoc """
  Simple implementation of a Sequencer, which relies on MIDI Clock messages to move forward in the sequence.
  This sequencer works with a resolution of 24 PPQ, which means that, when the note length is set to `:quarter`,
  it will move to the next step in the sequence every 24 MIDI Clock messages. If set to `:eighth` it will move
  to the next step every 12 MIDI Clock messages, so on and so forth.

  # Example

  Here's some example usage with `Midiex`.

      iex> [port | _] = Midiex.ports(:output)
      iex> {:ok, sequencer} = #{__MODULE__}.start_link(port, sequence: [60, 64, 67, 71])
      iex> #{__MODULE__}.play(sequencer)
  """

  use GenServer

  alias Phoenix.PubSub
  alias Seqex.MIDI

  require Logger

  @type sequence :: [MIDI.note() | [MIDI.note()]]

  @type note_length :: :quarter | :eighth | :sixteenth | :thirty_second

  @typedoc """
  * `sequence` - List of notes, or chords, to be played in the sequence.
  * `bpm` - The sequencer's BPM.
  * `connection` - The output MIDI connection to where the sequencer will send messages to.
  * `clock` - PID of the GenServer responsible for sending MIDI Clock messages to this sequencer. If not provided, the
    sequencer will start a new `Seqex.Clock` GenServer and use that for syncing.
  * `channel`- The MIDI channel to send the MIDI messages to, from 0 to 15. Defaults to 0 (Channel 1).
  * `note_length` - Lenght of each note in the sequence. Defaults to `:quarter` and can be any of the following values:
    * `:quarter` - 1/4 of a beat.
    * `:eighth` - 1/8 of a beat.
    * `:sixteenth` - 1/16 of a beat.
    * `:thirty_second` - 1/32 of a beat.
  """
  @type option ::
          {:sequence, sequence()}
          | {:bpm, non_neg_integer()}
          | {:connection, %Midiex.OutConn{}}
          | {:clock, pid()}
          | {:channel, non_neg_integer()}

  @typedoc """
  * `sequence` - List of notes, or chords, to be played in the sequence.
  * `connection` - The `%Midiex.OutConn{}` struct to be used to send the MIDI messages to.
  * `bpm` - The sequencer's BPM, increasing this value will make the sequencer play faster, while decreasing it will
    have the opposite effect.
  * `playing?` - Whether the sequencer is currently playing or not.
  * `notes_playing` - Used to keep track of the notes that are currently being played, so that we can stop them when
    the sequencer starts playing the notes in the next sep, when the sequencer is stopped or the sequence is updated.
  * `step` - The current step in the sequence.
  * `channel` - MIDI channel where the sequencer will send messages to.
  * `clock` - The PID of the GenServer that is responsible for sending MIDI Clock messages to this sequencer.
  * `clock_count` - Number of MIDI Clock messages the sequencer has received since it has started playing.
  * `clock_interval` - How many MIDI Clock messages the sequencer needs to be receive before playing a note. This
    value is updated whenever the sequencer's note length is changed. For a length of a quarter note (1/4), this should
    be the same as the resolution (24 PPQ), but for a length of eight (1/8), it should be half of that.
  """
  @type state :: %{
          sequence: sequence(),
          connection: %Midiex.OutConn{},
          bpm: non_neg_integer(),
          note_length: note_length(),
          playing?: boolean(),
          notes_playing: [MIDI.note() | [MIDI.note()]],
          step: non_neg_integer(),
          channel: non_neg_integer(),
          clock: pid(),
          clock_count: non_neg_integer()
        }

  @minute_in_milliseconds 60_000

  # MIDI Messages the sequencer must be able to respond to.
  @clock_message Midiex.Message.clock()
  @start_message Midiex.Message.start()
  @continue_message <<0xFB>>
  @stop_message Midiex.Message.stop()

  # Mapping between note length representation in atom and their decimal value, helpful when using it to calculate the
  # interval between notes.
  @note_lengths %{quarter: 1 / 4, eighth: 1 / 8, sixteenth: 1 / 16, thirty_second: 1 / 32}

  @default_initial_state %{
    sequence: [],
    bpm: 120,
    note_length: :quarter,
    channel: 0,
    clock_count: 0
  }

  # -------------------------------------------------------------------------------------------------------------------
  # Server Definition
  # -------------------------------------------------------------------------------------------------------------------

  @impl true
  @spec init([option()]) :: {:ok, state()}
  def init(args) do
    clock = if is_map_key(args, :clock), do: args.clock, else: elem(Seqex.Clock.start_link(), 1)
    GenServer.cast(clock, {:subscribe, self()})

    args
    |> Map.put_new(:bpm, 120)
    |> Map.put_new(:channel, 0)
    |> Map.put(:clock_interval, clock_interval(args.note_length))
    |> Map.put(:playing?, false)
    |> Map.put(:step, 0)
    |> Map.put(:notes_playing, [])
    |> Map.put(:clock, clock)
    |> then(fn state -> {:ok, state} end)
  end

  # Stops the previous note(s) in the sequence and plays the next one(s), scheduling another cast to the GenServer to
  # trigger the one(s) after.
  @impl true
  def handle_info(:play, %{playing?: true, sequence: sequence, connection: connection, step: step} = state) do
    # TODO: Improve this to use that sweet sweet math I just seem to be able to remember right now :melt:
    # We're using the `|| []` bit to make sure we also support steps with empty notes (`nil`).
    current_notes = List.flatten([Enum.at(sequence, step) || []])

    next_step =
      case step == length(sequence) - 1 do
        true -> 0
        false -> step + 1
      end

    # Determines the interval between notes taking into consideration the sequencer's BPM.
    interval = round(div(@minute_in_milliseconds, state.bpm) * (@note_lengths[state.note_length] * 4))

    MIDI.note_off(connection, state.notes_playing, state.channel)
    MIDI.note_on(connection, current_notes, state.channel)
    Process.send_after(self(), :play, interval)

    # Broadcast any time the sequencer has moved to a different step, in case clients want to display the current step.
    PubSub.broadcast(Seqex.PubSub, topic(self()), {:step, step})

    {:noreply, Map.merge(state, %{step: next_step, notes_playing: current_notes})}
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

  # Returns the note length of the notes the sequencer is playing.
  def handle_call(:note_length, _from, state), do: {:reply, state.note_length, state}

  # Returns the current step in the sequence.
  def handle_call(:step, _from, state), do: {:reply, state.step, state}

  # Returns the PID of the GenServer that is sending clock to this sequencer.
  # Useful if you want to sync multiple sequencers to the same clock.
  def handle_call(:clock, _from, state), do: {:reply, state.clock, state}

  def handle_call(:channel, _from, state), do: {:reply, state.channel, state}

  # Toggles the `:playing?` boolean in the state, effectively stopping or starting the sequencer.
  def handle_cast(:toggle_playing, state),
    do: {:noreply, Map.put(state, :playing?, !state.playing?)}

  def handle_cast(:play, state), do: {:noreply, Map.put(state, :playing?, true)}

  @doc """
  Since the sequencer doesn't actually have its own BPM, as that depends on the clock that is sending it the MIDI Clock
  messages, we'll simply cast this message to the GenServer that is sending the MIDI Clock to the sequencer.

  Be aware that this might not always work, for example, if the MIDI Clock messages are actually being set by an
  external device (OP-1, OP-Z, EP-133, etc.) instead of a single GenServer.
  """
  def handle_cast({:update_bpm, bpm}, state) do
    state
    |> Map.get(:clock)
    |> GenServer.cast({:bpm, bpm})
    |> then(fn _ -> {:noreply, state} end)
  end

  # Updating the `:sequence` in the sequencer's state also means both:
  #
  # 1. Updating the `:step` to 0, in order to make sure that, if the new
  # sequence is smaller than the previous one, we don't get an exception by trying to access an
  # element out of bounds.
  # 2. Stopping the last played note as we're resetting the step, so it's
  # likely that the next time the `:play` message runs it won't stop the
  # previously played note, as the sequence of notes might have changed as well as
  # the step has changed.
  def handle_cast({:update_sequence, sequence}, state) do
    # If the current step is bigger than the number of elements in the new sequence, let's go back to 0,
    # otherwise keep the current step so we avoid weirdly jumping back to the beginning of the sequence.
    step = if state.step >= length(sequence), do: 0, else: state.step

    state
    |> Map.put(:sequence, sequence)
    |> Map.put(:step, step)
    |> then(fn updated_state -> {:noreply, updated_state} end)
  end

  def handle_cast({:update_note_length, note_length}, state) do
    state
    |> Map.put(:note_length, note_length)
    |> Map.put(:clock_interval, clock_interval(note_length))
    |> then(fn updated_state -> {:noreply, updated_state} end)
  end

  # Updates the clock process that this sequencer is listening to by unsubscribing from the current clock
  # and subscribing to the new one.
  def handle_cast({:update_clock, clock}, state) do
    GenServer.cast(state.clock, {:unsubscribe, self()})
    GenServer.cast(clock, {:subscribe, self()})
    {:noreply, Map.put(state, :clock, clock)}
  end

  # Updates the MIDI channel the sequencer is sending messages to.
  def handle_cast({:update_channel, channel}, state), do: {:noreply, Map.put(state, :channel, channel)}

  # If the sequencer is not playing, completely ignore the MIDI Clock message.
  def handle_cast(@clock_message, %{playing?: false} = state), do: {:noreply, state}

  # TODO: Update to work with lengths other than 1/4 note.
  # TODO: Figure out when to broadcast step changes:
  # Broadcast any time the sequencer has moved to a different step, in case clients want to display the current step.
  #    PubSub.broadcast(Seqex.PubSub, topic(self()), {:step, step})
  def handle_cast(@clock_message, state) do
    clock_count = state.clock_count + 1

    case rem(clock_count, state.clock_interval) do
      # First MIDI Clock message. Play the notes in this step and increment the count.
      1 ->
        play(state.sequence, state.step, state.connection, state.notes_playing, state.channel)
        |> then(fn notes_playing -> Map.put(state, :notes_playing, notes_playing) end)
        |> Map.put(:clock_count, clock_count)
        |> then(fn state -> {:noreply, state} end)

      # A value of 0 means the sequencer has just received as many MIDI messages as it's `clock_interval` value,
      # so we should jump to the next step.
      0 ->
        step = next_step(state.sequence, state.step)

        state
        |> Map.put(:step, step)
        |> tap(fn _ -> PubSub.broadcast(Seqex.PubSub, topic(self()), {:step, step}) end)
        |> Map.put(:clock_count, clock_count)
        |> then(fn state -> {:noreply, state} end)

      # Simply increase clock count.
      _ ->
        {:noreply, Map.put(state, :clock_count, clock_count)}
    end
  end

  # When the sequencer receives the MIDI Start message, we need to go back to the first step of the sequence
  # reset the clock count as set it to play, as this is effectively the same as restarting the sequencer.
  def handle_cast(@start_message, state) do
    state
    |> Map.put(:clock_count, 0)
    |> Map.put(:step, 0)
    |> Map.put(:playing?, true)
    |> tap(fn _ -> PubSub.broadcast(Seqex.PubSub, topic(self()), :start) end)
    |> then(fn state -> {:noreply, state} end)
  end

  # When the sequencer receives a MIDI Continue message it means it can continue the sequence from where it stopped,
  # which in this implementation basically means setting the sequencer's `:playing?` value to `true`.
  def handle_cast(@continue_message, state) do
    PubSub.broadcast(Seqex.PubSub, topic(self()), :continue)
    {:noreply, Map.put(state, :playing?, true)}
  end

  # Stops the sequencer. In order to make sure no note is left hanging this will send a `note_off` message to all of
  # the possible note values in the MIDI specification. This should probably be updated to actually save the current
  # step in the GenServer's state, so that, when the sequencer is stopped we can just send the `note_off` message
  # to the note in that step in the sequence.
  @impl true
  def handle_cast(@stop_message, %{connection: connection, playing?: true, channel: channel} = state) do
    MIDI.note_off(connection, Range.to_list(0..127), channel)
    PubSub.broadcast(Seqex.PubSub, topic(self()), :stop)
    {:noreply, Map.put(state, :playing?, false)}
  end

  # If the sequencer is already stopped and it gets another MIDI Stop message, reset the clock count and step.
  # This is to mimick what happens with the OP-1 Field, where pressing the Stop button twice takes it to the beginning
  # of the loop, effectively resetting the song position.
  def handle_cast(@stop_message, %{playing?: false} = state) do
    state
    |> Map.put(:step, 0)
    |> Map.put(:clock_count, 0)
    |> tap(fn _ -> PubSub.broadcast(Seqex.PubSub, topic(self()), :stop) end)
    |> then(fn state -> {:noreply, state} end)
  end

  @spec play(sequence(), non_neg_integer(), %Midiex.OutConn{}, [MIDI.note() | [MIDI.note()]], non_neg_integer()) :: [
          MIDI.note() | [MIDI.note()]
        ]
  defp play(sequence, step, connection, notes_playing, channel) do
    # TODO: Improve this to use that sweet sweet math I just seem to be able to remember right now :melt:
    # We're using the `|| []` bit to make sure we also support steps with empty notes (`nil`).
    current_notes = List.flatten([Enum.at(sequence, step) || []])

    MIDI.note_off(connection, notes_playing, channel)
    MIDI.note_on(connection, current_notes, 100, channel)

    current_notes
  end

  # Determines the index of the next step in the sequence, given the current step and the sequence.
  @spec next_step(sequence(), non_neg_integer()) :: non_neg_integer()
  defp next_step(sequence, step) do
    case step == length(sequence) - 1 do
      true -> 0
      false -> step + 1
    end
  end

  @spec clock_interval(note_length()) :: non_neg_integer()
  defp clock_interval(:quarter), do: 24
  defp clock_interval(:eighth), do: 12
  defp clock_interval(:sixteenth), do: 6
  defp clock_interval(:thirty_second), do: 3

  # -------------------------------------------------------------------------------------------------------------------
  # Client Definition
  # -------------------------------------------------------------------------------------------------------------------

  @doc """
  Starts a new GenServer instance for the sequencer.
  You must provide the MIDI output port as the `output_port` argument.
  """
  @spec start_link(port_or_connection :: %Midiex.MidiPort{} | %Midiex.OutConn{}, options :: [option()]) :: {:ok, pid()}
  def start_link(port_or_connection, options \\ [])
  def start_link(%Midiex.MidiPort{} = port, options), do: start_link(Midiex.open(port), options)

  def start_link(%Midiex.OutConn{} = connection, options) do
    state =
      options
      |> Enum.into(%{})
      |> Map.put(:connection, connection)
      |> then(fn options -> Map.merge(@default_initial_state, options) end)

    genserver_options = Enum.reject(options, fn {key, _value} -> key in Map.keys(@default_initial_state) end)

    GenServer.start_link(__MODULE__, state, genserver_options)
  end

  @doc """
  Starts playing the sequencer.
  """
  @spec play(pid()) :: :ok
  def play(sequencer), do: GenServer.cast(sequencer, :play)

  @doc """

  """
  @spec start(pid()) :: :ok
  def start(sequencer), do: GenServer.cast(sequencer, @start_message)

  @doc """
  Sends a MIDI Continue message to the sequencer, effectively allowing it to continue playin from where it stopped.
  """
  @spec continue(pid()) :: :ok
  def continue(sequencer), do: GenServer.cast(sequencer, @continue_message)

  @doc """
  Stops the sequencer, turning off every note.
  The GenServer is not stopped, so you can still call `play/1` with the same PID.
  """
  @spec stop(pid()) :: :ok
  def stop(sequencer), do: GenServer.cast(sequencer, @stop_message)

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
  Updates the clock that the sequencer will listen to for MIDI Clock messages.
  """
  @spec update_clock(sequencer :: pid(), clock :: pid()) :: :ok
  def update_clock(sequencer, clock), do: GenServer.cast(sequencer, {:update_clock, clock})

  @doc """
  Updates the MIDI channel this sequencer is sending messages to.

  The `caller` parameter can be used when the calling process is a subscriber of the sequencer and does not wish to
  receive a message with the updated channel, as it was the one updating it.
  """
  @spec update_channel(sequencer :: pid(), channel :: non_neg_integer(), caller :: pid()) :: :ok
  def update_channel(sequencer, channel, caller \\ nil)
  def update_channel(_, channel, _) when channel > 15 or channel < 0, do: :ok

  def update_channel(sequencer, channel, caller) do
    GenServer.cast(sequencer, {:update_channel, channel})

    case caller do
      nil -> PubSub.broadcast(Seqex.PubSub, topic(sequencer), {:channel, channel})
      pid -> PubSub.broadcast_from(Seqex.PubSub, pid, topic(sequencer), {:channel, channel})
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
  Returns the sequencer's current note length.
  """
  @spec sequence(pid()) :: note_length()
  def note_length(sequencer), do: GenServer.call(sequencer, :note_length)

  @doc """
  Returns the sequencer's step in the sequence.
  """
  @spec step(pid()) :: non_neg_integer()
  def step(sequencer), do: GenServer.call(sequencer, :step)

  @doc """
  Returns the PID for the GenServer that is sending MIDI Clock messages to this sequencer.
  """
  @spec clock(sequencer :: pid()) :: clock :: pid()
  def clock(sequencer), do: GenServer.call(sequencer, :clock)

  @doc """
  Returns the current channel the sequencer is sending messages to.
  """
  @spec channel(sequencer :: pid()) :: non_neg_integer()
  def channel(sequencer), do: GenServer.call(sequencer, :channel)

  @doc """
  Returns whether the sequencer is playing or not.
  """
  @spec playing?(pid()) :: boolean()
  def playing?(sequencer), do: GenServer.call(sequencer, :is_playing?)

  @doc """
  Returns the PubSub topic the sequencer uses to broadcast update messages (updated bpm, updated sequence, etc.).
  """
  @spec topic(pid()) :: String.t()
  def topic(sequencer), do: "seqex.sequencer:#{inspect(sequencer)}"
end
