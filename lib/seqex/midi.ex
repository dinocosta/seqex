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

  # Base note for which to perform the calculation when transforming atom to integer.
  # This is the C4 note, so we know we should compare the atom's note scale to 4.
  @base_note 60
  @base_scale 3

  # How many semitones to increment the note value by, depending on it's distance to the note C.
  @note_increment %{"C" => 0, "D" => 2, "E" => 4, "F" => 5, "G" => 7, "A" => 9, "B" => 11}

  # When note is sharp (`"s"`) the note should move up one semitone, when flat (`"b"`) it should move down one
  # semitone.
  @accidental_increment %{"s" => 1, "b" => -1}

  @spec note_on(%Midiex.OutConn{}, note() | [note()], velocity()) :: %Midiex.OutConn{}
  def note_on(conn, note_or_notes, velocity \\ 100)

  def note_on(conn, notes, generic_velocity) when is_list(notes) do
    Enum.each(notes, fn
      {note, velocity} -> note_on(conn, note, velocity)
      note -> note_on(conn, note, generic_velocity)
    end)
  end

  def note_on(conn, note, velocity) when is_integer(note), do: Midiex.send_msg(conn, <<0x90, note, velocity>>)
  def note_on(conn, atom, velocity) when is_atom(atom), do: note_on(conn, atom_to_note(atom), velocity)

  @spec note_off(%Midiex.OutConn{}, note() | [note()]) :: %Midiex.OutConn{}
  def note_off(conn, notes) when is_list(notes) do
    Enum.each(notes, fn
      {note, _velocity} -> note_off(conn, note)
      note -> note_off(conn, note)
    end)
  end

  def note_off(conn, note) when is_integer(note), do: Midiex.send_msg(conn, <<0x80, note, 0>>)
  def note_off(conn, atom) when is_atom(atom), do: note_off(conn, atom_to_note(atom))

  @doc """
  Convers a note, as atom, to the integer representation of the note for use in MIDI messages.

  ## Examples

      iex> Seqex.MIDI.atom_to_note(:C4)
      60
      iex> Seqex.MIDI.atom_to_note(:B5)
      83
      iex> Seqex.MIDI.atom_to_note(:Db3)
      49
      iex> Seqex.MIDI.atom_to_note(:Cs3)
      49
  """
  @spec atom_to_note(atom()) :: 0..127
  def atom_to_note(atom) do
    atom
    |> Atom.to_string()
    |> String.codepoints()
    |> then(fn
      [note, scale] ->
        (String.to_integer(scale) - @base_scale) * 12 + @base_note + @note_increment[note]

      [note, accidental, scale] ->
        (String.to_integer(scale) - @base_scale) * 12 + @base_note + @note_increment[note] +
          @accidental_increment[accidental]
    end)
  end
end
