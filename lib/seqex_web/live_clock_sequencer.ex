defmodule SeqexWeb.LiveClockSequencer do
  use SeqexWeb, :live_view

  require Logger

  alias Phoenix.PubSub
  alias Seqex.ClockSequencer
  alias SeqexWeb.Components.Icons

  @default_bpm 120
  @default_sequence [[:C4], [], [:E4], [], [:G4], [], [:B4], []]
  @max_octave_value 5
  @min_octave_value 1

  def mount(params, _session, socket) do
    # Check if a process with `Seqex.Clock` name is already running, that's the default clock source. If it is, provide
    # it as the clock source for the sequencer when starting, otherwise, start the clock.
    clock = Process.whereis(Seqex.Clock) || elem(Seqex.Clock.start_link(name: Seqex.Clock), 1)
    channel = params |> Map.get("channel", "0") |> String.to_integer()
    [output_port | _] = Midiex.ports(:output)

    {:ok, sequencer} =
      Seqex.ClockSequencer.start_link(output_port, clock: clock, sequence: @default_sequence, channel: channel)

    socket
    |> assign(:sequencer, sequencer)
    |> assign(:bpm, ClockSequencer.bpm(sequencer))
    |> assign(:form, %{"bpm" => @default_bpm})
    |> assign(:sequence, ClockSequencer.sequence(sequencer))
    |> assign(:note_length, ClockSequencer.note_length(sequencer))
    |> assign(:step, ClockSequencer.step(sequencer) + 1)
    |> assign(:octave, 4)
    |> tap(fn _socket ->
      # Subscribe to the topic related to the sequencer, so that we can both broadcast updates as well as receive
      # messages related to the changes in the sequencer's state.
      PubSub.subscribe(Seqex.PubSub, ClockSequencer.topic(sequencer))
    end)
    |> then(fn socket -> {:ok, socket} end)
  end

  # Handlers for the PubSub broadcast messages.
  def handle_info({:bpm, bpm}, socket), do: {:noreply, assign(socket, :bpm, bpm)}
  def handle_info({:sequence, sequence}, socket), do: {:noreply, assign(socket, :sequence, sequence)}
  def handle_info({:step, step}, socket), do: {:noreply, assign(socket, :step, step + 1)}
  def handle_info({:note_length, length}, socket), do: {:noreply, assign(socket, :note_length, length)}

  # Handlers for `phx-click` events.
  def handle_event("update-bpm", %{"bpm" => bpm}, socket) do
    case Integer.parse(bpm) do
      {bpm, ""} when bpm >= 60 -> update_bpm(socket, bpm)
      _ -> {:noreply, put_flash(socket, :error, "BPM must be an integer greater than or equal to 60.")}
    end
  end

  def handle_event("play", _unsigned_params, socket) do
    ClockSequencer.play(socket.assigns.sequencer)
    {:noreply, socket}
  end

  def handle_event("stop", _unsigned_params, socket) do
    ClockSequencer.stop(socket.assigns.sequencer)
    {:noreply, socket}
  end

  def handle_event("update-note", %{"index" => index, "note" => note}, %{assigns: assigns} = socket) do
    index = String.to_integer(index)
    note = String.to_atom(note)

    assigns.sequence
    |> List.update_at(index, fn
      # No notes in this step, add the single note.
      nil ->
        note

      # Note already present in that same index, so transform to empty step.
      existing_note when existing_note == note ->
        nil

      # Note already present in that same index, so add the note and create a list.
      existing_note when is_atom(existing_note) ->
        [note, existing_note]

      # A list of notes is already present in this step.
      # If the note is in the list, reomve the note, otherwise add it.
      notes when is_list(notes) ->
        if Enum.member?(notes, note), do: List.delete(notes, note), else: [note | notes]
    end)
    |> tap(fn sequence -> ClockSequencer.update_sequence(assigns.sequencer, sequence, self()) end)
    |> then(fn sequence -> {:noreply, assign(socket, :sequence, sequence)} end)
  end

  def handle_event("note-length-shorten", _unsigned_params, %{assigns: assigns} = socket) do
    case assigns.note_length do
      :quarter -> update_note_length(socket, :eighth)
      :eighth -> update_note_length(socket, :sixteenth)
      :sixteenth -> update_note_length(socket, :thirty_second)
      :thirty_second -> {:noreply, socket}
    end
  end

  def handle_event("note-length-increase", _unsigned_params, %{assigns: assigns} = socket) do
    case assigns.note_length do
      :quarter -> {:noreply, socket}
      :eighth -> update_note_length(socket, :quarter)
      :sixteenth -> update_note_length(socket, :eighth)
      :thirty_second -> update_note_length(socket, :sixteenth)
    end
  end

  def handle_event("update-octave", %{"octave" => octave}, socket) do
    octave
    |> String.to_integer()
    |> then(fn value -> value |> min(@max_octave_value) |> max(@min_octave_value) end)
    |> then(fn value -> {:noreply, assign(socket, :octave, value)} end)
  end

  def handle_event("keydown", %{"key" => key}, socket) do
    if key == " " do
      if ClockSequencer.playing?(socket.assigns.sequencer) do
        ClockSequencer.stop(socket.assigns.sequencer)
      else
        ClockSequencer.play(socket.assigns.sequencer)
      end
    end

    {:noreply, socket}
  end

  defp update_note_length(socket, note_length) do
    ClockSequencer.update_note_length(socket.assigns.sequencer, note_length, self())
    {:noreply, assign(socket, :note_length, note_length)}
  end

  defp update_bpm(socket, bpm) do
    ClockSequencer.update_bpm(socket.assigns.sequencer, bpm, self())
    {:noreply, assign(socket, :bpm, bpm)}
  end

  # Helper function to determine the background color of the button based on the note and the sequence.
  defp background_color(index, note, sequence) do
    if note in Enum.at(sequence, index), do: "bg-orange", else: "bg-white"
  end

  # Given the live view's octave, generates the list of notes to display on the pads.
  # This could be done on the template, but readibility would be worse there, so we just do it here instead.
  defp notes(octave) do
    ["C", "D", "E", "F", "G", "A", "B"]
    |> Enum.map(fn note -> note <> "#{octave}" end)
    |> then(fn notes -> notes ++ ["C" <> "#{octave + 1}"] end)
    |> Enum.map(&String.to_atom/1)
  end

  # Given a note length atom representation, returns a string with the note length.
  defp note_length_to_string(:quarter), do: "1/4"
  defp note_length_to_string(:eighth), do: "1/8"
  defp note_length_to_string(:sixteenth), do: "1/16"
  defp note_length_to_string(:thirty_second), do: "1/32"
end
