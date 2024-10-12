defmodule SeqexWeb.Client do
  @moduledoc """
  This module is the LiveView client for the Sequencer, with a much more stripped down version of the features, as this
  one is merely intended to be used when allowing other users to update the sequencer for a given sequencer and to
  display information related to the sequencer in the display.
  """

  use SeqexWeb, :live_view

  require Logger

  alias Phoenix.PubSub
  alias Seqex.ClockSequencer
  alias SeqexWeb.Components.Icons
  alias Seqex.MIDI

  @max_octave_value 5
  @min_octave_value 1

  # List of colors for the active pads, with the index in the list determining the MIDI channel it is associated with.
  @active_colors [
    "bg-orange-500 bg-opacity-85",
    "bg-red-500 bg-opacity-85",
    "bg-yellow-500 bg-opacity-85",
    "bg-green-500 bg-opacity-85",
    "bg-blue-500 bg-opacity-85",
    "bg-indigo-500 bg-opacity-85",
    "bg-purple-500 bg-opacity-85",
    "bg-pink-500 bg-opacity-85",
    "bg-teal-500 bg-opacity-85",
    "bg-cyan-500 bg-opacity-85",
    "bg-lime-500 bg-opacity-85",
    "bg-emerald-500 bg-opacity-85",
    "bg-sky-500 bg-opacity-85",
    "bg-violet-500 bg-opacity-85",
    "bg-fuchsia-500 bg-opacity-85",
    "bg-rose-500 bg-opacity-85"
  ]

  # List of colors for the inactive pads, with the index in the list determining the MIDI channel it is associated
  # with.
  @inactive_colors [
    "bg-opacity-30 bg-orange-200",
    "bg-opacity-30 bg-red-200",
    "bg-opacity-30 bg-yellow-200",
    "bg-opacity-30 bg-green-200",
    "bg-opacity-30 bg-blue-200",
    "bg-opacity-30 bg-indigo-200",
    "bg-opacity-30 bg-purple-200",
    "bg-opacity-30 bg-pink-200",
    "bg-opacity-30 bg-teal-200",
    "bg-opacity-30 bg-cyan-200",
    "bg-opacity-30 bg-lime-200",
    "bg-opacity-30 bg-emerald-200",
    "bg-opacity-30 bg-sky-200",
    "bg-opacity-30 bg-violet-200",
    "bg-opacity-30 bg-fuchsia-200",
    "bg-opacity-30 bg-rose-200"
  ]

  def mount(params, _session, socket) do
    # The `mount/3` function is called twice by Phoenix, once to do the initial page load and again to establish a live
    # socket. Since we only need to connect to the sequencer once, we check if the socket is already connected. If it's
    # not, we proceed to do that setup, otherwise we'll just return the socket.
    if connected?(socket) do
      # Fetch the PID from the parameters and try to find a Process with that PID which should be the sequencer.
      sequencer = IEx.Helpers.pid(Map.get(params, "pid"))

      socket
      |> assign(:sequencer, sequencer)
      |> assign(:sequence, ClockSequencer.sequence(sequencer))
      |> assign(:step, ClockSequencer.step(sequencer) + 1)
      |> assign(:octave, 4)
      |> assign(:channel, ClockSequencer.channel(sequencer))
      |> assign(:display, "SeqEx")
      |> assign(:loading, false)
      |> tap(fn _socket ->
        # Subscribe to the topic related to the sequencer, so that we can both broadcast updates as well as receive
        # messages related to the changes in the sequencer's state.
        PubSub.subscribe(Seqex.PubSub, ClockSequencer.topic(sequencer))
      end)
      |> then(fn socket -> {:ok, socket} end)
    else
      {:ok, assign(socket, :loading, true)}
    end
  end

  # Handlers for the PubSub broadcast messages.
  # For the case of the start, continue and stop messages the client does not need to do anything, as it has
  # no UI elements that depend on these values.
  def handle_info({:sequence, sequence}, socket), do: {:noreply, assign(socket, :sequence, sequence)}
  def handle_info({:step, step}, socket), do: {:noreply, assign(socket, :step, step + 1)}
  def handle_info({:channel, channel}, socket), do: {:noreply, assign(socket, :channel, channel)}
  def handle_info(:start, socket), do: {:noreply, socket}
  def handle_info(:continue, socket), do: {:noreply, socket}
  def handle_info(:stop, socket), do: {:noreply, socket}

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
    |> then(fn sequence ->
      socket
      |> assign(:sequence, sequence)
      |> assign(:display, note)
      |> then(fn socket -> {:noreply, socket} end)
    end)
  end

  def handle_event("update-octave", %{"octave" => octave}, socket) do
    value =
      octave
      |> String.to_integer()
      |> min(@max_octave_value)
      |> max(@min_octave_value)

    socket
    |> assign(:octave, value)
    |> assign(:display, "OCTAVE #{value}")
    |> then(fn socket -> {:noreply, socket} end)
  end

  # Given the live view's octave, generates the list of notes to display on the pads.
  # This could be done on the template, but readibility would be worse there, so we just do it here instead.
  defp notes(octave) do
    ["C", "D", "E", "F", "G", "A", "B"]
    |> Enum.map(fn note -> note <> "#{octave}" end)
    |> then(fn notes -> notes ++ ["C" <> "#{octave + 1}"] end)
    |> Enum.map(&String.to_atom/1)
  end

  # Determines the background color to show for a given pad, depending on the sequencer's channel as well as whether
  # the pad is active or not.
  @spec pad_color(channel :: MIDI.channel(), active :: boolean()) :: String.t()
  defp pad_color(channel, true), do: Enum.at(@active_colors, channel)
  defp pad_color(channel, false), do: Enum.at(@inactive_colors, channel)

  # Determines whether the provided pad is active or not by figuring out if the pad's note is present in the sequence
  # for the provided index.
  defp pad_active?(index, note, sequence) do
    case Enum.at(sequence, index) do
      step_notes when is_list(step_notes) -> note in step_notes
      step_note -> note == step_note
    end
  end
end
