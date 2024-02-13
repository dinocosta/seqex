defmodule SeqexWeb.LivePlayPause do
  @moduledoc """
  Short example showing how to leverage LiveView, Agents and PubSub to
  have any client play or pause a sequencer.
  """

  use Phoenix.LiveView

  alias Seqex.Sequencer
  alias Phoenix.PubSub

  def render(assigns) do
    ~H"""
    <div class="p-4 font-sans">
      <h1 class="text-xl mb-4">Play & Pause</h1>

      <h2 class="text-lg mb-2">State</h2>
      <p class="mb-4"><%= @playing? %></p>

      <h2 class="text-lg mb-2">Controls</h2>
      <div class="flex space-x-2">
        <button phx-click="play" class="rounded-md p-2 bg-orange-500">Play</button>
        <button phx-click="pause" class="rounded-md p-2 bg-slate-300">Pause</button>
      </div>
    </div>
    """
  end

  def mount(params, session, socket) do
    # Checks if the sequencer process already exists, if it doesn't then it starts up the sequencer, otherwise
    # just fetch its PID and fetch state.
    sequencer =
      case Process.whereis(:sequencer) do
        nil ->
          output_port = Enum.find(Midiex.ports(), fn port -> port.direction == :output end)
          connection = Midiex.open(output_port)
          sequence = [60, 64, 67, 71]

          {:ok, sequencer} =
            GenServer.start_link(Seqex.Sequencer, %{sequence: sequence, conn: connection},
              name: :sequencer
            )

          sequencer

        pid ->
          pid
      end

    # Subscribe to events related to the sequencer.
    PubSub.subscribe(Seqex.PubSub, "sequencer")

    state = Sequencer.playing?(sequencer)

    socket
    |> assign(:playing?, state)
    |> assign(:sequencer, sequencer)
    |> then(fn socket -> {:ok, socket} end)
  end

  def handle_event("play", unsigned_params, socket) do
    Seqex.Sequencer.play(socket.assigns.sequencer)
    PubSub.broadcast(Seqex.PubSub, "sequencer", %{playing?: true})
    {:noreply, assign(socket, :playing?, true)}
  end

  def handle_event("pause", unsigned_params, socket) do
    Seqex.Sequencer.stop(socket.assigns.sequencer)
    PubSub.broadcast(Seqex.PubSub, "sequencer", %{playing?: false})
    {:noreply, assign(socket, :playing?, false)}
  end

  def handle_info(%{playing?: state}, socket), do: {:noreply, assign(socket, :playing?, state)}
end
