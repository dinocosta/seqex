defmodule Seqex.MIDI do
  def note_on(conn, note_or_notes, velocity \\ 100)

  def note_on(conn, notes, generic_velocity) when is_list(notes) do
    Enum.each(notes, fn
      {note, velocity} -> note_on(conn, note, velocity)
      note -> note_on(conn, note, generic_velocity)
    end)
  end

  def note_on(conn, note, velocity), do: Midiex.send_msg(conn, <<0x90, note, velocity>>)

  def note_off(conn, notes) when is_list(notes) do
    Enum.each(notes, fn
      {note, _velocity} -> note_off(conn, note)
      note -> note_off(conn, note)
    end)
  end

  def note_off(conn, note), do: Midiex.send_msg(conn, <<0x80, note, 0>>)
end
