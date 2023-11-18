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

  # TODO:
  # [ ] - Move existing code to `Sequencer.Arpeggiator`, as right now this is mostly an arpeggiator.
  # [ ] - Move `:position` into the sequencer's state
  # [ ] - Fix the issue where calling `play/1` after `stop/1` does not work, because `:playing?` is set to `false`
  # [ ] - Handle triggering multiple notes at the same time, sending only one MIDI message
  # [ ] - Support `nil` in the sequence, effectively allowing empty steps where no notes are playing
  # [ ] - Build interface with LiveView which can be shared between multiple clients and one host
  # [ ] - Investigate whether MIDI messages support specifying a duration, that
  #       way we don't need to actually send the `note_off` message.


  @type sequence :: [non_neg_integer()]
  @type state :: %{
          sequence: sequence(),
          conn: %Midiex.OutConn{},
          bpm: non_neg_integer(),
          playing?: boolean()
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
    |> Map.put(:playing?, true)
    |> then(fn state -> {:ok, state} end)
  end

  # Stops the previous note in the sequence and plays another one, scheduling another cast to the GenServer to trigger
  # the next note in the sequence.
  @impl true
  def handle_info({:play, position}, %{playing?: true, sequence: sequence, conn: conn} = state) do
    # TODO: Improve this to use that sweet sweet math I just seem to be able to remember right now :melt:
    previous_note =
      if position == 0,
        do: Enum.at(sequence, length(sequence) - 1),
        else: Enum.at(sequence, position - 1)

    current_note = Enum.at(sequence, position)

    next_position =
      case position == length(sequence) - 1 do
        true -> 0
        false -> position + 1
      end

    MIDI.note_off(conn, previous_note)
    MIDI.note_on(conn, current_note)
    Process.send_after(self(), {:play, next_position}, interval(state.bpm))

    {:noreply, state}
  end

  # When `:playing?` is set to `false`, the message should be ignored, as it is likely it is being called after the
  # `:stop` message was processed but this `:play` message was already scheduled.
  def handle_info({:play, _position}, %{playing?: false} = state), do: {:noreply, state}

  # Stops the sequencer. In order to make sure no note is left hanging this will send a `note_off` message to all of the
  # possible note values in the MIDI specification. This should probably be updated to actually save the current
  # position in the GenServer's state, so that, when the sequencer is stopped we can just send the `note_off` message to
  # the note in that position of the sequence.
  def handle_info(:stop, %{conn: conn} = state) do
    0..127
    |> Enum.each(fn note -> MIDI.note_off(conn, note) end)
    |> then(fn _ -> {:noreply, Map.put(state, :playing?, false)} end)
  end

  # Determines the interval between notes taking into consideration the sequencer's BPM.
  defp interval(bpm), do: div(@minute_in_milliseconds, bpm)

  @impl true
  def handle_cast({:set_bpm, bpm}, state), do: {:noreply, Map.put(state, :bpm, bpm)}

  # --------------------------------------------------------------------------------------------------------------------
  # Client Definition
  # --------------------------------------------------------------------------------------------------------------------

  @doc """
  Starts playing the sequencer.
  """
  @spec play(pid()) :: :ok
  def play(pid), do: Process.send(pid, {:play, 0}, [])

  @doc """
  Stops the sequencer, turning off every note. 
  The GenServer is not stopped, so you can still call `play/1` with the same PID.
  """
  @spec stop(pid()) :: :ok
  def stop(pid), do: Process.send(pid, :stop, [])

  @doc """
  Kills the sequencer by calling `GenServer.stop/1`.
  """
  @spec kill(pid()) :: :ok
  def kill(pid) do
    __MODULE__.stop(pid)
    GenServer.stop(pid)
  end

  def update_bpm(pid, bpm), do: GenServer.cast(pid, {:set_bpm, bpm})
end
