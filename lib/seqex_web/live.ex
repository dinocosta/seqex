defmodule SeqexWeb.Live do
  use Phoenix.LiveView

  require Logger

  alias Phoenix.PubSub
  alias Seqex.Sequencer

  @default_bpm 120
  @default_sequence [:C4, :E4, :G4, :B4]

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
    |> then(fn socket -> {:ok, socket} end)
  end

  def handle_info({:bpm, bpm}, state), do: {:noreply, assign(state, :bpm, bpm)}
  def handle_info({:sequence, sequence}, state), do: {:noreply, assign(state, :sequence, sequence)}

  def handle_event("bpm-dec", _unsigned_params, socket) do
    (socket.assigns.bpm - 1)
    |> tap(fn bpm -> PubSub.broadcast_from(Seqex.PubSub, self(), socket.assigns.topic, {:bpm, bpm}) end)
    |> then(fn bpm -> update_bpm(socket, bpm) end)
  end

  def handle_event("bpm-inc", _unsigned_params, socket) do
    (socket.assigns.bpm + 1)
    |> tap(fn bpm -> PubSub.broadcast_from(Seqex.PubSub, self(), socket.assigns.topic, {:bpm, bpm}) end)
    |> then(fn bpm -> update_bpm(socket, bpm) end)
  end

  def handle_event("sequence-update", params, socket) do
    IO.puts("I GOT CALLEd")
    dbg(params)
    {:noreply, socket}
  end

  def handle_event("play", _unsigned_params, socket) do
    Sequencer.play(socket.assigns.sequencer)
    {:noreply, socket}
  end

  def handle_event("stop", _unsigned_params, socket) do
    Sequencer.stop(socket.assigns.sequencer)
    {:noreply, socket}
  end

  defp update_bpm(socket, bpm) do
    Sequencer.update_bpm(socket.assigns.sequencer, bpm)
    {:noreply, assign(socket, :bpm, bpm)}
  end
end
