defmodule SeqexWeb.LiveSequencer do
  use SeqexWeb, :live_view

  require Logger

  alias Phoenix.PubSub
  alias Seqex.Sequencer

  @default_bpm 120
  @default_sequence [:C4, nil, :E4, nil, :G4, nil, :B4, nil]

  def render(assigns) do
    ~H"""
    <div class="bg-light-gray min-h-screen p-14">
      <h1 class="text-3xl font-bold mb-14" id="title" phx-hook="SetupSequencer" phx-update="ignore">SeqEx</h1>

      <div class="flex gap-4 mb-4">
        <div class="bg-orange text-white p-4" phx-click="play">Play</div>
        <div class="bg-gray text-white p-4" phx-click="stop">Stop</div>
        <div class="bg-white text-dark-gray p-4"><%= @bpm %></div>
        <div class="bg-gray text-white p-4" phx-click="bpm-dec">-</div>
        <div class="bg-gray text-white p-4" phx-click="bpm-inc">+</div>
      </div>

      <%= for note <- [:C4, :D4, :E4, :F4, :G4, :A4, :B4] do %>
        <div class="block space-x-2 mb-2">
          <%= for index <- 0..7 do %>
            <button phx-click="update-note" phx-value-index={index} phx-value-note={note} class="w-8 h-8 bg-gray" />
          <% end %>
        </div>
      <% end %>
      <div class="flex gap-4 mb-4">
        <%= for id <- 1..4 do %>
          <div class="w-14 h-14 bg-dark-gray">
            <p class="text-white"><%= id %></p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

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
    |> assign(:sequence, Sequencer.sequence(sequencer))
    |> assign(:topic, Sequencer.topic(sequencer))
    |> tap(fn socket ->
      # Subscribe to the topic related to the sequencer, so that we can both broadcast updates as well as receive
      # messages related to the changes in the sequencer's state.
      PubSub.subscribe(Seqex.PubSub, socket.assigns.topic)
    end)
    |> then(fn socket ->
      # For the existing notes in the sequencer, send a `"sequencer-toggle"` event so that those pads are highlighted
      # when the user first opens the page.
      socket.assigns.sequence
      |> Enum.with_index()
      |> Enum.reduce(socket, fn
        {nil, _index}, socket ->
          socket

        {notes, index}, socket when is_list(notes) ->
          Enum.reduce(notes, socket, fn note, socket ->
            push_event(socket, "sequencer-toggle", %{note: note, index: index})
          end)

        {note, index}, socket ->
          push_event(socket, "sequencer-toggle", %{note: note, index: index})
      end)
    end)
    |> then(fn socket -> {:ok, socket} end)
  end

  # Handlers for the PubSub broadcast messages.
  def handle_info({:bpm, bpm}, state), do: {:noreply, assign(state, :bpm, bpm)}
  def handle_info({:sequence, sequence}, state), do: {:noreply, assign(state, :sequence, sequence)}

  # Handlers for `phx-click` events.
  def handle_event("bpm-dec", _unsigned_params, socket), do: update_bpm(socket, socket.assigns.bpm - 1)
  def handle_event("bpm-inc", _unsigned_params, socket), do: update_bpm(socket, socket.assigns.bpm + 1)

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
    |> then(fn sequence ->
      socket
      |> push_event("sequencer-toggle", %{index: index, note: note})
      |> assign(:sequence, sequence)
      |> then(fn socket -> {:noreply, socket} end)
    end)
  end

  defp update_bpm(socket, bpm) do
    Sequencer.update_bpm(socket.assigns.sequencer, bpm, self())
    {:noreply, assign(socket, :bpm, bpm)}
  end
end
