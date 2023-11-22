defmodule Seqex.MIDI do
  def note_on(conn, note_or_notes, velocity \\ 100)

  def note_on(conn, notes, velocity) when is_list(notes),
    do: Enum.each(notes, fn note -> note_on(conn, note, velocity) end)

  def note_on(conn, note, velocity), do: Midiex.send_msg(conn, <<0x90, note, velocity>>)

  def note_off(conn, notes) when is_list(notes),
    do: Enum.each(notes, fn note -> note_off(conn, note) end)

  def note_off(conn, note), do: Midiex.send_msg(conn, <<0x80, note, 0>>)
end
