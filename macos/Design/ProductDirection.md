# vvhisper product direction

Confirmed 2026-11-15.

## Purpose and baseline

vvhisper is a general voice interface for macOS. Its core experience is **speak to
write, or speak to get something done**: dictation inserts speech as text, and Computer
Use carries out a task on the Mac.

The Mac’s built-in microphone and keyboard are enough. No dedicated accessory is required
for the baseline experience. Siri Remote is an optional enhancement, and more devices
will provide additional ways to access the same capabilities. Device availability must
not define whether someone can use the core product.

The product name is **vvhisper**, lowercase with an intentional double v.

## Four priorities

These are product priorities, not a committed release schedule.

| Priority | Intended improvement | What success should look like |
|---|---|---|
| General dictation | Improve responsiveness, recognition quality, reliable insertion, and feedback across apps. | A person can dictate using the Mac microphone and keyboard, see whether the app is listening or processing, and get accurate text in the intended field. |
| Faster, easier Computer Use | Reduce the steps and waiting between a spoken instruction and useful action. | Starting a task is easy, progress is understandable, and stopping is immediate and discoverable. |
| More device support | Connect additional input devices to the same dictation and Computer Use capabilities. | Supported accessories enhance convenience without being prerequisites or creating separate versions of the core experience. |
| Product design that fits | Make onboarding, settings, navigation, interaction feedback, and website messaging reflect the broader voice interface. | A new user can start with the Mac alone; adding and configuring a device is an optional path. |

## Implementation direction

Keep input triggers and audio sources separate from the capabilities they invoke.
A keyboard shortcut or supported accessory should be able to start a voice session;
the session’s destination determines whether speech becomes text or a Computer Use task.
This is a design direction for future work, not a claim that the code already has a
complete shared device abstraction.

Keep device-specific requirements inside the corresponding integration. Siri Remote’s
physical Siri-button capture, PacketLogger, Bluetooth, privileged capture helper, and
virtual audio device must not become prerequisites for Mac-microphone dictation. Preserve
the existing remote behavior and generation-specific safeguards while broadening access.

Design the first-run experience around core voice use, with device setup offered as an
optional enhancement. Lead product communication with Dictation and Computer Use; explain
Siri Remote and other supported accessories as ways to make those experiences better.

## Current foundations and remaining work

The current implementation already has:

- A keyboard modifier hotkey for dictation using a Mac microphone, with a microphone picker.
- Dictation engines, streaming Seed ASR, a dictionary, and transcript refinement.
- A Computer Use bar accessible from the menu bar, with keyboard entry and submission.
  A configured dictation hotkey can supply speech to its focused field. Its input appears
  before Dock placement settles.
- Computer Use routes recognized local actions before model-backed work. Jev target decisions
  and the full automation model both use OpenRouter and one Keychain-owned key. See
  [Computer Use routing](ComputerUseRouting.md) for supported scope and validation.
- Siri Remote integrations for both hardware families, including buttons, touch input,
  and the remote microphone bridge.

The current onboarding and some product surfaces remain centered on Siri Remote.
Auto Computer Use currently applies to remote Siri dictation holds, not the keyboard
hotkey. These are existing implementation boundaries, not the desired long-term product
boundary. Additional device integrations, a redesigned first-run flow, and improvements
to dictation and Computer Use remain future work. Do not describe them as implemented or
hardware-verified until the corresponding changes and validation exist.

See [the app README](../README.md) for current controls and setup, and
[AGENTS.md](../../AGENTS.md) for platform and hardware constraints.
