defmodule SeqexWeb.Live do
  use Phoenix.LiveView

  require Logger

  alias Seqex.Sequencer
  alias Phoenix.PubSub

  @default_bpm 120

  def render(assigns) do
    ports = Midiex.ports()
    assigns = assign(assigns, :ports, ports)

    ~H"""
    <div class="bg-light-gray min-h-screen p-14">
      <h1 class="text-3xl font-bold mb-14">SeqEx</h1>

      <div class="flex gap-4 mb-4">
        <div class="bg-orange text-white p-4" phx-click="play">Play</div>
        <div class="bg-gray text-white p-4" phx-click="stop">Stop</div>
        <div class="bg-white text-dark-gray p-4"><%= @bpm %></div>
        <div class="bg-gray text-white p-4" phx-click="bpm-dec">-</div>
        <div class="bg-gray text-white p-4" phx-click="bpm-inc">+</div>
      </div>

      <div class="flex gap-4">
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
    # Subscribe to the topic related to the sequencer, so that we can both broadcast updates as well as receive
    # messages related to the changes in the sequencer's state.
    PubSub.subscribe(Seqex.PubSub, "sequencer:update")

    # When mounting, we'll first see if there's already a process with the `Seqex.Sequencer` name, if that's the case
    # then we'll use it's PID instead of starting a new GenServer for the sequencer. This allows us to control the
    # same sequencer, independently of the client that is connecting to the live view.
    case Process.whereis(Seqex.Sequencer) do
      nil ->
        :output
        |> Midiex.ports()
        |> List.first()
        |> Sequencer.start_link(sequence: [:C4, :E4, :G4, :B4], bpm: @default_bpm, name: Seqex.Sequencer)
        |> then(fn {:ok, sequencer} -> assign(socket, :sequencer, sequencer) end)
        |> assign(:bpm, @default_bpm)
        |> then(fn socket -> {:ok, socket} end)

      pid ->
        socket
        |> assign(:sequencer, pid)
        |> assign(:bpm, Sequencer.bpm(pid))
        |> then(fn socket -> {:ok, socket} end)
    end
  end

  def handle_info({:bpm, bpm}, state) do
    IO.puts("Handling message!")
    {:noreply, assign(state, :bpm, bpm)}
  end

  def handle_event("bpm-dec", _unsigned_params, socket) do
    (socket.assigns.bpm - 1)
    |> tap(fn bpm -> PubSub.broadcast_from(Seqex.PubSub, self(), "sequencer:update", {:bpm, bpm}) end)
    |> then(fn bpm -> update_bpm(socket, bpm) end)
  end

  def handle_event("bpm-inc", _unsigned_params, socket) do
    (socket.assigns.bpm + 1)
    |> tap(fn bpm -> PubSub.broadcast_from(Seqex.PubSub, self(), "sequencer:update", {:bpm, bpm}) end)
    |> then(fn bpm -> update_bpm(socket, bpm) end)
  end

  defp update_bpm(socket, bpm) do
    Sequencer.update_bpm(socket.assigns.sequencer, bpm)
    {:noreply, assign(socket, :bpm, bpm)}
  end

  def handle_event("play", _unsigned_params, socket) do
    Sequencer.play(socket.assigns.sequencer)
    {:noreply, socket}
  end

  def handle_event("stop", _unsigned_params, socket) do
    Sequencer.stop(socket.assigns.sequencer)
    {:noreply, socket}
  end
end
