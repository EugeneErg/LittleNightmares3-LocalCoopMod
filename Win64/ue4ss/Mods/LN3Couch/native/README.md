# ln3couch_tw.dll

Native helper for the LN3Couch mod: the doll's halo (the second world) in split screen.
The Lua mod loads it with `package.loadlib` from `Scripts/main.lua` and talks to it
through the `SphereMarginConstant` of the game's main second-world capture.
If the file is missing, or `two_worlds_native = false` is set in `settings.lua`,
the mod works as before without it.

What it does (details in the comments of `ln3couch_tw.c`):

- composites the second world only into the first split view (the game's halo
  shader works correctly only there);
- on request, swaps where the two finished halves are shown on screen, so the
  doll holder is rendered first but shown on their own side.

It finds the game functions by byte signatures at startup and writes what it did
to `ln3couch_tw.log` next to itself. If a game update changes the code, it logs
an error and does nothing.

## Build

MinGW-w64 (x86_64), from this folder:

```
x86_64-w64-mingw32-gcc -O2 -shared -Wall -o ln3couch_tw.dll ln3couch_tw.c -static-libgcc
```

---

Вспомогательная библиотека мода LN3Couch: ореол куклы (второй мир) в
разделённом экране. Мод на Lua загружает её через `package.loadlib` и передаёт
ей указания меткой `SphereMarginConstant` основной съёмки второго мира. Нет
файла или в `settings.lua` стоит `two_worlds_native = false` — мод работает без
неё, как раньше. Сборка — командой выше (MinGW-w64). Что сделала — пишет в
`ln3couch_tw.log` рядом с собой.
