-- ============================================================
--  LN3Couch — настройки ПО УМОЛЧАНИЮ.
--  Обычно их менять не нужно: всё настраивается в игре через меню (F9).
--  То, что вы выберете в меню, сохраняется в settings.lua рядом.
-- ============================================================
return {
  -- Чем управляет игрок 2: "keyboard" (правая часть клавиатуры) или "gamepad"
  device = "gamepad",

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
    crouch = "Gamepad_LeftTrigger",         -- LT / L2 (держать)
    weapon = "Gamepad_FaceButton_Right",    -- B / круг: достать/убрать ключ или лук
    throw  = "Gamepad_RightShoulder",       -- RB / R1
    sprint = "Gamepad_FaceButton_Left",     -- X / квадрат (держать)
    deadzone = 0.2,
  },
  -- true: геймпад №1 — у игрока 2 (игрок 1 на клавиатуре)
  -- false: геймпад №1 — у игрока 1, геймпад №2 — у игрока 2
  gamepad_goes_to_player2 = false,

  -- Экран делится сам: когда герои в разных комнатах или напарник ушёл из кадра.
  -- Как делить: "auto" — по тому, где стоят герои (слева/справа или сверху/снизу),
  -- "top_bottom" — всегда сверху и снизу. Меняется в меню: «Разделение».
  split_sides = "auto",
  -- Игра вдвоём: запоминается выбор из меню; true — второй игрок подключится сам
  coop_enabled = false,
  language = "auto",         -- язык меню мода: "auto" (как в игре), "ru" или "en"

  -- Если направления перепутаны
  swap_axes = false, invert_forward = false, invert_right = false,
}
