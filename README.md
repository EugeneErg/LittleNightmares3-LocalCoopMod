# LN3Couch — Local Co-op for Little Nightmares III

<p align="center">

**Play Little Nightmares III locally with two players on one PC.**

Keyboard + Controller • Dynamic Split-Screen • Same Game Session

</p>

> **LN3Couch** is an unofficial community-made mod that adds local two-player co-op to **Little Nightmares III**.

---

## Features

* **2-player local co-op** on a single PC
* No second copy of the game required
* Player 2 can use a **keyboard or controller**
* Player 1 and Player 2 can use different input devices
* **Dynamic split-screen**
* Automatic switching between shared camera and split-screen
* Manual split-screen modes
* In-game co-op settings menu
* Configurable Player 2 controls
* Settings are saved between launches
* Co-op can be enabled/disabled during gameplay
* Integrated **Co-op** button in the game's pause menu
* Built with **UE4SS**

---

## How It Works

Little Nightmares III already contains systems for controlling the second character.

LN3Couch uses those existing systems instead of creating a completely separate multiplayer implementation.

When local co-op is enabled:

```text
Player 1
   │
PlayerController
   │
Player 1 Pawn


Player 2
   │
AI Controller
   │
Player 2 Pawn
```

The AI controller of Player 2 is temporarily disabled and LN3Couch feeds it local input from the second player.

This allows the existing Player 2 character, animations and gameplay systems to continue being used by the game.

A second Unreal `PlayerController` is also created when needed for the second viewport/camera.

---

## Dynamic Split-Screen

LN3Couch does not force split-screen to remain enabled at all times.

The mod can automatically determine whether both characters can be displayed on the same screen.

### Auto mode

When the players are close enough:

```text
┌──────────────────────────────┐
│                              │
│       P1          P2         │
│                              │
│       Shared Camera          │
│                              │
└──────────────────────────────┘
```

When the players move too far apart:

```text
┌───────────────┬───────────────┐
│               │               │
│      P1       │       P2      │
│               │               │
│    Camera 1   │    Camera 2   │
│               │               │
└───────────────┴───────────────┘
```

When the players come back together, the mod can return to the shared camera.

The system uses separate thresholds for entering and leaving split-screen to prevent rapid switching when players are near the boundary.

---

## Split-Screen Modes

The mod supports several modes:

| Mode       | Description                                                   |
| ---------- | ------------------------------------------------------------- |
| `Auto`     | Automatically switches between shared camera and split-screen |
| `Distance` | Uses player distance to control split-screen                  |
| `Always`   | Always use split-screen                                       |
| `Never`    | Never use split-screen                                        |

The automatic system primarily uses screen-space visibility and can fall back to distance-based detection when necessary.

---

## Player 2 Controls

### Default keyboard controls

| Action          | Key         |
| --------------- | ----------- |
| Move            | Arrow Keys  |
| Jump            | Enter       |
| Grab / Interact | Right Shift |
| Crouch          | Right Ctrl  |
| Sprint          | `/`         |

The controls can be changed from the in-game LN3Couch menu.

### Controller

Player 2 can use a separate gamepad.

Supported inputs include:

* Left stick
* Right stick
* A
* B
* LT
* RT

A configurable stick deadzone is provided.

---

# Installation

## Requirements

* **Little Nightmares III — PC version**
* Windows
* A compatible version of the game
* UE4SS files included with the mod

## Install

1. Download the latest release from the **Releases** section.

2. Open the game directory.

3. Navigate to:

```text
SMG031MP\Binaries\Win64
```

4. Copy the contents of the mod's `Win64` folder into the game's `Win64` folder.

The resulting structure should look similar to:

```text
SMG031MP\
└── Binaries\
    └── Win64\
        ├── LittleNightmaresIII.exe
        ├── dwmapi.dll
        └── ue4ss\
```

5. Start Little Nightmares III.

6. Start or load a game.

7. Open the pause menu and select **Co-op**.

You can also use:

```text
F9
```

to open the LN3Couch menu.

---

# Quick Start

The fastest way to test the mod:

1. Launch the game.
2. Start a game.
3. Press **F9**.
4. Enable Player 2.
5. Connect/configure Player 2's controller or keyboard.
6. Start playing.

---

# In-Game Menu

LN3Couch provides its own configuration menu.

Available options include:

* Enable/disable Player 2
* Player 2 input configuration
* Split-screen mode
* Split-screen distance
* Keyboard bindings
* Controller configuration
* Reset settings

The mod also adds a **Co-op** entry directly to the game's pause menu.

---

# Configuration

Settings are saved to:

```text
ue4ss\Mods\LN3Couch\settings.lua
```

This means your configuration can persist between game launches.

---

# Technical Overview

