# SeqEX
### Elixir MIDI Sequencer

---
# MIDI
---
# MIDI Messages
Technical details on how MIDI messages are built (8 bytes) and what each byte means.
---
# MIDI Messages
### Note On
Explain the Note On MIDI message, status byte, note and velocity.
---
# MIDI Messages
### Note Off
Explain the Note Off MIDI message, status byte, note and velocity (unused).
--- 
# Sequencer
Explain how the Sequencer is a `GenServer` implementation, maybe showing what state it keeps (or maybe just mention the different state fields as we present other details).
---
# Sequencer
### Note Duration
Go into detail on how the sequencer uses `Process.send_after/3` in order to trigger the next note (or notes) in the sequencer after a specified amount of time.
---
# Sequencer
### PubSub
Explain how the Sequencer uses Phoenix.PubSub in order to broadcast updates to its state to any subscribers. Mention the usage of both `Phoenix.PubSub.broadcast/3` as well as `Phoenix.PubSub.broadcast_from/4`.
---
# LiveView
Technical details into how the LiveView is built.
---
# LiveView
### PubSub
Explain how the LiveView implementation leverages `PubSub.subscribe/2` in order to receive update messages from the sequencer.
---
# LiveView
### Mount
Mention that, if the sequencer is already running, since we start the link with a named `GenServer`, the `mount/3` function tries to find that sequencer first, before starting a new one.
---
# LiveView
### Events
Mention how the LiveView handles updating BPM and sequence.