# Seqex

To start your Phoenix server:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

  * Official website: https://www.phoenixframework.org/
  * Guides: https://hexdocs.pm/phoenix/overview.html
  * Docs: https://hexdocs.pm/phoenix
  * Forum: https://elixirforum.com/c/phoenix-forum
  * Source: https://github.com/phoenixframework/phoenix

## Listening To MIDI Messages

[Midiex](https://github.com/haubie/midiex) allows MIDI messages to be processesd from input ports.
You can use `Midiex.Listener` to do this, defining handler functions to process the messages:

```elixir
# 1. Define the input port you want to listen to.
input_port = Enum.find(Midiex.ports(), fn port -> port.direction == :input end)

# 2. Create a listener.
{:ok, listener} = Midiex.Listener.start_link(input_port: input_port)

# 3. Define a handler function.
Midiex.Listener.add_handler(listener, fn message -> IO.inspect(message) end)
```

As far as I can tell the handler can be any function so you could use the notes from the MIDI
message to control anything you want to.
