defmodule SeqexWeb.Live do
  use Phoenix.LiveView

  require Logger

  alias Seqex.Sequencer

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
    output_port = Enum.find(Midiex.ports(), fn port -> port.direction == :output end)
    connection = Midiex.open(output_port)
    args = %{sequence: [60, 64, 67, 71], conn: connection, bpm: @default_bpm}

    {:ok, sequencer} = GenServer.start_link(Sequencer, args)

    socket
    |> assign(:sequencer, sequencer)
    |> assign(:bpm, @default_bpm)
    |> then(fn socket -> {:ok, socket} end)
  end

  def handle_event("bpm-dec", _unsigned_params, socket), do: update_bpm(socket, socket.assigns.bpm - 1)
  def handle_event("bpm-inc", _unsigned_params, socket), do: update_bpm(socket, socket.assigns.bpm + 1)

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
