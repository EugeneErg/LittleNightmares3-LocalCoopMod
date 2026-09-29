-- ============================================================
--  LN3Couch — настройки ПО УМОЛЧАНИЮ.
--  Обычно их менять не нужно: всё настраивается в игре через меню (F9).
--  То, что вы выберете в меню, сохраняется в settings.lua рядом.
-- ============================================================
return {
  -- Чем управляет игрок 2: "keyboard" (правая часть клавиатуры) или "gamepad"
  device = "keyboard",

  -- Клавиши игрока 2 для device = "keyboard".
  -- Названия клавиш — как в Unreal: Up, Down, Left, Right, Enter, RightShift,
  -- RightControl, Slash, Period, Comma, End, PageDown, NumPadZero ... NumPadNine
  keyboard = {
    up = "Up", down = "Down", left = "Left", right = "Right",
    jump   = "Enter",
    grab   = "RightShift",    -- держать
    crouch = "RightControl",  -- держать
    sprint = "Slash",         -- держать ( клавиша / )
  },

  -- Кнопки игрока 2 для device = "gamepad"
  gamepad = {
    jump   = "Gamepad_FaceButton_Bottom",   -- A / крест
    grab   = "Gamepad_RightTrigger",        -- RT / R2 (держать)
    crouch = "Gamepad_FaceButton_Right",    -- B / круг (держать)
    sprint = "Gamepad_LeftTrigger",         -- LT / L2 (держать)
    deadzone = 0.2,
  },
  -- true: геймпад №1 — у игрока 2 (игрок 1 на клавиатуре)
  -- false: геймпад №1 — у игрока 1, геймпад №2 — у игрока 2
  gamepad_goes_to_player2 = true,

  -- Разделение экрана: "auto" (когда герои далеко), "always", "never"
  split = "auto",
  split_on_distance  = 900,   -- разделить, если дальше (в сантиметрах игры)
  -- расположение: "top_bottom" (сверху и снизу) или "left_right"
  split_layout = "top_bottom",

  -- Если направления перепутаны
  swap_axes = false, invert_forward = false, invert_right = false,
}
