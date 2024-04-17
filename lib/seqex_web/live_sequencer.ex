# LaunchPad message that starts the OP-1 Field – 250
# 1111 1010
# Second time around it's 252
# 1111 1100
defmodule SeqexWeb.LiveSequencer do
  use SeqexWeb, :live_view

  require Logger

  alias Phoenix.PubSub
  alias Seqex.Sequencer
  alias SeqexWeb.Components.Icons

  @default_bpm 120
  @default_sequence [[:C4], [], [:E4], [], [:G4], [], [:B4], []]
  @max_octave_value 5
  @min_octave_value 1

  def mount(_params, _session, socket) do
    # When mounting, we'll first see if there's already a process with the `Seqex.Sequencer` name, if that's the case
    # then we'll use it's PID instead of starting a new GenServer for the sequencer. This allows us to control the
    # same sequencer, independently of the client that is connecting to the live view.
    sequencer =
      case Process.whereis(Seqex.Sequencer) do
        nil ->
          :output
          |> Midiex.ports()
          |> List.first()
          |> Sequencer.start_link(sequence: @default_sequence, bpm: @default_bpm, name: Seqex.Sequencer)
          |> then(fn {:ok, sequencer} -> sequencer end)

        sequencer ->
          sequencer
      end

    socket
    |> assign(:sequencer, sequencer)
    |> assign(:bpm, Sequencer.bpm(sequencer))
    |> assign(:form, %{"bpm" => @default_bpm})
    |> assign(:sequence, Sequencer.sequence(sequencer))
    |> assign(:note_length, Sequencer.note_length(sequencer))
    |> assign(:step, Sequencer.step(sequencer) + 1)
    |> assign(:octave, 4)
    |> tap(fn _socket ->
      # Subscribe to the topic related to the sequencer, so that we can both broadcast updates as well as receive
      # messages related to the changes in the sequencer's state.
      PubSub.subscribe(Seqex.PubSub, Sequencer.topic(sequencer))
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
    Sequencer.play(socket.assigns.sequencer)
    {:noreply, socket}
  end

  def handle_event("stop", _unsigned_params, socket) do
    Sequencer.stop(socket.assigns.sequencer)
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
    |> tap(fn sequence -> Sequencer.update_sequence(assigns.sequencer, sequence, self()) end)
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
      if Sequencer.playing?(socket.assigns.sequencer) do
        Sequencer.stop(socket.assigns.sequencer)
      else
        Sequencer.play(socket.assigns.sequencer)
      end
    end

    {:noreply, socket}
  end

  defp update_note_length(socket, note_length) do
    Sequencer.update_note_length(socket.assigns.sequencer, note_length, self())
    {:noreply, assign(socket, :note_length, note_length)}
  end

  defp update_bpm(socket, bpm) do
    Sequencer.update_bpm(socket.assigns.sequencer, bpm, self())
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
