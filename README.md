# SeqEx

SeqEx is a simple MIDI sequencer written in Elixir. It leverages [midiex](https://hex.pm/packages/midiex) as well
as the [Phoenix LiveView](https://hex.pm/packages/phoenix_live_view) to create a sequencer you can use on the browser,
as well as enable other poeple to control it.

- [Installation](#installation)
- [Usage](#usage)

## Installation

1. Clone this project.
2. Run `mix deps.get` on the repository's root.
3. Run `mix phx.server` to start the server, you should now be able to access `http://localhost:4000` on your browser.

## Usage

### Sequencer

If you wish to use the sequencer, you can access it through the `Seqex.Sequencer` module, for example:

```elixir
alias Seqex.Sequencer

sequence = [:C3, :E3, :G3, :E3]
bpm = 120

# 1. Fetch MIDI output port where we are sending messages to.
[output_port] = :output |> Midiex.ports() |> List.first()

# 2. Start sequencer's GenServer.
{:ok, sequencer} = Sequencer.start_link(output_port, sequence: sequence, bpm: bpm)

# 3. Play the sequencer.
Sequencer.play(sequencer)
```

Feel free to read the module's documentation, as well as the function's documentation to better understand its
capabilities.

### Live Views

There's 3 live routes available in the project:

- `/sequencer` – This is the UI for the sequencer, which allows you to set the sequence, tempo, note length, etc.
- `/playground/notes-listener` – Simple app that listens to MIDI messages and displays the notes being played.
- `/playground/notes-listener-grid` – Simple app that listens to MIDI messages and displays the notes being played as
  dots in a grid.
