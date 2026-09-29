# Little Nightmares III — Local Co-op Mod

**LN3Couch** adds local two-player co-op to **Little Nightmares III**, allowing two players to play together on the same PC.

> **Note:** This is a community-made mod and is not affiliated with or endorsed by Bandai Namco Entertainment or Supermassive Games.

## Features

* Local co-op for **2 players on one PC**
* Play together in the same game session
* Second player can be enabled directly from the in-game pause menu
* Quick toggle for Player 2 with **F9**
* Player 2 can use:

    * Keyboard
    * Gamepad / controller
* Configurable Player 2 controls
* Powered by **UE4SS**

## Requirements

* PC version of **Little Nightmares III**
* Windows
* A game version compatible with the current mod build
* A controller is recommended for Player 2 when Player 1 is using the keyboard

## Installation

1. Open the Little Nightmares III installation directory.

2. Navigate to:

   ```text
   SMG031MP\Binaries\Win64
   ```

   This is the directory containing:

   ```text
   LittleNightmaresIII.exe
   ```

3. Download the latest version of this mod from the repository.

4. Open the `Win64` folder from the downloaded mod.

5. Copy its **contents** into the game's `Win64` directory.

   The resulting structure should contain:

   ```text
   SMG031MP\
   └── Binaries\
       └── Win64\
           ├── LittleNightmaresIII.exe
           ├── dwmapi.dll
           └── ue4ss\
   ```

6. Start the game.

7. A UE4SS console/window may appear next to the game. This is expected.

## How to Play

1. Start a normal **single-player game**.
2. Once you are in the game, open the pause menu with `Esc`.
3. Select **Co-op**.
4. Enable Player 2 and configure the controls.

### Quick Start

You can enable Player 2 during gameplay by pressing:

```text
F9
```

## Player 2 — Default Keyboard Controls

| Action          | Key         |
| --------------- | ----------- |
| Move            | Arrow keys  |
| Jump            | Enter       |
| Grab / interact | Right Shift |
| Crouch          | Right Ctrl  |
| Run             | `/`         |

The controls can be changed through the co-op settings.

## Controller

Player 2 can also use a gamepad/controller.

For the best local co-op experience, a recommended setup is:

* **Player 1:** keyboard/mouse or primary controller
* **Player 2:** separate controller

Controller support and available bindings may depend on the current mod version and game configuration.

## How It Works

LN3Couch runs inside the game using **UE4SS**.

The mod starts with the normal single-player game and adds local Player 2 functionality to the running game session. It does **not** require a second copy of the game to be launched.

This is a **local co-op modification**, not an implementation of Little Nightmares III's official online multiplayer.

## Important

This mod modifies the game at runtime. Because Little Nightmares III was not originally designed to provide this exact local co-op configuration, unexpected behaviour may occur.

The mod is under active development.

If you encounter a problem, please provide:

* Game version
* Mod version
* Description of the problem
* Steps required to reproduce it
* Whether Player 2 uses keyboard or controller
* Screenshot or video, if possible
* `UE4SS` log, if relevant

This information makes debugging substantially easier.

## Troubleshooting

### The game does not start

Check that:

1. `dwmapi.dll` is located directly in:

   ```text
   SMG031MP\Binaries\Win64
   ```

2. The `ue4ss` folder is also directly inside `Win64`.

3. You did not accidentally copy the entire downloaded `Win64` folder as a nested folder.

Correct:

```text
Win64\
├── dwmapi.dll
└── ue4ss\
```

Incorrect:

```text
Win64\
└── Win64\
    ├── dwmapi.dll
    └── ue4ss\
```

### The Co-op option does not appear

Make sure that:

* UE4SS is loading correctly.
* The mod files were copied to the correct `Win64` directory.
* You started a game rather than remaining on the main menu.
* You are using a supported game/mod version.

You can also try pressing:

```text
F9
```

while actively playing.

### Player 2 does not respond

Check the Player 2 control settings and verify that the selected keyboard/controller is recognized by Windows and the game.

If using a controller, disconnect other controllers temporarily and test again.

## Removing the Mod

To remove LN3Couch, delete:

```text
SMG031MP\Binaries\Win64\dwmapi.dll
```

and the:

```text
SMG031MP\Binaries\Win64\ue4ss
```

folder.

No original game files should need to be permanently modified.

## Compatibility

| Component                  | Status        |
| -------------------------- | ------------- |
| Little Nightmares III — PC | Supported     |
| Local 2-player co-op       | Supported     |
| Player 2 keyboard          | Supported     |
| Player 2 controller        | Supported     |
| Official online co-op      | Not modified  |
| Console versions           | Not supported |

> Compatibility may change between game updates. If a new game update breaks the mod, wait for an updated mod version or report the issue.

## Known Limitations

The mod is an ongoing project. Some game mechanics may behave differently with two local players because the original game was designed around its existing player/online-co-op architecture.

If you discover a reproducible limitation, please report it in the repository so it can be documented here.

## FAQ

### Is this official?

No. LN3Couch is a community-made modification.

### Does it add local split-screen?

The mod enables two players to play locally on the same PC. The exact camera/display behaviour depends on the current implementation.

### Do I need two copies of the game?

No. The mod operates within a single running game.

### Can both players use controllers?

Player 2 supports a controller. The exact controller configuration should be checked in the current mod version.

### Can I use a keyboard for both players?

Player 2 has its own default keyboard bindings, so a second player can use the keyboard. However, a separate controller is recommended for a more comfortable setup.

### Does this replace online co-op?

No. The mod is intended to add a local play option; it does not replace the game's official online multiplayer.

### Will the mod work after every game update?

Not necessarily. Game updates can change internal structures used by UE4SS mods.

If the game receives an update, check this repository for a compatible version.

## Reporting Bugs

Please open an issue on GitHub and include:

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

Attach screenshots, videos, and relevant UE4SS logs when possible.

## Credits

Created by **EugeneErg**.

Built using **UE4SS**.

Thanks to the Little Nightmares modding community and everyone testing the local co-op implementation.

## Disclaimer

Little Nightmares III and its associated trademarks are the property of their respective owners.

This project is an unofficial fan-made modification and is provided independently of the game's developers and publisher.

Use the mod at your own risk and keep backups of important save data.

## License

See the repository license for the terms applicable to this project.
