# LN3Couch — Local Couch Co-op for Little Nightmares III

[![Latest release](https://img.shields.io/github/v/release/EugeneErg/LittleNightmares3-LocalCoopMod?label=download)](https://github.com/EugeneErg/LittleNightmares3-LocalCoopMod/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/EugeneErg/LittleNightmares3-LocalCoopMod/total)](https://github.com/EugeneErg/LittleNightmares3-LocalCoopMod/releases)
[![Stars](https://img.shields.io/github/stars/EugeneErg/LittleNightmares3-LocalCoopMod?style=flat)](https://github.com/EugeneErg/LittleNightmares3-LocalCoopMod/stargazers)
[![UE4SS](https://img.shields.io/badge/built%20with-UE4SS-blue)](https://github.com/UE4SS-RE/RE-UE4SS)

**Play Little Nightmares III with two players on one PC — one screen, two gamepads, like *It Takes Two* or *Split Fiction*.**

Little Nightmares III only offers online co-op. LN3Couch lets a second person on the same PC take over Low or Alone with their own controller, with a dynamic split screen that appears only when you need it.

**One game, one Steam account.** No second copy of the game, no second account, no two game windows: the mod adds Player 2 inside a single running game.

[Русская версия](README_RU.md)

<img width="2347" height="1599" alt="image" src="https://github.com/user-attachments/assets/53c32411-0679-4df7-abfb-0f1ffaa50e9a" />

---

## Features

### Two real players
- **Player 2 plays the companion with their own gamepad**, using the game's standard controls. Walk, run, crouch, jump, grab, carry and throw items, push and pull boxes, use the wrench or the bow, climb — everything Player 1 can do.
- **Boosting each other.** At the places where the game has a boost, hold the grab button (RT). Whoever holds it first gives the boost, the other player jumps. Either player can give the boost, and it plays the game's own animations.
- **Enemies hunt both of you.** In the single-player game enemies only catch the player and leave the AI companion alone. With LN3Couch the second hero is a real player, so enemies catch either of you, in normal encounters and in chases.

### Camera and screen
- **Shared screen that frames both players.** When you are together, the game's own camera takes both heroes into account, not just Player 1.
- **Split screen when you need it.** When you are in different rooms, or Player 2 leaves Player 1's view, the screen splits top/bottom (or left/right). Walk back together and it merges again.
- **Room-aware camera for Player 2.** On the split screen, Player 2's camera follows the same per-room rules as the game's camera: set angles, room bounds, smooth transitions.
- **Look around** with the right stick, each player in their own view.
- **Deaths look right.** When someone is caught, both views fade out together and come back at the checkpoint.

### Convenience
- **In-game menu.** A **Co-op** item in the pause menu (or **F9**). Turn Player 2 on or off at any time, settings are saved.
- **Automatic gamepad detection.** Press A on Player 2's controller and the mod finds it.
- **Keeps going through checkpoints, deaths and level changes.** Co-op pauses while loading and resumes on its own.

## Requirements

- Little Nightmares III for PC (Steam), Windows
- **Two gamepads**, one per player (Player 2 can also use the right side of the keyboard)
- Start a regular **single-player** game, not the online co-op mode. The mod hands the AI companion to Player 2.

## Installation

1. Download `LN3Couch_vX.Y.zip` from **[Releases](https://github.com/EugeneErg/LittleNightmares3-LocalCoopMod/releases/latest)**.
2. Open the game folder and go to `SMG031MP\Binaries\Win64` (the folder that contains `LittleNightmaresIII.exe`).
3. Copy the **contents** of the archive's `Win64` folder there: `dwmapi.dll` and the `ue4ss` folder. Replace files if asked.

```text
SMG031MP\Binaries\Win64\
├── LittleNightmaresIII.exe
├── dwmapi.dll        ← from the mod
└── ue4ss\            ← from the mod
```

4. Start the game. A UE4SS console window opens next to it. This is expected.

**To uninstall,** delete `dwmapi.dll` and the `ue4ss` folder.

## How to play

1. Start or load a single-player game.
2. Open the pause menu and select **Co-op**, or press **F9**.
3. Turn on Player 2. The first time, run gamepad detection and press **A** on Player 2's controller.
4. Play. Player 2 uses the game's standard controller layout.

## Settings

Everything is in the in-game **Co-op** menu:

| Option | Values |
|---|---|
| Player 2 | on / off |
| Player 2 controls | gamepad / right side of the keyboard |
| Gamepad #1 belongs to | Player 1 / Player 2 |
| Screen | Auto (split when needed), By distance, Always split, Always shared |
| Layout | Top/bottom, Left/right |
| Split distance | for the "By distance" mode |
| Player 2 buttons | remap Player 2's controls |

Settings are stored in `ue4ss\Mods\LN3Couch\settings.lua`.

## How it works

LN3Couch is a Lua mod running on [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS). It does not change any game files.

```text
Before:  Player 1 ─ PlayerController ─ hero 1
                    AI controller    ─ hero 2 (companion)

After:   Player 1 ─ PlayerController 1 ─ hero 1
         Player 2 ─ PlayerController 2 ─ hero 2   (AI controller suspended)
```

- A second local player is created inside the running game and takes over the companion hero. From then on the game's own input, abilities and interactions work for Player 2.
- Split screen uses the engine's native two-player viewports.
- On the shared screen, Player 2's hero is added to the game camera as a point of interest, so the camera's own logic frames both players.
- Player 2's split-screen camera reproduces the game's room cameras: the hero's position in the room maps to the camera's position, with the designer-set angles and limits.
- For boosts the mod briefly hands the giving hero to the game's AI, which knows how to perform the boost, and gives it back as soon as the boost ends.
- Enemies decide whether to grab by checking the player only. The mod runs the same check for the second player, so they grab whoever they are chasing.

## Compatibility

Tested on the Steam version of Little Nightmares III, October 2026. A game update can change the internals the mod relies on. If the mod stops working after an update, please open an issue.

## Troubleshooting

- **The game does not start or the UE4SS window does not appear.** Check that `dwmapi.dll` and `ue4ss` are directly inside `Win64`, not in `Win64\Win64`.
- **No Co-op item in the pause menu.** You need to be in a loaded game, not the main menu. F9 also works.
- **The wrong gamepad controls Player 2.** In the Co-op menu, run gamepad detection and press A on Player 2's controller, or switch "Gamepad #1 belongs to".
- **Something broke.** Please attach `ue4ss\UE4SS.log`, `ue4ss\Mods\LN3Couch\trail.txt` and, after a crash, the newest folder from `%LOCALAPPDATA%\LittleNightmaresIII\Saved\Crashes`.

## Reporting bugs

[Open an issue](https://github.com/EugeneErg/LittleNightmares3-LocalCoopMod/issues/new/choose) and include what you did, what happened and the log files listed above. Videos help a lot.

## Credits

- **LN3Couch** by [EugeneErg](https://github.com/EugeneErg)
- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS), MIT license (included in `ue4ss/LICENSE`)

## Disclaimer

Unofficial fan-made modification. Not affiliated with or endorsed by Bandai Namco Entertainment or Supermassive Games. Little Nightmares is a trademark of its respective owners. You need a legitimate copy of the game. Use at your own risk.

---

If LN3Couch let you play with someone you love, **⭐ star the repo**. It really helps other people find it.
