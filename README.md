# LN3Couch — Local Couch Co-op for Little Nightmares III

[![Latest release](https://img.shields.io/github/v/release/EugeneErg/LittleNightmares3-LocalCoopMod?label=download)](https://github.com/EugeneErg/LittleNightmares3-LocalCoopMod/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/EugeneErg/LittleNightmares3-LocalCoopMod/total)](https://github.com/EugeneErg/LittleNightmares3-LocalCoopMod/releases)
[![Stars](https://img.shields.io/github/stars/EugeneErg/LittleNightmares3-LocalCoopMod?style=flat)](https://github.com/EugeneErg/LittleNightmares3-LocalCoopMod/stargazers)
[![UE4SS](https://img.shields.io/badge/built%20with-UE4SS-blue)](https://github.com/UE4SS-RE/RE-UE4SS)

**Play Little Nightmares III with two players on one PC — one screen, two gamepads, like *It Takes Two* or *Split Fiction*.**

Little Nightmares III only offers online co-op. LN3Couch lets a second person on the same PC take over Low or Alone with their own controller, with a dynamic split screen that appears only when you need it.

[Русская версия](README_RU.md)

<img width="2347" height="1599" alt="image" src="https://github.com/user-attachments/assets/53c32411-0679-4df7-abfb-0f1ffaa50e9a" />

---

## Features

- **Real second player.** Player 2 controls the companion with their own gamepad exactly like Player 1: walk, run, crouch, jump, grab, carry and throw items, push and pull boxes, use the wrench or the bow, climb. All of it is the game's own controls, not an imitation.
- **Dynamic split screen.** You share one screen while both heroes are in view. When the companion leaves Player 1's frame, the screen splits top/bottom (or left/right). When you come back together, it merges again.
- **Room-aware camera for Player 2.** Player 2's camera follows the same per-room camera rules the game uses for Player 1: set angles, room bounds, smooth transitions between rooms.
- **Look around.** Each player looks around with the right stick when the screen is split. When it is shared, both can.
- **In-game menu.** A **Co-op** item is added to the game's pause menu (or press **F9**). Turn co-op on or off at any time. Settings are saved.
- **Automatic gamepad detection.** Press A on Player 2's controller and the mod finds it.
- **Survives checkpoints, deaths and level changes.** Co-op pauses during loading and resumes on its own.

## Requirements

- Little Nightmares III for PC (Steam), Windows
- **Two gamepads**, one per player
- Start a regular **single-player** game, not the online co-op mode. The mod hands the AI companion to Player 2.

## Installation

1. Download `LN3Couch_vX.Y.zip` from **[Releases](https://github.com/EugeneErg/LittleNightmares3-LocalCoopMod/releases/latest)**.
2. Open the game folder and go to `SMG031MP\Binaries\Win64` (the folder that contains `LittleNightmaresIII.exe`).
3. Copy the **contents** of the archive's `Win64` folder there: `dwmapi.dll` and the `ue4ss` folder.

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
3. Turn on Player 2. The first time, press **A** on Player 2's controller so the mod can find it.
4. Play. Player 2 uses the game's standard controller layout.

## Settings

Everything is in the in-game **Co-op** menu:

| Option | Values |
|---|---|
| Player 2 | on / off |
| Split screen | Auto (when the companion is off-screen), By distance, Always, Never |
| Layout | Top/bottom, Left/right |
| Player 2 gamepad | auto-detect |

Settings are stored in `ue4ss\Mods\LN3Couch\settings.lua`.

## How it works

LN3Couch is a Lua mod running on [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS).

```text
Before:  Player 1 ─ PlayerController ─ hero 1
                    AI controller    ─ hero 2 (companion)

After:   Player 1 ─ PlayerController 1 ─ hero 1
         Player 2 ─ PlayerController 2 ─ hero 2   (AI controller suspended)
```

- A second local player is created (`CreatePlayer`) and gets the companion hero. The game's own input, abilities and interactions then work for Player 2 natively.
- The companion's AI controller is fully suspended while Player 2 owns the hero, and restored when co-op is turned off.
- The game keeps an internal character registry that grows every time a hero changes controller and is only cleaned up when the hero is destroyed. Left as is, this crashes the game after the next death. LN3Couch undoes the extra entry right after each hand-over.
- Split screen uses the engine's native two-player viewports. The mod decides when to split by projecting the companion into Player 1's view.
- Player 2's view uses a separate camera that reproduces the game's "dollhouse" room cameras: the hero's position in the room's player volume maps to the camera's position in its camera volume, with the designer-set angle and follow limits.
- Audio stays with Player 1's camera, so room ambience keeps playing when Player 2 joins.

## Compatibility

Tested on the Steam version of Little Nightmares III, October 2026. A game update can change the internals the mod relies on. If the mod stops working after an update, please open an issue.

## Troubleshooting

- **The game does not start or the UE4SS window does not appear.** Check that `dwmapi.dll` and `ue4ss` are directly inside `Win64`, not in `Win64\Win64`.
- **No Co-op item in the pause menu.** You need to be in a loaded game, not the main menu. F9 also works.
- **The wrong gamepad controls Player 2.** In the Co-op menu, run gamepad detection and press A on Player 2's controller.
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
