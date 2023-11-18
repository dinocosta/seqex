defmodule SeqexWeb.Live do
  use Phoenix.LiveView

  def render(assigns) do
    ports = Midiex.ports()
    assigns = assign(assigns, :ports, ports)

    ~H"""
    <h1>Ports</h1>
    <ul>
      <%= for port <- @ports do %>
        <li><%= port.name %> (<%= String.upcase(Atom.to_string(port.direction)) %>)</li>
      <% end %>
    </ul>

    <button phx-click="refresh_ports">Refresh</button>
    """
  end

  def handle_event("refresh_ports", _tuple, socket) do
    ports = Midiex.ports()
    {:noreply, assign(socket, :ports, ports)}
  end
end
