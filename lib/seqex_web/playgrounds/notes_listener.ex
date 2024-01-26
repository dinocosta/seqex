defmodule SeqexWeb.Playgrounds.NotesListener do
  @moduledoc """
  LiveView which listens for MIDI messages and displays a list of the notes currently being played.
  """

  use Phoenix.LiveView

  require Logger

  @note_names ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

  def render(assigns) do
    ~H"""
    <div class="bg-[#FF6600] h-screen p-14 grid place-items-center">
      <p class="text-[#0F0A0A] text-8xl">
        <%= for <<note, velocity>> <- Enum.sort_by(@notes, fn <<note, _>> -> note end) do %>
            <span class={"opacity-#{velocity_to_opacity(velocity)}"}><%= note_name(note) %></span>
        <% end %>
        </p>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    # Need to keep track of the LiveView's PID so we can pass it to the MIDI listener handler function.
    live_view = self()

    # Pick the first port with `:direction` set to `:input`, open a connection and start a listener which calls
    # this live view's `handle_cast/2` function when a MIDI message is received.
    :input
    |> Midiex.ports()
    |> List.first()
    |> then(fn port -> Midiex.Listener.start_link(port: port) end)
    |> then(fn {:ok, listener} ->
      Midiex.Listener.add_handler(listener, fn message ->
        GenServer.cast(live_view, {:midi_message, message})
      end)
    end)

    # We're going to keep the list of pressed notes in the socket's `:notes` assigns key.
    socket
    |> assign(notes: [])
    |> then(fn socket -> {:ok, socket} end)
  end

  # MIDI message starts with 144 (1001XXXX) so this is a Note On event.
  # This means we'll remove this note from the list of notes.
  def handle_cast({:midi_message, %Midiex.MidiMessage{data: [144, note, velocity]}}, socket) do
    socket
    |> assign(notes: [<<note, velocity>> | socket.assigns.notes])
    |> then(fn socket -> {:noreply, socket} end)
  end

  # MIDI message starts with 128 (1000XXXX) so this is a Note Off event.
  # This means we'll remove this note from the list of notes.
  def handle_cast({:midi_message, %Midiex.MidiMessage{data: [128, note, _velocity]}}, socket) do
    socket.assigns.notes
    |> Enum.reject(fn <<value, _velocity>> -> value == note end)
    |> then(fn notes -> {:noreply, assign(socket, notes: notes)} end)
  end

  # Given the note's value returns a `String.t()` with the note's name.
  #
  # ## Example
  #
  #   iex> NotesListener.note_name(60)
  #   "C4"
  #   iex> NotesListener.note_name(65)
  #   "F4"
  @spec note_name(integer()) :: String.t()
  defp note_name(note) do
    # Since we know that there's only 12 notes in an octave we can just divide the note's value by 12
    # and subtract 1 (because C0 is note number 12, at least in this implementation), which will
    # give us the range of the note.
    # We then take the remainder and determine the note's name from the @note_indexes list.
    range = div(note, 12) - 1
    name = Enum.at(@note_names, rem(note, 12))

    "#{name}#{range}"
  end

  # Given a note's velocity, will return the hexadecimal code for the alpha channel
  #
  # ## Example
  #
  #  iex> NotesListener.velocity_to_opacity(127)
  #  100
  #  iex> NotesListener.velocity_to_opacity(0)
  #  0
  #
  # Note: By default, the classes supported by Tailwind go from 5 to 5, so `opacity-5`, `opacity-10`, etc.
  # so in this function we have to return a multiple of 5 in order to use existing classes.
  @spec velocity_to_opacity(integer()) :: float()
  defp velocity_to_opacity(velocity) do
    velocity
    |> Kernel.*(100)
    |> div(127)
    |> then(fn value -> value - rem(value, 5) end)
  end
end