LN3Couch is implemented as a Lua mod running through **UE4SS**.

The mod uses several existing Little Nightmares III systems rather than replacing the game's player architecture.

### Player 2

The existing `KosmosAIController` and second hero Pawn are located at runtime.

The mod identifies the second character using the game's existing classes, including:

```text
BP_Low_C
BP_Alone_C
```

The AI controller is then temporarily stopped while local input is supplied by LN3Couch.

Conceptually:

```text
Game's existing Player 2
          │
          ▼
   KosmosAIController
          │
       AI stopped
          │
          ▼
     LN3Couch Input
          │
          ▼
       Player 2
```

This allows the mod to reuse existing movement, interaction and character functionality.

---

## Second Player Camera

The second viewport uses an additional camera actor.

The camera follows Player 2 while maintaining an offset derived from the main player's camera.

This allows the second player to have an independent view without replacing the game's existing camera system.

The mod can dynamically enable or disable the second viewport depending on the selected split-screen mode.

---

## Second PlayerController

When local co-op is enabled, LN3Couch creates an additional Unreal `PlayerController` for the second local viewport.

The controller is not used as the primary owner of Player 2's Pawn.

Instead:

```text
PlayerController 1
        │
        └── Player 1

AI Controller
        │
        └── Player 2

PlayerController 2
        │
        └── Secondary viewport / camera
```

This approach allows the existing Player 2 gameplay logic to remain intact.

---

# Compatibility

| Feature                 | Status        |
| ----------------------- | ------------- |
| PC                      | Supported     |
| 2 local players         | Supported     |
| Keyboard + Keyboard     | Supported     |
| Keyboard + Controller   | Supported     |
| Controller for Player 2 | Supported     |
| Dynamic split-screen    | Supported     |
| Shared camera mode      | Supported     |
| Official online co-op   | Not modified  |
| Console versions        | Not supported |

Compatibility may change after Little Nightmares III updates.

Game updates can change internal Unreal classes, functions or UI structures used by the mod.

---

# Known Limitations

LN3Couch is an ongoing project.

Because Little Nightmares III was not originally designed specifically for this local configuration, some situations may behave differently from the official game.

Potential areas affected by future game updates include:

* Player Controller creation
* Camera systems
* Pause menu UI
* Player/AI classes
* Input handling
* Level transitions
* Respawn/checkpoint behaviour

If you encounter a reproducible problem, please report it.

---

# Troubleshooting

## The game does not start

Verify that:

```text
dwmapi.dll
```

is directly inside:

```text
SMG031MP\Binaries\Win64
```

and that:

```text
ue4ss
```

is also directly inside `Win64`.

### Correct

```text
Win64\
├── dwmapi.dll
└── ue4ss\
```

### Incorrect

```text
Win64\
└── Win64\
    ├── dwmapi.dll
    └── ue4ss\
```

---

## Co-op does not appear

Try the following:

1. Start an actual game session.
2. Press `F9`.
3. Check that UE4SS loaded correctly.
4. Verify that the mod files are in the correct directory.
5. Verify game/mod compatibility.

---

## Player 2 does not respond

Check:

* Player 2 key bindings
* Controller connection
* Controller assignment
* Whether another controller is interfering with input

For controller problems, try temporarily disconnecting other controllers.

---

# Reporting Bugs

Before opening an issue, please provide:

```text
Game version:
Mod version:
Windows version:

Player 1 input:
Player 2 input:

Description:

Steps to reproduce:

Expected behaviour:

Actual behaviour:
```

Screenshots, videos and UE4SS logs are highly appreciated.

---

# Development

The project is open to contributions, testing and bug reports.

If you are familiar with:

* Unreal Engine
* UE4SS
* Lua
* Unreal Blueprint internals
* Local multiplayer
* Camera systems

you are welcome to contribute improvements or report technical findings.

---

# Roadmap

Possible future improvements may include:

* Additional controller/input options
* Improved camera behaviour
* More robust level-transition handling
* Better compatibility with future game updates
* Additional configuration options
* Improved split-screen behaviour
* More extensive testing across game versions

The roadmap may change as the mod develops.

---

# Credits

**LN3Couch**
Created by **EugeneErg**

Built using **UE4SS**.

Thanks to everyone testing the mod and contributing feedback.

---

# Disclaimer

Little Nightmares III and all associated trademarks are property of their respective owners.

LN3Couch is an unofficial community modification and is not affiliated with, endorsed by, or supported by Bandai Namco Entertainment or Supermassive Games.

Use the modification at your own risk.

---

## ⭐ Support the Project

If LN3Couch helps you play Little Nightmares III locally with friends:

**Star the repository on GitHub.**

Stars, bug reports, feedback and contributions help the project grow and make future development easier.
