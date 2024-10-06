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

  @doc """
  Send a MIDI Note On message to the provided `connection` with provided note or list of notes.

  A note can be provided as one of these three options:

  1. A number, for example, `60` for Middle C
  2. A string, for example, "C4" for Middle C
  3. An atom, for example, :C4 for Middle C
  4. As a tuple, where the first element is any of the above, and the second element is the note's velocity (0 to 127).

  Be aware when using sharps and flats, as not all notes have both. For example, for the note `C` you can use `:Cs4`
  but you can't use `:Cb4`, while for the note `G` you can use both sharps and flats, and for the note `B` you can
  only use flats. Check the `Midiex.Message.note_on` function for more details.
  """
  @spec note_on(%Midiex.OutConn{}, note() | [note()], velocity(), non_neg_integer()) :: %Midiex.OutConn{}
  def note_on(conn, note_or_notes, velocity \\ 100, channel \\ 0)

  def note_on(conn, notes, generic_velocity, channel) when is_list(notes) do
    Enum.each(notes, fn
      {note, velocity} -> note_on(conn, note, velocity, channel)
      note -> note_on(conn, note, generic_velocity, channel)
    end)
  end

  def note_on(conn, note, velocity, channel),
    do: Midiex.send_msg(conn, Midiex.Message.note_on(note, velocity, channel: channel))

  @doc """
  Send a MIDI Note Off message to the provided `connection` with provided note or list of notes.

  A note can be provided as one of these three options:

  1. A number, for example, `60` for Middle C
  2. A string, for example, "C4" for Middle C
  3. An atom, for example, :C4 for Middle C

  Be aware when using sharps and flats, as not all notes have both. For example, for the note `C` you can use `:Cs4`
  but you can't use `:Cb4`, while for the note `G` you can use both sharps and flats, and for the note `B` you can
  only use flats. Check the `Midiex.Message.note_on` function for more details.
  """
  @spec note_off(%Midiex.OutConn{}, note() | [note()], non_neg_integer()) :: %Midiex.OutConn{}
  def note_off(conn, notes, channel \\ 0)

  def note_off(conn, notes, channel) when is_list(notes) do
    Enum.each(notes, fn
      {note, _velocity} -> note_off(conn, note, channel)
      note -> note_off(conn, note, channel)
    end)
  end

  def note_off(conn, note, channel), do: Midiex.send_msg(conn, Midiex.Message.note_off(note, 0, channel: channel))

  @doc """
  Sends a MIDI All Notes Off message to the provided connection.
  This causes the receiving device to stop all notes that are playing.
  """
  @spec all_notes_off(%Midiex.OutConn{}) :: %Midiex.OutConn{}
  def all_notes_off(connection), do: Midiex.send_msg(connection, Midiex.Message.all_notes_off())

  @doc """
  Sends a MIDI Start message (`<<0xFA>>`) to the provided output connection(s).
  """
  @spec start(%Midiex.OutConn{} | [%Midiex.OutConn{}]) :: %Midiex.OutConn{} | [%Midiex.OutConn{}]
  def start(connection_or_connections), do: Midiex.send_msg(connection_or_connections, Midiex.Message.start())

  @doc """
  Sends a MIDI Continue message (`<<0xFB>>`) to the provided output connection(s).
  """
  @spec continue(%Midiex.OutConn{} | [%Midiex.OutConn{}]) :: %Midiex.OutConn{} | [%Midiex.OutConn{}]
  def continue(connection_or_connections), do: Midiex.send_msg(connection_or_connections, <<0xFB>>)

  @doc """
  Sends a MIDI Stop message (`<<0xFC>>`) to the provided output connection(s).
  """
  @spec stop(%Midiex.OutConn{} | [%Midiex.OutConn{}]) :: %Midiex.OutConn{} | [%Midiex.OutConn{}]
  def stop(connection_or_connections), do: Midiex.send_msg(connection_or_connections, Midiex.Message.stop())

  @doc """
  Sends a MIDI Clock message (`<<0xF8>>`) to the provided output connection(s).
  """
  @spec clock(%Midiex.OutConn{} | [%Midiex.OutConn{}]) :: %Midiex.OutConn{} | [%Midiex.OutConn{}]
  def clock(connection_or_connections), do: Midiex.send_msg(connection_or_connections, Midiex.Message.clock())

  @doc """
  Convers a note, as atom, to the integer representation of the note for use in MIDI messages.

  ## Examples

      iex> Seqex.MIDI.atom_to_note(:C4)
      72
      iex> Seqex.MIDI.atom_to_note(:B5)
      95
      iex> Seqex.MIDI.atom_to_note(:Db3)
      61
      iex> Seqex.MIDI.atom_to_note(:Cs3)
      61
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

  @doc """
  Converts a note's integer representation into the respective note's atom.

  ## Options

  * `:accidentals` - When set to `:sharp`, the note will be represented as a sharp note, and when set to `:flat`, the
    note will be represented as a flat note. Uses `:sharp` by default.

  ## Examples

      iex> Seqex.MIDI.note_to_atom(72)
      :C4
      iex> Seqex.MIDI.note_to_atom(95)
      :B5
      iex> Seqex.MIDI.note_to_atom(61, accidentals: :flat)
      :Db3
      iex> Seqex.MIDI.note_to_atom(61)
      :Cs3
  """
  @spec note_to_atom(0..127) :: atom()
  def note_to_atom(note, options \\ []) do
    sharp? = Keyword.get(options, :accidentals, :sharp) == :sharp
    flat? = Keyword.get(options, :accidentals, :flat) == :flat

    scale = div(note - @base_note, 12) + @base_scale

    {letter, sharp_or_flat} =
      case Enum.find(@note_increment, fn {_letter, value} -> value == rem(note - @base_note, 12) end) do
        {letter, _value} ->
          {letter, ""}

        nil when sharp? ->
          @note_increment
          |> Enum.find(@note_increment, fn {_letter, value} -> value == rem(note - 1 - @base_note, 12) end)
          |> then(fn {letter, _value} -> {letter, "s"} end)

        nil when flat? ->
          @note_increment
          |> Enum.find(@note_increment, fn {_letter, value} -> value == rem(note + 1 - @base_note, 12) end)
          |> then(fn {letter, _value} -> {letter, "b"} end)
      end

    :"#{letter}#{sharp_or_flat}#{scale}"
  end

  @doc """
  Returns a list of notes for a major triad, given the root note.

  ## Examples

      iex> Seqex.MIDI.major_triad(:C4)
      [:C4, :E4, :G4]

      iex> Seqex.MIDI.major_triad(60)
      [60, 64, 67]
  """
  @spec major_triad(atom()) :: [note()]
  def major_triad(root) when is_integer(root), do: [root, root + 4, root + 7]

  def major_triad(root) when is_atom(root) do
    root
    |> atom_to_note()
    |> major_triad()
    |> Enum.map(&note_to_atom/1)
  end

  @doc """
  Returns a list of notes for a minor triad, given the root note.

  ## Examples

      iex> Seqex.MIDI.minor_triad(:C4)
      [:C4, :Ds4, :G4]

      iex> Seqex.MIDI.minor_triad(60)
      [60, 63, 67]
  """
  @spec minor_triad(atom()) :: [note()]
  def minor_triad(root) when is_integer(root), do: [root, root + 3, root + 7]

  def minor_triad(root) when is_atom(root) do
    root
    |> atom_to_note()
    |> minor_triad()
    |> Enum.map(&note_to_atom/1)
  end
end
