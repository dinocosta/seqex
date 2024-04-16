defmodule SeqexWeb.Playgrounds.NotesListenerGrid do
  @moduledoc """
  LiveView which listens for MIDI messages and displays a list of the notes currently being played in a grid.
  """

  use Phoenix.LiveView

  require Logger

  def render(assigns) do
    ~H"""
    <div class="bg-zinc-900 h-screen grid items-center justify-items-center">
      <%= for octave <-  0..7  do %>
        <div class="grid grid-rows-12 grid-flow-col">
          <%= for note <- 1..12 do %>
            <div class={"#{opacity(@notes, note + (12 * octave))} bg-orange rounded-full h-24 w-24 cell"}></div>
          <% end %>
        </div>
      <% end %>
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

  # MIDI message starts with 144 (10010000) so this is a Note On event on channel 1.
  # This means we'll remove this note from the list of notes.
  def handle_cast({:midi_message, %Midiex.MidiMessage{data: [144, _note, velocity]}}, socket) do
    socket
    |> assign(notes: [<<:rand.uniform(72), velocity>> | socket.assigns.notes])
    |> then(fn socket -> {:noreply, socket} end)
  end

  # MIDI message starts with 128 (10000000) so this is a Note Off event on channel 1.
  # This means we'll remove this note from the list of notes.
  def handle_cast({:midi_message, %Midiex.MidiMessage{data: [128, _note, _velocity]}}, socket) do
    socket.assigns.notes
    |> tl()
    |> then(fn notes -> {:noreply, assign(socket, notes: notes)} end)
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

  defp opacity(notes, cell_value) do
    case Enum.find(notes, fn <<value, _>> -> value == cell_value end) do
      nil -> "opacity-0"
      <<_value, velocity>> -> "opacity-#{velocity_to_opacity(velocity)}"
    end
  end
end
