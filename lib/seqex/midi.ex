defmodule Seqex.MIDI do
  @moduledoc """
  Helper functions to send MIDI messages to a MIDI output port.
  """

  @typedoc """
  The velocity determines how hard a note is played, with 0 being the softest and 127 the hardest.
  """
  @type velocity :: 0..127

  @typedoc """
  A note can either be repreesented as a single integer, meaning the MIDI note to be played, or a tuple, where the
  first value is the note to be played and the second value is the velocity of the note.
  """
  @type note :: 0..127 | {0..127, velocity()}

  @spec note_on(%Midiex.OutConn{}, note() | [note()], velocity()) :: %Midiex.OutConn{}
  def note_on(conn, note_or_notes, velocity \\ 100)

  def note_on(conn, notes, generic_velocity) when is_list(notes) do
    Enum.each(notes, fn
      {note, velocity} -> note_on(conn, note, velocity)
      note -> note_on(conn, note, generic_velocity)
    end)
  end

  def note_on(conn, note, velocity), do: Midiex.send_msg(conn, <<0x90, note, velocity>>)

  @spec note_off(%Midiex.OutConn{}, note() | [note()]) :: %Midiex.OutConn{}
  def note_off(conn, notes) when is_list(notes) do
    Enum.each(notes, fn
      {note, _velocity} -> note_off(conn, note)
      note -> note_off(conn, note)
    end)
  end

  def note_off(conn, note), do: Midiex.send_msg(conn, <<0x80, note, 0>>)
end
