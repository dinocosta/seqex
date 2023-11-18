defmodule Seqex.MIDI do
  def note_on(conn, note, velocity \\ 100), do: Midiex.send_msg(conn, <<0x90, note, velocity>>)
  def note_off(conn, note), do: Midiex.send_msg(conn, <<0x80, note, 0>>)
end
