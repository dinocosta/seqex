defmodule SeqexWeb.LiveSequencer do
  use SeqexWeb, :live_view

  require Logger

  alias Phoenix.PubSub
  alias Seqex.Sequencer
  alias SeqexWeb.Components.Icons

  @default_bpm 120
  @default_sequence [[:C4], [], [:E4], [], [:G4], [], [:B4], []]

  def render(assigns) do
    ~H"""
    <div class="bg-light-gray min-h-screen p-4">
      <div class="text-3xl font-bold mb-8 w-10 h-10 md:w-14 md:h-14 bg-orange rounded-full" />

      <div class="flex justify-center gap-1 md:gap-2 mb-2">
        <%= for step <- 1..length(@sequence) do %>
          <div class="w-10 md:w-14">
            <p class="block font-mono"><%= step %></p>
            <div class="flex">
              <div
                id={"step-#{step}"}
                class={
                  if step == @step,
                    do: "grow m-auto h-2 rounded-full bg-orange",
                    else: "grow m-auto h-2 rounded-full bg-white"
                }
              />
            </div>
          </div>
        <% end %>
      </div>

      <div class="mb-8">
        <%= for note <- [:C4, :D4, :E4, :F4, :G4, :A4, :B4, :C5] do %>
          <div class="flex justify-center space-x-1 md:space-x-2 mb-2 overflow-x-scroll">
            <%= for index <- 0..7 do %>
              <button
                phx-click="update-note"
                phx-value-index={index}
                phx-value-note={note}
                class="w-10 h-10 md:w-14 md:h-14 rounded-md bg-dark-gray"
              >
                <div class={"ml-6 mb-4 md:ml-10 md:mb-6 w-2 h-2 rounded-full " <> background_color(index, note, @sequence)} />
              </button>
            <% end %>
          </div>
        <% end %>
      </div>

      <div class="flex gap-1 md:gap-2 mb-4">
        <div class="bg-orange text-white p-4 rounded-md" phx-click="play"><Icons.play /></div>
        <div class="bg-gray text-white p-4 rounded-md" phx-click="stop"><Icons.pause /></div>
      </div>

      <div class="flex gap-1 md:gap-2 mb-4">
        <.form for={@form} class="flex">
          <input
            type="text"
            name="bpm"
            default={@bpm}
            phx-change="update-bpm"
            phx-debounce="750"
            value={@bpm}
            class="rounded-md flex-grow"
          />
        </.form>
        <div class="bg-gray text-white p-4 rounded-md" phx-click="update-bpm" phx-value-bpm={@bpm - 1}><Icons.minus /></div>
        <div class="bg-gray text-white p-4 rounded-md" phx-click="update-bpm" phx-value-bpm={@bpm + 1}><Icons.plus /></div>
      </div>

      <div class="flex gap-1 md:gap-2 mb-4">
        <p><%= @note_length %></p>
        <div class="bg-orange text-white p-4 rounded-md font-mono" phx-click="note-length-shorten">x2</div>
        <div class="bg-gray text-white p-4 rounded-md font-mono" phx-click="note-length-increase">:2</div>
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
    |> assign(:form, %{"bpm" => @default_bpm})
    |> assign(:sequence, Sequencer.sequence(sequencer))
    |> assign(:note_length, Sequencer.note_length(sequencer))
    |> assign(:step, 1)
    |> assign(:topic, Sequencer.topic(sequencer))
    |> tap(fn socket ->
      # Subscribe to the topic related to the sequencer, so that we can both broadcast updates as well as receive
      # messages related to the changes in the sequencer's state.
      PubSub.subscribe(Seqex.PubSub, socket.assigns.topic)
    end)
    |> then(fn socket -> {:ok, socket} end)
  end

  # Handlers for the PubSub broadcast messages.
  def handle_info({:bpm, bpm}, state), do: {:noreply, assign(state, :bpm, bpm)}
  def handle_info({:sequence, sequence}, state), do: {:noreply, assign(state, :sequence, sequence)}
  def handle_info({:step, step}, state), do: {:noreply, assign(state, :step, step)}

  # Handlers for `phx-click` events.
  def handle_event("update-bpm", %{"bpm" => bpm}, socket) do
    case Integer.parse(bpm) do
      {bpm, ""} when bpm > 0 -> update_bpm(socket, bpm)
      :error -> {:noreply, put_flash(socket, :error, "BPM must be an integer greater than 0.")}
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
end
