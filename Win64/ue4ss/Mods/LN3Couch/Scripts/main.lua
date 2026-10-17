-- LN3Couch v9.15.9 — игра вдвоём на одном ПК для Little Nightmares III
-- F9 — меню кооператива (всё включается и настраивается там)
local UEHelpers = require("UEHelpers")

------------------------------------------------------------------ утилиты
-- «след» действий: короткий файл, который пишется сразу на диск, чтобы
-- после вылета было видно, что мод делал последним
local TRAIL = { f = nil, n = 0 }
local function trail(line)
  if not TRAIL.f then
    -- запись прошлого запуска сохраняем в trail_prev.txt (после вылета её
    -- иначе затирает следующий запуск)
    pcall(function() os.remove("ue4ss/Mods/LN3Couch/trail_prev.txt"); os.rename("ue4ss/Mods/LN3Couch/trail.txt", "ue4ss/Mods/LN3Couch/trail_prev.txt") end)
    TRAIL.f = io.open("ue4ss/Mods/LN3Couch/trail.txt", "w")
  end
  if not TRAIL.f then return end
  TRAIL.n = TRAIL.n + 1
  if TRAIL.n > 40000 then TRAIL.f:close(); TRAIL.f = io.open("ue4ss/Mods/LN3Couch/trail.txt", "w"); TRAIL.n = 0; if not TRAIL.f then return end end
  TRAIL.f:write(os.date("%H:%M:%S "), line, "\n"); TRAIL.f:flush()
end
local function log(fmt, ...)
  local line = string.format(fmt, ...)
  print("[LN3Couch] " .. line .. "\n")
  pcall(trail, line)
end
local function valid(o)
  if o == nil or type(o) ~= "userdata" then return false end
  local ok, r = pcall(function() return o:IsValid() end); return ok and r == true
end
local function nm(o) if valid(o) then return o:GetFullName() end return "nil" end
local function clsName(o) if not valid(o) then return "nil" end local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end) return ok and n or "?" end
local warned = {}
local function try(label, f, ...)
  local ok, r = pcall(f, ...)
  if not ok and not warned[label] then warned[label] = true; log("ОШИБКА в %s: %s", label, tostring(r)) end
  return ok, r
end
local function vec(v) return { X = v.X, Y = v.Y, Z = v.Z } end
local function dist(a, b) local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z; return math.sqrt(dx*dx + dy*dy + dz*dz) end

------------------------------------------------------------------ настройки
local SAVE_PATH = "ue4ss/Mods/LN3Couch/settings.lua"
local CFG, DEFAULTS

local function deepcopy(t) if type(t) ~= "table" then return t end local r = {}; for k, v in pairs(t) do r[k] = deepcopy(v) end; return r end
local function merge(dst, src) for k, v in pairs(src) do if type(v) == "table" and type(dst[k]) == "table" then merge(dst[k], v) else dst[k] = v end end end

local function serialize(v, ind)
  ind = ind or ""
  if type(v) == "table" then
    local keys = {}; for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = { "{\n" }
    for _, k in ipairs(keys) do
      -- ключ-слово пишем как есть, всё остальное — в скобках и кавычках
      local ks = (type(k) == "string" and k:match("^[%a_][%w_]*$")) and k or ("[" .. serialize(k) .. "]")
      out[#out + 1] = string.format("%s  %s = %s,\n", ind, ks, serialize(v[k], ind .. "  "))
    end
    out[#out + 1] = ind .. "}"; return table.concat(out)
  elseif type(v) == "string" then return string.format("%q", v) else return tostring(v) end
end

local function loadSettings()
  package.loaded["config"] = nil
  local ok, c = pcall(require, "config")
  DEFAULTS = (ok and type(c) == "table") and c or {}
  CFG = deepcopy(DEFAULTS)
  local f = io.open(SAVE_PATH, "r")
  if f then
    local src = f:read("*a"); f:close()
    local fn, perr = load(src, "settings", "t", {})
    local ok2, saved = pcall(fn or function() end)
    if ok2 and type(saved) == "table" then merge(CFG, saved); log("сохранённые настройки загружены")
    else log("settings.lua не читается (%s) — взяты настройки по умолчанию", tostring(perr or saved)) end
  end
end

local function saveSettings()
  local f, err = io.open(SAVE_PATH, "w")
  if not f then log("не удалось сохранить настройки: %s", tostring(err)); return end
  f:write("-- настройки LN3Couch, сохранены из меню игры\nreturn " .. serialize(CFG) .. "\n"); f:close()
end
loadSettings()
-- экран делится автоматически (по комнатам и видимости); в меню выбирается
-- вид разделения: авто, горизонтально, вертикально или «всегда» (split_sides)
CFG.split = "auto"
if CFG.keyboard and not CFG.keyboard.throw then CFG.keyboard.throw = "Period" end
if CFG.gamepad and not CFG.gamepad.throw then CFG.gamepad.throw = "Gamepad_RightShoulder" end
if CFG.gamepad and not CFG.gamepad.weapon then
  CFG.gamepad.weapon = "Gamepad_FaceButton_Right"            -- B, как у игрока 1
  if CFG.gamepad.crouch == "Gamepad_FaceButton_Right" then CFG.gamepad.crouch = "Gamepad_LeftShoulder" end
end
if CFG.keyboard and not CFG.keyboard.weapon then CFG.keyboard.weapon = "Comma" end

------------------------------------------------------------------ состояние
local S = {
  coop = false, pc1 = nil, p1 = nil, ai = nil, buddy = nil,
  pc2 = nil, cam2 = nil, camStrategy = 1, camCheckAt = 0,
  split = false, splitChangedAt = -1000,
  prev = {}, keyPrev = {}, frames = 0,
  menuOpen = false, menu = nil, sel = 1, capture = nil, toast = nil, toastUntil = 0,
  drawSeen = false,
}
local TICKS = 0
-- v9.15.7: время в секундах — настоящее (по часам игры), а не «кадры / 60»:
-- мод получает не 60 тактов в секунду, а сколько успевает игра (в тяжёлых
-- местах около 25–30), и всё, что считалось «секундами» по тактам, шло вдвое
-- медленнее (подсадка начиналась через 0,8 с вместо 0,4).
S.nowt = { tick = -1, t = 0, real = nil, base = 0 }
local function now()
  if S.nowt.tick == TICKS then return S.nowt.t end
  local okr, rt = pcall(function() return UEHelpers.GetGameplayStatics():GetRealTimeSeconds(UEHelpers.GetWorld()) end)
  if okr and type(rt) == "number" and rt > 0 then
    -- часы игры идут с загрузки уровня — сшиваем, чтобы время только росло
    if S.nowt.real == nil or rt < S.nowt.real then S.nowt.base = S.nowt.t - rt + (S.nowt.real and 1 / 60 or 0) end
    S.nowt.real = rt
    S.nowt.t = S.nowt.base + rt
  else
    S.nowt.t = S.nowt.t + math.max(0, TICKS - S.nowt.tick) / 60
  end
  S.nowt.tick = TICKS
  return S.nowt.t
end
local suspendCoop -- объявлено заранее, задаётся ниже -- «секунды» по нашему циклу (~60 раз в секунду)

------------------------------------------------------------------ ввод
local keyCache = {}
local function key(name) local k = keyCache[name]; if not k then k = { KeyName = FName(name) }; keyCache[name] = k end; return k end
local function isDown(pc, name)
  if not (valid(pc) and name) then return false end
  local ok, r = pcall(function() return pc:IsInputKeyDown(key(name)) end); return ok and r == true
end
local function analog(pc, name)
  if not valid(pc) then return 0 end
  local ok, r = pcall(function() return pc:GetInputAnalogKeyState(key(name)) end); return (ok and type(r) == "number") and r or 0
end
local function pressed(name) -- фронт нажатия на клавиатуре игрока 1
  local d = isDown(S.pc1, name); local was = S.keyPrev[name]; S.keyPrev[name] = d; return d and not was
end

local function p2Source() if valid(S.pc2) then return S.pc2 end return S.pc1 end
local function readP2()
  if CFG.device == "gamepad" then
    local src, g = p2Source(), CFG.gamepad
    local lx, ly = analog(src, "Gamepad_LeftX"), analog(src, "Gamepad_LeftY")
    if math.abs(lx) < g.deadzone then lx = 0 end
    if math.abs(ly) < g.deadzone then ly = 0 end
    -- Запасной путь: аналоговые значения у «безтелесного» игрока 2 движок может
    -- не обновлять, а нажатия-кнопки обновляет всегда. Стик, отклонённый за порог,
    -- движок тоже присылает как кнопки Gamepad_LeftStick_*. Плюс крестовина.
    local du = isDown(src, "Gamepad_LeftStick_Up") or isDown(src, "Gamepad_DPad_Up")
    local dd = isDown(src, "Gamepad_LeftStick_Down") or isDown(src, "Gamepad_DPad_Down")
    local dl = isDown(src, "Gamepad_LeftStick_Left") or isDown(src, "Gamepad_DPad_Left")
    local dr = isDown(src, "Gamepad_LeftStick_Right") or isDown(src, "Gamepad_DPad_Right")
    if lx == 0 and ly == 0 then
      ly = (du and 1 or 0) - (dd and 1 or 0)
      lx = (dr and 1 or 0) - (dl and 1 or 0)
      if (ly ~= 0 or lx ~= 0) and not S.padDigitalLogged then S.padDigitalLogged = true; log("геймпад игрока 2: стик читается как кнопки (аналог = 0)") end
    elseif not S.padAnalogLogged then S.padAnalogLogged = true; log("геймпад игрока 2: аналоговый стик работает (%.2f, %.2f)", lx, ly) end
    return ly, lx, analog(src, "Gamepad_RightX"), analog(src, "Gamepad_RightY"),
           isDown(src, g.jump), isDown(src, g.grab), isDown(src, g.crouch), isDown(src, g.sprint),
           isDown(src, g.throw or "Gamepad_RightShoulder"), isDown(src, g.weapon or "Gamepad_FaceButton_Right")
  end
  local k, pc = CFG.keyboard, S.pc1
  local f = (isDown(pc, k.up) and 1 or 0) - (isDown(pc, k.down) and 1 or 0)
  local r = (isDown(pc, k.right) and 1 or 0) - (isDown(pc, k.left) and 1 or 0)
  return f, r, 0, 0, isDown(pc, k.jump), isDown(pc, k.grab), isDown(pc, k.crouch), isDown(pc, k.sprint),
         isDown(pc, k.throw or "Period"), isDown(pc, k.weapon or "Comma")
end

------------------------------------------------------------------ персонажи
local function pcId(pc) local ok, id = pcall(function() return pc.Player.ControllerId end) if ok then return id end end
local function isLocalPC(pc) local ok, r = pcall(function() return pc.Player ~= nil and pc.Player:IsValid() end) return ok and r end
-- Игрок 1 — первый локальный игрок. Номер его геймпада не обязательно 0:
-- игра отдаёт его тому геймпаду, которым нажали «начать».
local function findPC1()
  local list = {}
  for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
    if valid(pc) and isLocalPC(pc) and pc ~= S.pc2 then list[#list + 1] = pc end
  end
  if #list == 0 then return nil end
  local ok, first = pcall(function() return UEHelpers.GetGameplayStatics():GetPlayerController(list[1], 0) end)
  if ok and valid(first) and first ~= S.pc2 and isLocalPC(first) then return first end
  for _, pc in ipairs(list) do local okp, pawn = pcall(function() return pc.Pawn end) if okp and valid(pawn) then return pc end end
  return list[1]
end
-- номер геймпада для игрока 2: из настроек, но не тот, что у игрока 1
local function p2PadId()
  local want = CFG.p2_controller_id or 1
  local p1id = valid(S.pc1) and pcId(S.pc1) or 0
  if want == p1id then want = (p1id == 0) and 1 or 0 end
  return want
end
local function findPC(id)
  for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
    if pc:IsValid() then
      local ok, cid = pcall(function() return pc.Player.ControllerId end)
      if ok and cid == id then return pc end
    end
  end
end
-- v9.15.6: ГЕРОИ — ПО РОДУ, А НЕ ПО ИМЕНИ. Раньше героями считались только
-- классы BP_Low_C и BP_Alone_C, и в дополнениях (Dime в The Backstage, свои
-- Low и Alone в The Shores) мод героев не находил и кооператив не включался.
-- Все герои игры происходят от BP_KosmosPlayer_C — по нему и узнаём.
S.heroCls = {}
local function isHero(p)
  if not valid(p) then return false end
  local ok, cls = pcall(function() return p:GetClass() end)
  if not ok or not valid(cls) then return false end
  local key = cls:GetFName():ToString()
  local r = S.heroCls[key]
  if r == nil then
    r = false
    local c, depth = cls, 0
    while valid(c) and depth < 12 do
      local n = c:GetFName():ToString()
      if n == "BP_KosmosPlayer_C" then r = true; break end
      local oks, sup = pcall(function() return c:GetSuperStruct() end)
      c = oks and sup or nil; depth = depth + 1
    end
    S.heroCls[key] = r
  end
  return r
end
local function heroName(p)
  if not valid(p) then return "?" end
  local c = p:GetClass():GetFName():ToString()
  if c:find("Low") then return "Low" elseif c:find("Alone") then return "Alone" elseif c:find("Dime") then return "Dime" end
  return (c:gsub("^BP_", ""):gsub("_C$", ""))
end
-- все герои в мире (живые и «лишние» копии)
S.heroList = function()
  local out = {}
  local list = FindAllOf("BP_KosmosPlayer_C") or FindAllOf("KosmosBaseCharacter") or {}
  for _, h in ipairs(list) do if isHero(h) then out[#out + 1] = h end end
  return out
end
local function findBuddy(p1pawn)
  for _, ai in ipairs(FindAllOf("KosmosAIController") or {}) do
    if ai:IsValid() then
      local ok, pawn = pcall(function() return ai.Pawn end)
      if ok and isHero(pawn) and pawn ~= p1pawn then return ai, pawn end
    end
  end
end
local function setBrain(ai, on)
  try("Brain", function() local b = ai.BrainComponent; if valid(b) then if on then b:RestartLogic() else b:StopLogic("LN3Couch") end end end)
  if not on then try("StopAllAICommands", function() ai:StopAllAICommands() end) end
end

-- Реестр персонажей игры. Каждый раз, когда героем начинает управлять другой
-- контроллер, игра дописывает в этот список ещё одну запись о герое, а при его
-- исчезновении убирает только одну. «Лишняя» запись потом роняет игру.
-- Поэтому после каждой смены управления мы сами убираем дописанную запись
-- (у списка меняем только длину — новые записи всегда в конце).
local REG_OK = pcall(function()
  RegisterCustomProperty({
    Name = "LN3_CharNum",
    Type = PropertyTypes.IntProperty,
    BelongsToClass = "/Script/Kosmos.KosmosCharactersSubsystem",
    OffsetInternal = 0x40,
  })
end)
-- То же поле как массив целых чисел — чтобы можно было найти и убрать дубликаты.
-- Одна запись = 0x1C байт = 7 чисел; первые два — «ссылка» на персонажа.
S.regArrOk = pcall(function()
  RegisterCustomProperty({
    Name = "LN3_CharArr",
    Type = PropertyTypes.ArrayProperty,
    BelongsToClass = "/Script/Kosmos.KosmosCharactersSubsystem",
    OffsetInternal = 0x38,
    ArrayProperty = { Type = PropertyTypes.IntProperty },
  })
end)
-- Номер объекта в движке (UObjectBase::InternalIndex, смещение 0x0C) —
-- чтобы понять, на живого ли персонажа указывает запись реестра.
S.idxOk = pcall(function()
  RegisterCustomProperty({
    Name = "LN3_Index",
    Type = PropertyTypes.IntProperty,
    BelongsToClass = "/Script/CoreUObject.Object",
    OffsetInternal = 0x0C,
  })
end)
local function charsSub()
  local ok, sub = pcall(function() return FindFirstOf("KosmosCharactersSubsystem") end)
  if ok and valid(sub) then return sub end
end
local function regCount(sub)
  local ok, n = pcall(function() return sub.LN3_CharNum end)
  if ok and type(n) == "number" and n >= 0 and n < 256 then return n end
end
local function registryWorks()
  local sub = charsSub()
  return REG_OK and sub ~= nil and regCount(sub) ~= nil
end
-- Убрать повторные записи об одном и том же персонаже. Именно повтор после
-- исчезновения героя превращается в «пустую» запись, на которой игра падает.
local function dedupeRegistry(why)
  local REG_INTS = 7
  if not S.regArrOk then return end
  local sub = charsSub(); if not sub then return end
  local n = regCount(sub); if not n or n < 1 then return end
  local ints = {}
  local okRead = pcall(function()
    sub.LN3_CharNum = n * REG_INTS
    local arr = sub.LN3_CharArr
    for i = 1, n * REG_INTS do ints[i] = arr[i] end
  end)
  pcall(function() sub.LN3_CharNum = n end)   -- длину возвращаем сразу
  if not okRead or #ints ~= n * REG_INTS then
    if not S.regReadLogged then S.regReadLogged = true; log("реестр: не удалось прочитать записи") end
    return
  end
  -- живые персонажи: запись о персонаже, которого уже нет (после смерти и
  -- возрождения), — та самая «пустая» запись, на которой игра падает,
  -- как только включается ИИ (подсадка).
  local live, liveN = {}, 0
  if S.idxOk then
    pcall(function()
      for _, c in ipairs(FindAllOf("KosmosBaseCharacter") or {}) do
        if valid(c) then local i = c.LN3_Index; if type(i) == "number" then live[i] = true; liveN = liveN + 1 end end
      end
    end)
  end
  local best = {}   -- для каждого номера — запись с самым новым «серийником»
  for k = 0, n - 1 do
    local idx, ser = ints[k * REG_INTS + 1], ints[k * REG_INTS + 2]
    if type(idx) ~= "number" or type(ser) ~= "number" or idx < 0 or idx > 50000000 then
      if not S.regOddLogged then S.regOddLogged = true; log("реестр: непонятная запись (%s,%s) — не трогаю", tostring(idx), tostring(ser)) end
      return
    end
    if not best[idx] or ser > best[idx].ser then best[idx] = { k = k, ser = ser } end
  end
  -- проверка, что записи действительно указывают на персонажей: если ни одна
  -- не совпала с живыми — значит, догадка о формате неверна, «исчезнувших» не трогаем
  local matched = 0
  for idx in pairs(best) do if live[idx] then matched = matched + 1 end end
  if matched == 0 then
    if liveN > 0 and not S.regNoMatchLogged then S.regNoMatchLogged = true; trail("реестр: записи не совпали с живыми персонажами — исчезнувших не убираю") end
    liveN = 0
  end
  local keep, dups, stale = {}, 0, 0
  for k = 0, n - 1 do
    local idx = ints[k * REG_INTS + 1]
    if best[idx].k ~= k then dups = dups + 1
    elseif liveN > 0 and not live[idx] then stale = stale + 1
    else keep[#keep + 1] = k end
  end
  if not S.regMapLogged and (stale > 0 or dups > 0) then
    S.regMapLogged = true
    local e, l = {}, {}
    for k = 0, n - 1 do e[#e + 1] = ints[k * REG_INTS + 1] .. ":" .. ints[k * REG_INTS + 2] end
    for i in pairs(live) do l[#l + 1] = tostring(i) end
    trail("реестр: записи " .. table.concat(e, " ") .. " | живые персонажи " .. table.concat(l, " "))
  end
  -- если «живыми» оказались бы все записи убраны — что-то не так, не трогаем
  if #keep == 0 then return end
  if dups == 0 and stale == 0 then return end
  local okWrite = pcall(function()
    sub.LN3_CharNum = n * REG_INTS
    local arr = sub.LN3_CharArr
    for j, k in ipairs(keep) do
      if (j - 1) ~= k then
        for t = 1, REG_INTS do arr[(j - 1) * REG_INTS + t] = ints[k * REG_INTS + t] end
      end
    end
  end)
  pcall(function() sub.LN3_CharNum = okWrite and #keep or n end)
  log("реестр персонажей: убрал повторов %d, записей об исчезнувших %d (%s), было %d, стало %d", dups, stale, why or "", n, okWrite and #keep or n)
end

-- Сменить управление героем без «лишней записи». false — если не получилось.
local function safePossess(ctrl, pawn, label)
  local sub = charsSub()
  local n0 = sub and regCount(sub)
  if not n0 then log("%s: реестр персонажей недоступен — не меняю управление", label); return false end
  local ok = try("Possess " .. label, function() ctrl:Possess(pawn) end)
  local n1 = regCount(sub)
  if n1 and n1 > n0 and n1 - n0 <= 3 then
    pcall(function() sub.LN3_CharNum = n0 end)
    trail(string.format("%s: реестр %d→%d, вернул %d", label, n0, n1, n0))
  else
    trail(string.format("%s: реестр %s→%s", label, tostring(n0), tostring(n1)))
  end
  return ok
end

------------------------------------------------------------------ второй вид и камера
local function gms() return UEHelpers.GetGameMapsSettings() end
-- Как делить экран. По умолчанию — сам: на обычном экране сверху и снизу
-- (каждой половине остаётся широкий кадр, как в игре), на сверхшироком
-- (21:9 и шире) — слева и справа. В settings.lua можно задать
-- split_layout = "top_bottom" или "left_right".
-- v9.15.4: вид разделения из меню. nil — сам (как стоят герои);
-- true — слева/справа (вертикальная черта), false — сверху/снизу.
S.sidesForced = function()
  local s = CFG.split_sides or "auto"
  if s == "left_right" or s == "always_left_right" then return true end
  if s == "top_bottom" or s == "always_top_bottom" then return false end
  return nil
end
S.splitAlways = function()
  local s = CFG.split_sides or "auto"
  return s == "always_left_right" or s == "always_top_bottom"
end
S.layoutLR = function()
  if CFG.split_layout_force == "left_right" then return true end
  if CFG.split_layout_force == "top_bottom" then return false end
  local f = S.sidesForced(); if f ~= nil then return f end
  if S.splitLR ~= nil then return S.splitLR end
  if not S.aspect then
    pcall(function()
      local vs = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary"):GetViewportSize(S.pc1)
      if vs.X > 0 and vs.Y > 0 then S.aspect = vs.X / vs.Y; log("экран %dx%d — делю %s", vs.X, vs.Y, S.aspect >= 2.0 and "слева и справа" or "сверху и снизу") end
    end)
  end
  return (S.aspect or 1.78) >= 2.0
end
local function applyLayout()
  try("layout", function()
    local g = gms()
    g.TwoPlayerSplitscreenLayout = S.layoutLR() and 1 or 0
  end)
end

local updateCam2Pose
local setSplitVisible
local function spawnCam()
  local ok, a = try("spawn camera", function()
    local cls = StaticFindObject("/Script/Engine.CameraActor")
    local gs = UEHelpers.GetGameplayStatics()
    local t = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = vec(S.buddy:K2_GetActorLocation()), Scale3D = { X = 1, Y = 1, Z = 1 } }
    local actor = gs:BeginDeferredActorSpawnFromClass(S.pc1, cls, t, 1, S.pc1)
    return gs:FinishSpawningActor(actor, t)
  end)
  if ok and valid(a) then return a end
end

-- Камера игры (Kosmos CameraManager) привязана к комнатам и не умеет «смотреть» через
-- чужую камеру. Поэтому второму игроку на время создания даём обычный движковый
-- PlayerCameraManager, а он уже честно смотрит через нашу камеру.
local function applyCam()
  local cm = S.pc2.PlayerCameraManager
  if S.nativeCam then
    try("pc2 ViewTarget", function() S.pc2:SetViewTargetWithBlend(S.buddy, 0, 0, 0, false) end)
    try("fade cm2", function() if valid(cm) then cm:StopCameraFade() end end)
    log("камера игрока 2: игровая (%s)", clsName(cm))
    return
  end
  try("pc2 ViewTarget", function() S.pc2:SetViewTargetWithBlend(S.cam2, 0, 0, 0, false) end)
  try("fade cm2", function() if valid(cm) then cm:StopCameraFade() end end)
  log("камера игрока 2: %s", nm(cm))
end

local function usablePC2(pc)
  if not valid(pc) then return false end
  local ok, r = pcall(function() return valid(pc.Player) and valid(pc.PlayerCameraManager) end)
  return ok and r
end

local function createPC2()
  local cdo, oldCam, gm, oldSpec
  -- С «настоящим» вторым игроком оставляем игровую камеру (она умеет вести
  -- героя по комнатам, как у игрока 1). Обычная движковая — только для режима ИИ.
  -- (игровая камера для второго игрока роняла игру — используем свою)
  do try("cdo swap", function()
    cdo = S.pc1:GetClass():GetCDO()
    oldCam = cdo.PlayerCameraManagerClass
    local vanilla = StaticFindObject("/Script/Engine.PlayerCameraManager")
    if valid(vanilla) then cdo.PlayerCameraManagerClass = vanilla end
  end) end
  gm = UEHelpers.GetGameModeBase()
  if valid(gm) then try("spec flag", function() oldSpec = gm.bStartPlayersAsSpectators; gm.bStartPlayersAsSpectators = true end) end
  -- Игра, увидев нового игрока посреди партии, отдаёт ему героя (а потом мы
  -- возвращали героя игроку 1). Каждая такая передача героя оставляет в
  -- игре «лишнюю запись» о персонаже, и после смерти/перезагрузки игра на
  -- ней падает. Поэтому на время создания второго вида говорим игре, что
  -- партия «ещё не началась» — тогда героя она никому не раздаёт.
  local oldState
  if valid(gm) then
    pcall(function()
      oldState = gm.CurrentMatchState
      gm.CurrentMatchState = FName("WaitingToStart")
    end)
  end
  local ok, pc = try("CreatePlayer", function() return UEHelpers.GetGameplayStatics():CreatePlayer(S.pc1, p2PadId(), true) end)
  if valid(gm) and oldState ~= nil then pcall(function() gm.CurrentMatchState = oldState end) end
  if cdo and oldCam then try("cdo restore", function() cdo.PlayerCameraManagerClass = oldCam end) end
  if valid(gm) and oldSpec ~= nil then try("spec restore", function() gm.bStartPlayersAsSpectators = oldSpec end) end
  if ok then return pc end
end

-- v9.15.2: лишние «локальные игроки». После «выхода из уровня» и быстрого
-- возобновления старый второй игрок иногда остаётся, и мод создаёт ещё
-- одного — их становится трое. При разделении экран берёт первых двух из
-- списка, и во второй половине оказывается старый вид (на обеих половинах
-- был первый игрок). Оставляем только игрока 1 и нашего второго.
S.pruneLocalPlayers = function(keep2, why)
  local removed = 0
  for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
    if valid(pc) and pc ~= S.pc1 and pc ~= keep2 and isLocalPC(pc) then
      local okh, hp = pcall(function() return pc.Pawn end)
      if okh and isHero(hp) then
        log("лишний игрок (контроллер %s) с героем %s — не трогаю", tostring(pcId(pc)), heroName(hp))
      else
        local id = pcId(pc)
        pcall(function() pc:UnPossess() end)
        pcall(function() UEHelpers.GetGameplayStatics():RemovePlayer(pc, false) end)
        removed = removed + 1
        log("убран лишний игрок (контроллер %s) — %s", tostring(id), why)
      end
    end
  end
  return removed
end
local function ensurePC2()
  if usablePC2(S.pc2) then return true end
  S.pc2 = nil
  local existing
  for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
    if valid(pc) and pc ~= S.pc1 and isLocalPC(pc) and not existing and usablePC2(pc) then existing = pc end
  end
  -- если «вторых» несколько — оставляем одного
  pcall(S.pruneLocalPlayers, existing, "второй уже есть")
  S.pc2 = usablePC2(existing) and existing or createPC2()
  if not usablePC2(S.pc2) then log("не удалось создать вид для игрока 2"); S.pc2 = nil; return false end
  local stolen = S.pc2.Pawn
  if valid(stolen) then
    log("вид игрока 2 захватил %s — возвращаю", heroName(stolen))
    try("pc2 UnPossess", function() S.pc2:UnPossess() end)
    if stolen == S.p1 then safePossess(S.pc1, S.p1, "вернуть героя игроку 1") end
    if stolen == S.buddy and valid(S.ai) then safePossess(S.ai, S.buddy, "вернуть героя ИИ"); setBrain(S.ai, false) end
  end
  local okn, cmn = pcall(function() return S.pc2.PlayerCameraManager:GetClass():GetFName():ToString() end)
  S.nativeCam = okn and cmn ~= "PlayerCameraManager"
  if S.nativeCam then
    applyCam()
  else
    if not valid(S.cam2) then S.cam2 = spawnCam() end
    if valid(S.cam2) then updateCam2Pose(); applyCam() else log("камеру для игрока 2 создать не удалось") end
  end
  S.camCheckAt = S.frames + 30
  S.camOkLogged = false
  S.lp2 = S.pc2.Player
  local pid = p2PadId()
  if pcId(S.pc2) ~= pid then
    try("SetPlayerControllerID", function() UEHelpers.GetGameplayStatics():SetPlayerControllerID(S.pc2, pid) end)
  end
  log("геймпады: игрок 1 = %s, игрок 2 = %s", tostring(pcId(S.pc1)), tostring(pcId(S.pc2)))
  S.split = true
  setSplitVisible(false)
  return true
end

local function removePC2()
  -- v9.15.1 (#15): если экран был разделён, вернуть игроку 1 его обычный обзор.
  -- Раньше при выходе в меню/смене уровня с разделённым экраном у игрока 1
  -- оставалась «половинная» настройка обзора, и вся игра казалась ближе
  if S.aspectSaved then
    local A = S.aspectSaved
    pcall(function()
      local lp = S.pc1.Player
      local key = lp:GetFullName()
      if A.lp[key] ~= nil then lp.AspectRatioAxisConstraint = A.lp[key]; A.lp[key] = nil; trail("экран: обзор игрока 1 возвращён (" .. tostring(lp.AspectRatioAxisConstraint) .. ")") end
    end)
    A.lp = {}
    -- камеры старого уровня могли быть уже удалены — их не трогаем
    A.cams = {}
  end
  if valid(S.lp2) and valid(S.pc2) then try("reattach", function() S.lp2.PlayerController = S.pc2 end) end
  if S.playersSwapped then pcall(S.setPlayerOrder, false) end
  try("split off", function() gms().bUseSplitscreen = false end)
  S.split, S.lp2 = false, nil
  if valid(S.pc2) then
    try("pc2 UnPossess", function() S.pc2:UnPossess() end)
    try("RemovePlayer", function() UEHelpers.GetGameplayStatics():RemovePlayer(S.pc2, false) end)
  end
  S.pc2 = nil
  if valid(S.cam2) then try("cam destroy", function() S.cam2:K2_DestroyActor() end) end
  S.cam2 = nil
end

local function lookMag(v) if not v then return 0 end return math.abs(v.X or 0) + math.abs(v.Y or 0) end

-- «Комнатная» камера для игрока 2. Игра расставляет по уровню камеры-«кукольные
-- домики»: у каждой есть зона героя и зона, в которой ездит сама камера.
-- Чем дальше герой прошёл по своей зоне, тем дальше камера проехала по своей,
-- и смотрит она под заданным художниками углом, чуть доворачивая за героем.
-- Повторяем это для героя игрока 2.
local RC = { list = {}, listAt = -100000, cur = nil, pickAt = 0, logged = {} }
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end
local function angDiff(a, b) return ((a - b + 180) % 360) - 180 end
local function boxInfo(box)
  local c = box:K2_GetComponentLocation()
  local r = box:K2_GetComponentRotation()
  local e = box:GetScaledBoxExtent()
  return c, math.rad(r.Yaw), e
end
local function toLocal(c, yaw, p)
  local dx, dy = p.X - c.X, p.Y - c.Y
  return dx * math.cos(yaw) + dy * math.sin(yaw), -dx * math.sin(yaw) + dy * math.cos(yaw), p.Z - c.Z
end
local function toWorld(c, yaw, lx, ly, lz)
  return { X = c.X + lx * math.cos(yaw) - ly * math.sin(yaw), Y = c.Y + lx * math.sin(yaw) + ly * math.cos(yaw), Z = c.Z + lz }
end
local function pickRoomCam(p)
  if S.frames - RC.listAt > 300 then RC.list = FindAllOf("DollhouseCameraActor") or {}; RC.listAt = S.frames end
  local best, bestPri, bestSize
  for _, a in ipairs(RC.list) do
    local ok, res = pcall(function()
      if not (valid(a) and a.mEnabled) then return nil end
      local pv = a.mEditablePlayerVolume; if not valid(pv) then return nil end
      local c, yaw, e = boxInfo(pv)
      local lx, ly, lz = toLocal(c, yaw, p)
      if math.abs(lx) <= e.X and math.abs(ly) <= e.Y and math.abs(lz) <= e.Z then return { a.mPriority or 0, e.X * e.Y } end
    end)
    if ok and res then
      if not best or res[1] > bestPri or (res[1] == bestPri and res[2] < bestSize) then best, bestPri, bestSize = a, res[1], res[2] end
    end
  end
  return best
end
-- Стоит ли точка p в зоне комнатной камеры a
S.inRoomVol = function(a, p)
  local pv = a.mEditablePlayerVolume; if not valid(pv) then return false end
  local c, yaw, e = boxInfo(pv)
  local lx, ly, lz = toLocal(c, yaw, p)
  return math.abs(lx) <= e.X and math.abs(ly) <= e.Y and math.abs(lz) <= e.Z
end
local function roomCamPose(a, p)
  local cc = a.mCameraComponent
  local pc, pyaw, pe = boxInfo(a.mEditablePlayerVolume)
  local lx, ly, lz = toLocal(pc, pyaw, p)
  local tx, ty, tz = clamp(lx / math.max(pe.X, 1), -1, 1), clamp(ly / math.max(pe.Y, 1), -1, 1), clamp(lz / math.max(pe.Z, 1), -1, 1)
  local loc
  local cv = a.mEditableCameraVolume
  if valid(cv) then
    local cvc, cvyaw, cve = boxInfo(cv)
    local rx, ry, rz = 1, 1, 1
    pcall(function() if cc.mUseRatio then local r = cc.mCameraVolumeRatio; rx, ry, rz = r.X, r.Y, r.Z end end)
    -- v9.15.3: где герой в своей коробке (доли по КАЖДОЙ оси отдельно), там
    -- и камера в своей. Замеры на камере игрока 1 (зона ArrivalsBridgeEntry,
    -- 7 точек): доли камеры игры совпадают с долями героя по каждой оси с
    -- точностью ~0,05. Раньше доли делились на ОДНУ общую длину (наибольшую
    -- сторону) — в вытянутых зонах камера почти не ездила вдоль короткой
    -- стороны. Коробки бывают повёрнуты по-разному — поворачиваем доли
    -- из осей коробки героя в оси коробки камеры.
    local d = pyaw - cvyaw
    local nx = clamp(tx * math.cos(d) - ty * math.sin(d), -1, 1)
    local ny = clamp(tx * math.sin(d) + ty * math.cos(d), -1, 1)
    loc = toWorld(cvc, cvyaw, nx * cve.X * rx, ny * cve.Y * ry, tz * cve.Z * rz)
  else
    loc = cc:K2_GetComponentLocation()
  end
  local base = cc:K2_GetComponentRotation()
  local yaw, pitch = base.Yaw, base.Pitch
  -- доворот за героем в пределах, заданных для этой камеры
  local ok = pcall(function()
    if a.mUseFollowRotation then
      local f = a.mCameraFollowRotation
      local dx, dy, dz = p.X - loc.X, p.Y - loc.Y, (p.Z + 40) - loc.Z
      local lookYaw = math.deg(math.atan(dy, dx))
      local lookPitch = math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy)))
      local sc = (f.mScale and f.mScale > 0) and f.mScale or 1
      yaw = base.Yaw + clamp(angDiff(lookYaw, base.Yaw) * sc, f.mYawMin, f.mYawMax)
      pitch = base.Pitch + clamp((lookPitch - base.Pitch) * sc, f.mPitchMin, f.mPitchMax)
    end
  end)
  local fov = 60
  pcall(function() fov = cc.FieldOfView end)
  return loc, { Pitch = pitch, Yaw = yaw, Roll = 0 }, fov
end
-- поза комнатной камеры для героя игрока 2 (или nil — тогда старая камера)
local function roomCamTarget()
  if CFG.room_camera == false then return nil end
  local okp, p = pcall(function() return S.buddy:K2_GetActorLocation() end)
  if not okp then return nil end
  -- особый план предмета (колесо и т.п.) — показываем его как есть, без
  -- подстройки под положение героя: камера стоит там, где её поставили художники
  if valid(S.cam2External) then
    local ok, loc, rot, fov = pcall(function()
      local cc = S.cam2External.mCameraComponent
      if not valid(cc) then cc = S.cam2External:GetComponentByClass(StaticFindObject("/Script/Engine.CameraComponent")) end
      return cc:K2_GetComponentLocation(), cc:K2_GetComponentRotation(), cc.FieldOfView
    end)
    if ok and loc then return loc, rot, fov end
  end
  if S.frames >= RC.pickAt then
    RC.pickAt = S.frames + 10
    local a = S.pickRoomAnyCopy(p)
    -- «липкая» комната: пока герой рядом с зоной текущей камеры (запас 2,5 м),
    -- не перескакиваем на другую — рычаги, подсадки и прыжки иначе дёргают камеру
    if a ~= RC.cur and valid(RC.cur) then
      local still = false
      pcall(function()
        local pv = RC.cur.mEditablePlayerVolume
        local c, yaw, e = boxInfo(pv)
        local lx, ly, lz = toLocal(c, yaw, p)
        still = math.abs(lx) <= e.X + 250 and math.abs(ly) <= e.Y + 250 and math.abs(lz) <= e.Z + 400
      end)
      if still then
        RC.pending = (RC.pending == a) and a or a
        RC.pendingFor = (RC.pendingAt == a) and (RC.pendingFor or 0) + 1 or 1
        RC.pendingAt = a
        if RC.pendingFor < 6 then a = RC.cur end   -- ~1 с в новой зоне, прежде чем сменить
      end
    end
    if a ~= RC.cur then
      RC.cur = a; RC.changedAt = S.frames
      if a and not RC.logged[a:GetFName():ToString()] then RC.logged[a:GetFName():ToString()] = true; trail("вторая камера: комната " .. a:GetFName():ToString()) end
    end
  end
  if not valid(RC.cur) then return nil end
  if S.frames >= (RC.p1At or 0) then
    RC.p1At = S.frames + 10
    local okl, l1 = pcall(function() return S.p1:K2_GetActorLocation() end)
    RC.p1cur = nil
    if okl then pcall(function() RC.p1cur = S.pickRoomAnyCopy(l1) end) end
  end
  -- v9.15.3: и в той же зоне, что Low, камеру для Alone считаем по данным
  -- камеры комнаты (а не копируем камеру игрока 1): при разделении зона
  -- выбирается заново по месту Alone, и поза считается от Alone
  -- в наложенных копиях зона комнаты может быть в другой копии — считаем
  -- позу по месту героя, перенесённому в копию этой зоны
  local pp = p
  if S.overlayOn then pcall(function() pp = S.toCopyOf(p, RC.cur.mEditablePlayerVolume:K2_GetComponentLocation()) end) end
  local ok, loc, rot, fov = pcall(roomCamPose, RC.cur, pp)
  if not ok then
    if not RC.errLogged then RC.errLogged = true; log("комнатная камера: ошибка %s", tostring(loc)) end
    return nil
  end
  -- v9.15.5: в наложенных копиях уровня камера комнаты стоит в другой копии
  -- (в 200 м от героя) — игра показывает оттуда наложение. Наложения у второй
  -- камеры нет, поэтому ставим её в копию, где сейчас Alone, на то же место
  -- относительно копии: тот же ракурс, но видно саму Alone.
  if S.overlayOn then
    -- v9.15.5: кукла у Alone — вторая камера смотрит из «светлой» копии (той,
    -- где стоит камера игры), на то же место. Иначе — из копии, где Alone.
    -- v9.15.7: как у камеры игры — из той копии, где стоит камера игры.
    -- Героя из другой копии движок сам дорисовывает в эту (поэтому камера,
    -- ушедшая за героем в его копию, показывала «невидимку» с куклой).
    local okc, cl = pcall(function() return S.pc1.PlayerCameraManager:GetCameraLocation() end)
    loc = S.toCopyOf(loc, okc and cl or p)
  end
  if dist(loc, S.overlayOn and S.toCopyOf(p, loc) or p) > 5000 then return nil end
  return loc, rot, fov
end
-- v9.15.3: ГЕРОЙ ВСЕГДА В КАДРЕ. Камера комнаты поворачивается за героем
-- лишь в пределах, заданных художниками, а «камера за героем» повторяет
-- наклон камеры игрока 1. Когда Alone забиралась высоко (на другой ярус),
-- вторая камера смотрела мимо — её было не видно. Если герой дальше от
-- центра кадра, чем на cam2_keep_yaw/cam2_keep_pitch градусов, доворачиваем.
S.keepInView = function(loc, pitch, yaw)
  local okb, bl = pcall(function() return S.buddy:K2_GetActorLocation() end)
  if not okb then return pitch, yaw end
  if S.overlayOn then bl = S.toCopyOf(bl, loc) end   -- Alone в той копии, где камера
  local dx, dy, dz = bl.X - loc.X, bl.Y - loc.Y, (bl.Z + 40) - loc.Z
  local h = math.sqrt(dx * dx + dy * dy)
  if h < 50 then return pitch, yaw end
  local lookYaw = math.deg(math.atan(dy, dx))
  local lookPitch = math.deg(math.atan(dz, h))
  -- половина экрана сверху/снизу — по высоте кадр уже, держим героя ближе к центру
  local limY = CFG.cam2_keep_yaw or 20
  local limP = CFG.cam2_keep_pitch or ((S.split and not S.layoutLR()) and 8 or 13)
  local dyaw = ((lookYaw - yaw + 180) % 360) - 180
  local dp = lookPitch - pitch
  local fixed = false
  if dyaw > limY then yaw = yaw + dyaw - limY; fixed = true elseif dyaw < -limY then yaw = yaw + dyaw + limY; fixed = true end
  if dp > limP then pitch = pitch + dp - limP; fixed = true elseif dp < -limP then pitch = pitch + dp + limP; fixed = true end
  if fixed and (not S.keepLogAt or S.frames - S.keepLogAt > 600) then
    S.keepLogAt = S.frames
    trail(string.format("вторая камера: Alone была вне кадра (в сторону %.0f°, по высоте %.0f°) — доворачиваю", dyaw, dp))
  end
  return pitch, yaw
end
updateCam2Pose = function()
  if not (valid(S.cam2) and valid(S.pc1) and valid(S.p1) and valid(S.buddy)) then return end
  -- герой «перенёсся» (смерть, чекпоинт) — камеру ставим сразу, без проезда
  local frozen = false
  pcall(function()
    local bl = S.buddy:K2_GetActorLocation()
    local hidden = false; pcall(function() hidden = S.buddy:IsHidden() end)
    local jump = S.lastBuddyLoc and dist(bl, S.lastBuddyLoc) or 0
    -- v9.15.5: переход Alone в другую копию уровня (наложенные копии) — это
    -- не смерть и не перенос: она стоит на том же месте, только в другой
    -- копии. Камеру не замораживаем, а переносим вместе с ней на тот же
    -- сдвиг — картинка у второго игрока не прыгает и не показывает чужое.
    local g = S.overlayOn and S.copy and S.copy.gap
    local holderIsBuddy = false
    if g then pcall(function() holderIsBuddy = (S.lightHolder() == S.buddy) end) end
    if g and S.lastBuddyLoc and not hidden then
      local dz = bl.Z - S.lastBuddyLoc.Z
      local dh = math.sqrt((bl.X - S.lastBuddyLoc.X) ^ 2 + (bl.Y - S.lastBuddyLoc.Y) ^ 2)
      if dh < 500 and math.abs(math.abs(dz) - g) < 500 then
        -- v9.15.7: камера остаётся в копии камеры игры, переход героя её не двигает
        S.lastBuddyLoc, S.camFrozenAt, jump = bl, nil, 0
        if not S.copyJumpLogAt or S.frames - S.copyJumpLogAt > 600 then
          S.copyJumpLogAt = S.frames
          trail(string.format("вторая камера: Alone перешла в другую копию уровня (%.0f см) — камера остаётся в копии камеры игры", dz))
        end
      end
    end
    if hidden then
      -- герой спрятан игрой (смерть) — камера стоит на его последнем месте
      S.camFrozenAt = S.camFrozenAt or S.frames; frozen = true
    elseif S.camFrozenAt and S.frames - S.camFrozenAt < 180 then
      frozen = true   -- даём игре закончить перенос героя
    elseif jump > 1500 and not S.camFrozenAt then
      -- герой «улетел» (смерть, перенос) — пару секунд держим камеру на месте
      S.camFrozenAt = S.frames; frozen = true
      trail("вторая камера: герой перенёсся — жду и ставлю камеру к нему")
    else
      -- после ожидания (или большого скачка) камера сразу встаёт к герою —
      -- раньше она могла навсегда остаться на старом месте
      if S.camFrozenAt or jump > 500 then S.camSnap = true; RC.pickAt = 0 end
      S.lastBuddyLoc = bl; S.camFrozenAt = nil
    end
  end)
  -- сцена смерти: камера второго игрока стоит, где была, и гаснет вместе с
  -- экраном первого; после возрождения — появляется уже на новом месте
  if S.dyingNow then
    if not S.p2Faded then
      S.p2Faded = true
      pcall(function() S.pc2.PlayerCameraManager:StartCameraFade(0, 1, 0.7, { R = 0, G = 0, B = 0, A = 1 }, false, true) end)
      trail("вторая камера: сцена смерти — держу место и затемняю")
    end
    return
  elseif S.p2Faded then
    S.p2Faded = false; S.camSnap = true
    pcall(function() S.pc2.PlayerCameraManager:StartCameraFade(1, 0, 0.7, { R = 0, G = 0, B = 0, A = 1 }, false, false) end)
  end
  if frozen then return end
  local rloc, rrot, rfov = roomCamTarget()
  if rloc then
    local function lerp(a, c, t) return a + (c - a) * t end
    local function lerpAng(a, c, t) local d = ((c - a + 180) % 360) - 180; return a + d * t end
    local rs = S.roomSm
    if not rs or S.camSnap then rs = { x = rloc.X, y = rloc.Y, z = rloc.Z, pitch = rrot.Pitch, yaw = rrot.Yaw, fov = rfov }; S.roomSm, S.camSnap = rs, false end
    -- после смены комнаты переезжаем плавнее
    -- новая комната далеко — не «едем» через полкарты, а ставим сразу
    if dist({ X = rs.x, Y = rs.y, Z = rs.z }, rloc) > 1500 then rs.x, rs.y, rs.z, rs.pitch, rs.yaw = rloc.X, rloc.Y, rloc.Z, rrot.Pitch, rrot.Yaw end
    local k = (RC.changedAt and S.frames - RC.changedAt < 40) and 0.08 or 0.14
    rs.x, rs.y, rs.z = lerp(rs.x, rloc.X, k), lerp(rs.y, rloc.Y, k), lerp(rs.z, rloc.Z, k)
    rs.pitch, rs.yaw, rs.fov = lerpAng(rs.pitch, rrot.Pitch, k), lerpAng(rs.yaw, rrot.Yaw, k), lerp(rs.fov, rfov, k)
    local tx, ty = S.p2LookX or 0, S.p2LookY or 0
    S.p2lx = (S.p2lx or 0) + (tx - (S.p2lx or 0)) * 0.12
    S.p2ly = (S.p2ly or 0) + (ty - (S.p2ly or 0)) * 0.12
    try("cam2 room", function()
      local kp, ky = rs.pitch, rs.yaw
      pcall(function() kp, ky = S.keepInView({ X = rs.x, Y = rs.y, Z = rs.z }, rs.pitch, rs.yaw) end)
      S.cam2:K2_SetActorLocationAndRotation({ X = rs.x, Y = rs.y, Z = rs.z }, { Pitch = kp + S.p2ly * 10, Yaw = ky + S.p2lx * 15, Roll = 0 }, false, {}, false)
      local cc = S.cam2.CameraComponent
      if valid(cc) then cc:SetFieldOfView(rs.fov) end
    end)
    S.camSm = nil
    return
  end
  S.roomSm = nil
  try("cam2 update", function()
    local cm1 = S.pc1.PlayerCameraManager
    local l1, r1 = cm1:GetCameraLocation(), cm1:GetCameraRotation()
    local p1l, bl = S.p1:K2_GetActorLocation(), S.buddy:K2_GetActorLocation()
    -- Пока игрок 1 крутит СВОЮ камеру, вторая камера не повторяет это движение:
    -- держим последний «спокойный» ракурс.
    local okL, look1 = pcall(function() return S.p1:GetLookInput() end)
    local p1Looking = okL and lookMag(look1) > 0.15
    -- Ракурс второй камеры «замораживаем» в момент разделения. Камера игрока 1
    -- постоянно покачивается от бега и прыжков — это больше не передаётся.
    -- Новый ракурс берём, только если камера игрока 1 по-настоящему сменилась
    -- (другая комната: поворот больше 20° дольше секунды).
    local fresh = { dx = l1.X - p1l.X, dy = l1.Y - p1l.Y, dz = l1.Z - p1l.Z, pitch = r1.Pitch, yaw = r1.Yaw, roll = r1.Roll }
    if not S.camBase or S.camSnap then
      S.camBase, S.camDrift = fresh, 0
    elseif not p1Looking then
      local dyaw = math.abs(((fresh.yaw - S.camBase.yaw + 180) % 360) - 180)
      local dpit = math.abs(fresh.pitch - S.camBase.pitch)
      if dyaw > 20 or dpit > 15 then S.camDrift = (S.camDrift or 0) + 1 else S.camDrift = 0 end
      if S.camDrift > 60 then S.camBase, S.camDrift = fresh, 0; log("вторая камера: новый ракурс (сменилась камера комнаты)") end
    end
    local b = S.camBase
    -- Сглаживание: камера игрока 1 «гуляет» относительно своего героя, когда тот
    -- бегает и прыгает, — вторая камера не должна это повторять. Ракурс меняем
    -- очень плавно, за напарником следуем мягко (по высоте — ещё мягче).
    local function lerp(a, c, t) return a + (c - a) * t end
    local function lerpAng(a, c, t) local d = ((c - a + 180) % 360) - 180; return a + d * t end
    local sm = S.camSm
    if not sm or S.camSnap then
      sm = { dx = b.dx, dy = b.dy, dz = b.dz, pitch = b.pitch, yaw = b.yaw, bx = bl.X, by = bl.Y, bz = bl.Z }
      S.camSm, S.camSnap = sm, false
    end
    sm.dx, sm.dy, sm.dz = lerp(sm.dx, b.dx, 0.03), lerp(sm.dy, b.dy, 0.03), lerp(sm.dz, b.dz, 0.03)
    sm.pitch, sm.yaw = lerpAng(sm.pitch, b.pitch, 0.03), lerpAng(sm.yaw, b.yaw, 0.03)
    sm.bx, sm.by, sm.bz = lerp(sm.bx, bl.X, 0.18), lerp(sm.by, bl.Y, 0.18), lerp(sm.bz, bl.Z, 0.06)
    -- свой «осмотр» игрока 2 (правый стик), плавно
    local tx, ty = S.p2LookX or 0, S.p2LookY or 0
    S.p2lx = (S.p2lx or 0) + (tx - (S.p2lx or 0)) * 0.12
    S.p2ly = (S.p2ly or 0) + (ty - (S.p2ly or 0)) * 0.12
    -- v9.15.3: высоту берём не больше 2,5 м над героем: камера игрока 1
    -- бывает высоко над Low (он внизу, камера смотрит на ярус выше), и вторая
    -- камера, повторяя это, висела над Alone и смотрела ей в макушку
    local dzc = math.max(-50, math.min(CFG.cam2_max_height or 250, sm.dz))
    local loc = { X = sm.bx + sm.dx, Y = sm.by + sm.dy, Z = sm.bz + dzc }
    local kp, ky = sm.pitch, sm.yaw
    pcall(function() kp, ky = S.keepInView(loc, sm.pitch, sm.yaw) end)
    S.cam2:K2_SetActorLocationAndRotation(loc, { Pitch = kp + S.p2ly * 12, Yaw = ky + S.p2lx * 22, Roll = b.roll }, false, {}, false)
    local cc = S.cam2.CameraComponent
    if valid(cc) then cc:SetFieldOfView(cm1:GetFOVAngle()) end
  end)
end

local function updateCam2()
  -- самопроверка: вид игрока 2 должен смотреть через нашу камеру, а камера —
  -- быть рядом с героем
  if not S.nativeCam and S.split and valid(S.pc2) and valid(S.cam2) and S.frames % 60 == 0 then
    pcall(function()
      if S.pc2:GetViewTarget() ~= S.cam2 then S.pc2:SetViewTargetWithBlend(S.cam2, 0, 0, 0, false); trail("вид игрока 2: вернул на свою камеру") end
      local c2, bl = S.cam2:K2_GetActorLocation(), S.buddy:K2_GetActorLocation()
      if S.overlayOn then bl = S.toCopyOf(bl, c2) end   -- камера может быть в другой копии нарочно
      local d = dist(c2, bl)
      if d > 3000 then S.camSnap = true; S.roomSm = nil; RC.cur = nil; RC.pickAt = 0; trail(string.format("вторая камера далеко от героя (%.0f см) — переставил", d)) end
    end)
  end
  if S.nativeCam then
    if valid(S.pc2) and S.frames >= S.camCheckAt then
      S.camCheckAt = S.frames + 180
      local ok, d = pcall(function() return dist(S.pc2.PlayerCameraManager:GetCameraLocation(), S.buddy:K2_GetActorLocation()) end)
      local okt, vt = pcall(function() return S.pc2:GetViewTarget() end)
      if (okt and vt ~= S.buddy) or (ok and d > 6000) then
        log("вид игрока 2 смотрит не туда (%s, %.0f) — переподключаю", okt and clsName(vt) or "?", ok and d or -1)
        applyCam()
      elseif ok and not S.camOkLogged then S.camOkLogged = true; log("вид игрока 2 работает (игровая камера, %.0f см до героя)", d) end
    end
    return
  end
  updateCam2Pose()
  if valid(S.pc2) and valid(S.cam2) and S.frames >= S.camCheckAt then
    S.camCheckAt = S.frames + 180
    local ok, d = pcall(function() return dist(S.pc2.PlayerCameraManager:GetCameraLocation(), S.cam2:K2_GetActorLocation()) end)
    if ok and d > 100 then
      log("вид игрока 2 не совпадает с камерой (расхождение %.0f) — переподключаю", d)
      applyCam()
    elseif ok and not S.camOkLogged then S.camOkLogged = true; log("вид игрока 2 работает") end
  end
end

-- Виден ли напарник в кадре игрока 1 (доли экрана 0..1), nil — если не удалось посчитать
local projLogged = false
local VIS_LIB = nil
-- v9.15.3: ВИДИМАЯ ЧАСТЬ ЭКРАНА. Камеры игры держат пропорции кадра (16:9):
-- на мониторе с другими пропорциями (например, 4:3 — 2048x1536) сверху и
-- снизу чёрные полосы. Положение героя на экране считается по всему окну,
-- вместе с полосами, — герой в полосе «в кадре», хотя его не видно (Low был
-- на 0.89 высоты окна, а картинка кончается на 0.875). Берём пропорции
-- текущего вида камеры игрока 1 и считаем долю уже от видимой картинки.
VIS_RECT = { at = -999, x0 = 0, y0 = 0, w = 1, h = 1 }
S.visibleRect = function(W, H)
  if S.frames - VIS_RECT.at < 30 then return VIS_RECT end
  VIS_RECT.at = S.frames
  VIS_RECT.x0, VIS_RECT.y0, VIS_RECT.w, VIS_RECT.h = 0, 0, 1, 1
  if S.split then return VIS_RECT end   -- при разделении мод сам снимает «держать пропорции»
  local constrain, ar = nil, nil
  pcall(function()
    local pov = S.pc1.PlayerCameraManager.CameraCachePrivate.POV
    constrain, ar = pov.bConstrainAspectRatio, pov.AspectRatio
  end)
  if constrain == true and ar and ar > 0 then S.sharedAspect = ar elseif W and H and H > 0 then S.sharedAspect = W / H end
  if constrain == nil and not VIS_RECT.errLogged then VIS_RECT.errLogged = true; trail("экран: пропорции кадра камеры игрока 1 не прочитать — считаю по всему окну") end
  if constrain ~= true or not ar or ar <= 0 or not (W and H and W > 0 and H > 0) then return VIS_RECT end
  local va = W / H
  if va < ar - 0.01 then
    local vh = (W / ar) / H; VIS_RECT.y0, VIS_RECT.h = (1 - vh) / 2, vh       -- полосы сверху и снизу
  elseif va > ar + 0.01 then
    local vw = (H * ar) / W; VIS_RECT.x0, VIS_RECT.w = (1 - vw) / 2, vw       -- полосы по бокам
  end
  if not VIS_RECT.logged then
    VIS_RECT.logged = true
    trail(string.format("экран: окно %dx%d, кадр игры %.2f — видимая часть: по ширине %.0f%%, по высоте %.0f%%", W, H, ar, VIS_RECT.w * 100, VIS_RECT.h * 100))
  end
  return VIS_RECT
end
-- v9.15.3: БУДЕТ ЛИ ГЕРОЙ ВИДЕН НА ОБЩЕМ ЭКРАНЕ. Пока экран разделён, кадр
-- игрока 1 — половина окна с другими пропорциями, и пересчёт «с половины на
-- целый экран» ошибался (тем более с чёрными полосами 16:9 на мониторе 4:3):
-- мод объединял, на общем экране герой оказывался за краем — и снова делил,
-- по кругу. Считаем по углам от камеры игрока 1: общий кадр — это её угол
-- обзора по ширине и пропорции кадра игры (16:9) по высоте. Возвращает доли
-- от половины угла: 0 — центр, 1 — край кадра.
S.sharedAspect = 16 / 9
S.viewFrac = function(hero)
  local cm = S.pc1.PlayerCameraManager
  local cl, cr, fov = cm:GetCameraLocation(), cm:GetCameraRotation(), cm:GetFOVAngle()
  local t = S.camCopyLoc(hero)
  local yaw, pitch = math.rad(cr.Yaw), math.rad(cr.Pitch)
  local fx, fy, fz = math.cos(pitch) * math.cos(yaw), math.cos(pitch) * math.sin(yaw), math.sin(pitch)
  local rx, ry = -math.sin(yaw), math.cos(yaw)                                  -- вправо
  local ux, uy, uz = -math.sin(pitch) * math.cos(yaw), -math.sin(pitch) * math.sin(yaw), math.cos(pitch)  -- вверх
  local dx, dy, dz = t.X - cl.X, t.Y - cl.Y, t.Z - cl.Z
  local f = dx * fx + dy * fy + dz * fz
  if f <= 1 then return nil end
  local r = dx * rx + dy * ry
  local u = dx * ux + dy * uy + dz * uz
  local th = math.tan(math.rad((fov or 60) / 2))
  local tv = th / S.sharedAspect
  return (r / f) / th, (u / f) / tv
end
local function buddyScreenPos(hero)
  hero = hero or S.buddy
  local ok, res = pcall(function()
    if not valid(VIS_LIB) then VIS_LIB = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary") end
    local lib = VIS_LIB
    local vs = lib:GetViewportSize(S.pc1)
    local W, H = vs.X, vs.Y
    if not (W and H and W > 0 and H > 0) then return nil end
    if S.split then
      if S.layoutLR() then W = W / 2 else H = H / 2 end
    end
    local loc = S.camCopyLoc(hero)
    local out = {}
    local onScr = S.pc1:ProjectWorldLocationToScreen({ X = loc.X, Y = loc.Y, Z = loc.Z }, out, true)
    local x = out.X or (out[1] and out[1].X)
    local y = out.Y or (out[1] and out[1].Y)
    if not projLogged and hero == S.buddy then projLogged = true; log("проверка видимости: экран %dx%d, напарник %s (%s, %s)", W, H, tostring(onScr), tostring(x), tostring(y)) end
    if not onScr or not x or not y then return { inFront = false } end
    local r = S.visibleRect(W, H)
    return { inFront = true, x = (x / W - r.x0) / r.w, y = (y / H - r.y0) / r.h }
  end)
  if ok then return res end
  if not projLogged then projLogged = true; log("проверка видимости не удалась: %s", tostring(res)) end
  return nil
end

local VIS = { hiddenFor = 0, shownFor = 0, fallback = false }
-- Узел врага «повернуться к цели» (BPC_RotateToTargetPlayer): запоминаем,
-- у каких врагов его вызывает сама игра и с какими параметрами
S.turnSeen = {}
S.watchTurnNode = function(rc)
  if S.turnHooked then return end
  S.turnHooked = true
  pcall(function()
    rc:GetClass():ForEachFunction(function(f)
      pcall(function()
        if f:GetFName():ToString() ~= "RUN_RotateToTargetActor" then return end
        local full = f:GetFullName():gsub("^Function ", "")
        RegisterHook(full, function(ctx, ac, tc, blend, speed, dts, fnb)
          if S.turnSelf then return end
          pcall(function()
            local comp = ctx:get()
            local cls = clsName(comp:GetOwner())
            if S.turnSeen[cls] then return end
            local rec = { blend = blend:get(), speed = speed:get(), fn = fnb:get() }
            if type(rec.blend) == "number" and type(rec.speed) == "number" and type(rec.fn) == "number" then
              S.turnSeen[cls] = rec
              trail(string.format("погоня: игра поворачивает %s узлом «к цели» (%.2f/%.2f/%d)", cls, rec.blend, rec.speed, rec.fn))
            end
          end)
        end)
        trail("погоня: слежу, кого игра поворачивает узлом «к цели»")
      end)
    end)
  end)
end
local function insideBox(p, m) return p and p.inFront and p.x > m and p.x < 1 - m and p.y > m and p.y < 1 - m end

-- Заставка (ролик на движке): героями управляет «секвенсор» игры — он
-- проигрывает им анимацию, которую создаёт на лету (/Engine/Transient...).
-- В обычной игре таких анимаций у героев нет. Пока она идёт и ещё 3 с после —
-- экран не делим ни в каком режиме: два вида во время ролика роняли игру (#10).
S.inCutscene = function()
  if S.frames % 10 == 0 then
    local now = false
    for _, h in ipairs({ S.p1, S.buddy }) do
      if valid(h) then
        local ok, path = pcall(function() local m = h:GetCurrentMontage(); return valid(m) and m:GetFullName() or nil end)
        if ok and path and path:find("/Engine/Transient", 1, true) then now = true end
      end
    end
    if now then
      if not (S.cutsceneUntil and S.frames < S.cutsceneUntil) then trail("экран: идёт заставка — экран общий") end
      S.cutsceneUntil = S.frames + 180
    end
  end
  return S.cutsceneUntil ~= nil and S.frames < S.cutsceneUntil
end

-- v9.15.5: ДВЕ ВЕРСИИ УРОВНЯ ОДНА ПОВЕРХ ДРУГОЙ. В одном месте игры уровень
-- существует в двух копиях, разнесённых по высоте на ~200 м, и игра
-- показывает их наложенными в одном кадре: камера стоит в одной копии, а
-- герои ходят и перескакивают между копиями. Для мода герои оказывались в
-- 200 м от камеры и друг от друга — проверка «виден ли напарник» давала
-- мусор, экран делился, когда герои рядом. Поэтому, пока идёт наложение,
-- всё, что мод считает по положению героев (виден ли в кадре, рядом ли, в
-- какой комнате), считаем так, будто герой стоит в той же копии, что и
-- камера (для кадра) или первый герой (для «рядом» и комнат). Расстояние
-- между копиями берём из самой игры: из прыжка героя при переходе между
-- копиями или из разницы высот героев, стоящих рядом по плану.
S.copy = { gap = nil }
S.copyTick = function()
  local big = CFG.layer_overlay_gap or 10000
  pcall(function()
    local a, b = S.p1:K2_GetActorLocation(), S.buddy:K2_GetActorLocation()
    -- прыжок героя по высоте больше 100 м за кадр — переход между копиями
    for i, z in ipairs({ a.Z, b.Z }) do
      local prev = S.copy["z" .. i]
      if prev and math.abs(z - prev) > big then
        local g = math.abs(z - prev)
        if not S.copy.gap or math.abs(S.copy.gap - g) > 50 then trail(string.format("экран: герой перешёл в другую копию уровня — между копиями %.0f см", g)) end
        S.copy.gap, S.copy.est = g, false
      end
      S.copy["z" .. i] = z
    end
    local dh = math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2)
    local dz = math.abs(a.Z - b.Z)
    if dh < 3000 and dz > big and (not S.copy.gap or S.copy.est) then
      S.copy.gap, S.copy.est = dz, false
      trail(string.format("экран: герои в разных копиях уровня — между копиями %.0f см", dz))
    end
    local cl = S.pc1.PlayerCameraManager:GetCameraLocation()
    local dCam = dist(cl, a)
    -- камера в другой копии, а точного расстояния ещё нет — берём разницу
    -- высот камеры и героя (ошибка — высота камеры над героем, пара метров)
    if dCam > big and not S.copy.gap then
      S.copy.gap, S.copy.est = math.abs(cl.Z - a.Z), true
      trail(string.format("экран: камера в другой копии уровня — между копиями примерно %.0f см", S.copy.gap))
    end
    -- камера по высоте в 100+ м от любого из героев — герой в другой копии
    local on = math.abs(cl.Z - a.Z) > big or math.abs(cl.Z - b.Z) > big or (dh < 3000 and dz > big)
    if on then S.copy.untilF = S.frames + 600 end
  end)
  -- v9.15.7: кукла перешла к другому, экран разделён — первым ставим держащего
  if S.twoWorlds() and S.split and S.frames % 15 == 7 then
    -- куклы ни у кого — порядок как обычно, по тому, где стоят герои
    local hh = S.lightOwner()
    local want
    if hh then want = (hh == S.buddy) else want = S.p2Geo or false end
    if (S.p2First or false) ~= want then
      S.p2First = want
      local ok = pcall(S.setPlayerOrder, want)
      trail(string.format("два мира: %s — первая половина у %s (%s)", hh and ((S.lightHolder() and "кукла у " or "кукла рядом с ") .. heroName(hh)) or "кукла далеко от обоих", want and "второго" or "первого", ok and "ок" or "ошибка"))
    end
  end
  local on = S.copy.untilF ~= nil and S.frames < S.copy.untilF
  if on ~= (S.overlayOn or false) then
    S.overlayOn = on
    trail(on and "экран: наложенные копии уровня — считаю героев в одной копии" or "экран: наложенных копий больше нет")
    if not on then S.dollHolder = nil end
    if S.split then
      pcall(S.applySplitAspect, true)
      local hh = S.lightOwner()
      if on and hh and S.p2First ~= (hh == S.buddy) then S.p2First = (hh == S.buddy); pcall(S.setPlayerOrder, S.p2First) end
    end
  end
end
-- у кого «светлая» вещь (кукла Alone «Delusion» — с ней герой видит светлую
-- копию). Ищем среди вещей, которые игра числит за героем.
S.lightHolder = function()
  if valid(S.dollHolder) and (S.dollHolder == S.p1 or S.dollHolder == S.buddy) then return S.dollHolder end
  return nil
end
-- v9.15.7: «чья» кукла для экрана: у кого в руках, а если лежит — того героя,
-- кто к ней ближе (по плану, копии не важны): сфера вокруг неё видна в его
-- половине, и вести себя всё должно так же, как если бы он её держал
-- точка в копии уровня, где стоит камера (по высоте камеры: если точка дальше
-- 100 м по высоте — переносим на целое число шагов между копиями)
S.toCamCopy = function(p, cl)
  local gap = (S.copy and S.copy.gap) or CFG.copy_gap or 20000
  local dz = p.Z - cl.Z
  if math.abs(dz) <= (CFG.layer_overlay_gap or 10000) then return p end
  local k = math.floor(dz / gap + 0.5)
  return { X = p.X, Y = p.Y, Z = p.Z - k * gap }
end
-- v9.15.7: «два мира» для экрана — не только когда герои в разных копиях
-- уровня, но и когда рядом (до 60 м) есть кукла со сферой: её ареол движок
-- рисует, даже если в её круг ещё никто не входил
S.twoWorlds = function()
  if S.overlayOn then return true end
  if S.frames - (S.twAt or -1000) < 30 then return S.twCache end
  S.twAt = S.frames
  local on = false
  pcall(function()
    local d = S.halo and S.halo.dollActor and S.halo.dollActor() or nil
    if not valid(d) then return end
    local dl = d:K2_GetActorLocation()
    local lim = CFG.doll_world_dist or 6000
    for _, h in ipairs({ S.p1, S.buddy }) do
      local l = h:K2_GetActorLocation()
      if math.sqrt((l.X - dl.X) ^ 2 + (l.Y - dl.Y) ^ 2) < lim then on = true end
    end
  end)
  if on ~= (S.twCache or false) then trail(on and "два мира: рядом кукла со сферой — экран делю с учётом её ареола" or "два мира: куклы рядом больше нет") end
  S.twCache = on
  return on
end
S.lightOwner = function()
  local h = S.lightHolder()
  if h then return h end
  if not S.twoWorlds() then return nil end
  if S.frames - (S.ownAt or -1000) < 10 then return S.ownCache end
  S.ownAt = S.frames
  local own = nil
  pcall(function()
    local doll = S.halo and S.halo.dollActor and S.halo.dollActor() or nil
    if not valid(doll) then return end
    local dl = doll:K2_GetActorLocation()
    local function dxy(hero) local l = hero:K2_GetActorLocation(); return math.sqrt((l.X - dl.X) ^ 2 + (l.Y - dl.Y) ^ 2) end
    local d1, d2 = dxy(S.p1), dxy(S.buddy)
    -- v9.15.7: кукла лежит — первой должна быть половина, в КАДРЕ которой
    -- кукла (движок рисует ареол только в первой половине). Видна только у
    -- одного — его половина; у обоих — того, кто ближе; ни у кого — порядок
    -- как обычно (по тому, где стоят герои).
    local prev = S.ownCache
    local function seen(cl, cr, fov)
      local p = S.toCamCopy(dl, cl)
      local x, y = S.camFrac(cl, cr, fov, p)
      S.ownDbg = (S.ownDbg or "") .. (x and string.format(" (%.2f, %.2f)", x, y) or " (позади)")
      return x ~= nil and math.abs(x) <= 1.1 and math.abs(y) <= 1.1
    end
    local v1, v2 = false, false
    S.ownDbg = ""
    pcall(function() local cm = S.pc1.PlayerCameraManager; v1 = seen(cm:GetCameraLocation(), cm:GetCameraRotation(), cm:GetFOVAngle()) end)
    pcall(function() if S.split and valid(S.cam2) then v2 = seen(S.cam2:K2_GetActorLocation(), S.cam2:K2_GetActorRotation(), S.cam2.CameraComponent.FieldOfView) end end)
    if v1 and not v2 then own = S.p1; S.ownWhy = "в кадре первого"; return end
    if v2 and not v1 then own = S.buddy; S.ownWhy = "в кадре второго"; return end
    if not v1 and not v2 then own = nil; S.ownWhy = "ни в чьём кадре"; return end
    S.ownWhy = "ближе"
    own = (d2 < d1) and S.buddy or S.p1
    local hyst = CFG.doll_owner_hysteresis or 300
    if prev == S.p1 and own == S.buddy and d1 - d2 < hyst then own = S.p1 end
    if prev == S.buddy and own == S.p1 and d2 - d1 < hyst then own = S.buddy end
  end)
  if own ~= S.ownCache then
    pcall(function() trail(string.format("два мира: кукла лежит — её ареол в половине %s (%s; в кадрах первого/второго:%s)", own and heroName(own) or "ничьей", S.ownWhy or "?", S.ownDbg or "")) end)
  end
  if not own and S.split and S.frames - (S.ownDbgAt or -10000) > 300 then
    S.ownDbgAt = S.frames
    trail("два мира: кукла лежит, ни в чьём кадре —" .. (S.ownDbg or "") .. (S.halo and valid(S.halo.doll) and "" or " (куклу не нашёл)"))
  end
  S.ownCache = own
  return own
end
S.dollNear = function(h, r)
  local pat = CFG.light_item or "Delusion"
  local hl = h:K2_GetActorLocation()
  for _, a in ipairs(FindAllOf("KosmosCarriable") or {}) do
    local ok, yes = pcall(function() return valid(a) and clsName(a):find(pat, 1, true) and dist(a:K2_GetActorLocation(), hl) < r end)
    if ok and yes then return a end
  end
  return nil
end
S.dollEvent = function(h, name)
  if name:find("Pickup") then
    if S.dollNear(h, 250) and S.dollHolder ~= h then
      S.dollHolder = h
      trail("кукла: взял " .. heroName(h))
    end
  elseif name:find("Putdown") or name:find("Throw") or name:find("Drop") then
    if S.dollHolder == h then
      S.dollHolder = nil
      trail("кукла: " .. heroName(h) .. " положил(а)")
    end
  end
end
-- положение p, перенесённое в копию уровня, где находится точка ref
S.toCopyOf = function(p, ref)
  local g = S.copy.gap
  if not (S.overlayOn and g and g > 0) then return p end
  local k = math.floor((ref.Z - p.Z) / g + 0.5)
  if k == 0 then return p end
  return { X = p.X, Y = p.Y, Z = p.Z + k * g }
end
-- в какой комнате герой: в наложенных копиях зоны комнат есть только в одной
-- копии — если в копии героя комнаты нет, ищем на том же месте в другой копии
-- (раньше герой в «пустой» копии был «без комнаты», и разные комнаты не
-- замечались: первый ушёл в другую комнату — экран не делился)
S.pickRoomAnyCopy = function(p)
  local r = pickRoomCam(p)
  local g = S.overlayOn and S.copy.gap
  if r or not g then return r end
  return pickRoomCam({ X = p.X, Y = p.Y, Z = p.Z + g }) or pickRoomCam({ X = p.X, Y = p.Y, Z = p.Z - g })
end
-- где Alone для проверок «рядом» и «в какой комнате» — в копии Low
S.buddyLoc = function()
  local b = S.buddy:K2_GetActorLocation()
  if not S.overlayOn then return b end
  return S.toCopyOf(b, S.p1:K2_GetActorLocation())
end
-- где герой для проверки «виден в кадре» — в копии камеры игрока 1
S.camCopyLoc = function(hero)
  local h = hero:K2_GetActorLocation()
  if not S.overlayOn then return h end
  return S.toCopyOf(h, S.pc1.PlayerCameraManager:GetCameraLocation())
end
-- v9.15.7: ДАЛЕКО ОТ КАМЕРЫ. Камера игры следит за героем игрока 1: когда
-- он убегает, второй выходит из кадра, и экран делится. А когда далеко
-- убегает второй, он остаётся «в кадре», но крошечный — двери и мелочи,
-- которые видно только вблизи, ему не разглядеть. Сравниваем, во сколько раз
-- второй дальше от камеры, чем первый.
S.farRatio = function()
  local r, d2 = 1, 0
  pcall(function()
    local cl = S.pc1.PlayerCameraManager:GetCameraLocation()
    local d1 = dist(cl, S.camCopyLoc(S.p1))
    d2 = dist(cl, S.camCopyLoc(S.buddy))
    r = d2 / math.max(d1, 100)
  end)
  return r, d2
end
local function wantSplit()
  if S.inCutscene() then return false end
  if CFG.layer_overlay ~= false then S.copyTick() end
  local mode = CFG.split
  if mode == "always" or S.splitAlways() then return true end
  if mode == "never" then return false end
  if mode == "auto" and not VIS.fallback then
    -- в какой «комнате» (зоне камеры игры) каждый герой
    if S.frames % 10 == 0 then
      pcall(function()
        S.roomP1 = S.pickRoomAnyCopy(S.p1:K2_GetActorLocation())
        S.roomP2 = S.pickRoomAnyCopy(S.buddy:K2_GetActorLocation())
      end)
    end
    local diffRooms = valid(S.roomP1) and valid(S.roomP2) and S.roomP1 ~= S.roomP2
    if diffRooms then VIS.diffFor = (VIS.diffFor or 0) + 1; VIS.sameFor = 0 else VIS.diffFor = 0; VIS.sameFor = (VIS.sameFor or 0) + 1 end
    local p = buddyScreenPos()
    if p == nil then VIS.fallback = true; log("перехожу на разделение по расстоянию") return S.split end
    if S.split then
      -- Половинка экрана шире обычного кадра, и в неё напарник «влезает» раньше,
      -- чем влезет в целый экран. Пересчитываем положение так, как оно будет
      -- в целом кадре (берём худший случай), и объединяем только если он там уверенно.
      local function full(pp)
        if not (pp and pp.inFront) then return pp end
        -- слева/справа половина держит ширину целого кадра, а по высоте видит
        -- вдвое больше; сверху/снизу — наоборот
        if S.layoutLR() then return { inFront = true, x = pp.x, y = 0.5 + (pp.y - 0.5) * 2 }
        else return { inFront = true, x = 0.5 + (pp.x - 0.5) * 2, y = pp.y } end
      end
      local q = full(p)
      -- v9.15.3: где герои окажутся на общем экране — по углам камеры игрока 1
      -- (объединяем только с запасом: до 75% от края по ширине и высоте,
      -- а делим у самого края — иначе на границе «делится-объединяется»)
      local okA, ax, ay = pcall(S.viewFrac, S.buddy)
      if okA and ax then q = { inFront = true, x = 0.5 + ax * 0.5, y = 0.5 - ay * 0.5 } elseif okA then q = { inFront = false } end
      local raw1 = buddyScreenPos(S.p1)
      local q1 = full(raw1)
      local okB, bx, by = pcall(S.viewFrac, S.p1)
      if okB and bx then q1 = { inFront = true, x = 0.5 + bx * 0.5, y = 0.5 - by * 0.5 } elseif okB then q1 = { inFront = false } end
      local p1In = q1 == nil or insideBox(q1, 0.125)
      -- объединяем, когда герои в одной комнате и напарник уверенно в кадре,
      -- или когда они просто стоят рядом (тогда комнаты не важны)
      local close, dh, dz = false, 99999, 0
      pcall(function()
        local a, b = S.p1:K2_GetActorLocation(), S.buddyLoc()
        dh = math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2); dz = math.abs(a.Z - b.Z)
        close = dh < (CFG.merge_distance or 450) and dz < 200
      end)
      -- ролик: камера игры смотрит в сторону (зеркало, катсцена) — в её кадре нет
      -- НИ ОДНОГО героя, а сами герои рядом. Делить тут нечего, а два вида во
      -- время ролика роняли игру (issue #10, сцена с зеркалом) — объединяем.
      -- v9.15.3: только если герои стоят совсем рядом на одной высоте (ролики
      -- с движком и так ловит S.inCutscene); иначе «не видно обоих» бывает,
      -- когда второй лезет наверх, а камера игры тянется к нему
      local cutscene = dh < 250 and dz < 60 and not (p and p.inFront) and not (raw1 and raw1.inFront)
      if cutscene then
        if not VIS.cutLogged then VIS.cutLogged = true; trail("экран: в кадре нет ни одного героя, а они рядом (ролик) — объединяю") end
        VIS.shownFor = math.max(VIS.shownFor, 15)
        return false
      end
      VIS.cutLogged = false
      -- в разных комнатах экран всегда разделён, как бы близко герои ни стояли
      local farR, farD = S.farRatio()
      if diffRooms or (VIS.sameFor or 0) < 20 then VIS.shownFor = 0
      elseif farR > (CFG.merge_far_ratio or 1.4) and farD > (CFG.split_far_min or 1500) then VIS.shownFor = 0
      elseif not p1In then VIS.shownFor = 0
      elseif close then VIS.shownFor = VIS.shownFor + 2
      elseif insideBox(q, 0.125) then VIS.shownFor = VIS.shownFor + 1
      else VIS.shownFor = math.max(0, VIS.shownFor - 2) end     -- короткие «выпадения» не сбрасывают счёт
      if dh < 900 and (not VIS.mlogAt or S.frames - VIS.mlogAt > 120) then
        VIS.mlogAt = S.frames
        trail(string.format("экран: рядом (%.0f см), напарник в кадре=%s (%.2f, %.2f), разные комнаты=%s, счёт=%d",
          dh, tostring(insideBox(q, 0.05)), q and q.x or -1, q and q.y or -1, tostring(diffRooms), VIS.shownFor))
      end
      if now() - S.splitChangedAt < 1.0 then return true end   -- разделённым держим минимум 1 с
      return VIS.shownFor < 15           -- ~0,25 с
    else
      local p1 = buddyScreenPos(S.p1)
      local p1Out = p1 ~= nil and not insideBox(p1, 0.0)
      -- ролик: в кадре камеры игры нет ни одного героя, а они рядом — не делим
      -- (камера смотрит в сторону, например в зеркало; issue #10)
      -- v9.15.3: «ролик» — только когда герои вплотную на одной высоте. Раньше
      -- (до 4,5 м и 2 м по высоте) это срабатывало, когда второй лез наверх:
      -- обоих уже не видно, а экран не делился
      local close = false
      pcall(function()
        local a, b = S.p1:K2_GetActorLocation(), S.buddyLoc()
        close = math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) < 250 and math.abs(a.Z - b.Z) < 60
      end)
      if close and not (p and p.inFront) and not (p1 and p1.inFront) then
        if not VIS.cutLogged then VIS.cutLogged = true; trail("экран: в кадре нет ни одного героя, а они рядом (ролик) — не делю") end
        VIS.hiddenFor = 0
        return false
      end
      VIS.cutLogged = false
      -- v9.15.3: «виден» — с запасом от края (герой — точка у пояса, у самой
      -- рамки он уже наполовину за кадром, а сверху за кадром голова), и
      -- счёт не обнуляется, когда герой на миг заходит обратно в рамку:
      -- у края он то входит, то выходит, и раньше счёт так и не набирался
      local seen = p and p.inFront and p.x > 0.06 and p.x < 0.94 and p.y > 0.12 and p.y < 0.96
      local farR, farD = S.farRatio()
      if seen and farR > (CFG.split_far_ratio or 1.8) and farD > (CFG.split_far_min or 1500) then
        seen = false
        if not VIS.farAt or S.frames - VIS.farAt > 300 then
          VIS.farAt = S.frames
          trail(string.format("экран: второй далеко от камеры (в %.1f раза дальше первого, %.0f см) — делю", farR, farD))
        end
      end
      if seen and not p1Out then VIS.hiddenFor = math.max(0, VIS.hiddenFor - 3) else VIS.hiddenFor = VIS.hiddenFor + 1 end
      -- делим, если напарник ушёл из кадра или в другую комнату
      -- если и сам игрок 1 выпал из кадра — делим быстрее
      -- для разбора: напарник не виден, а экран не делится — почему
      if (not seen or p1Out) and (not VIS.whyAt or S.frames - VIS.whyAt > 120) then
        VIS.whyAt = S.frames
        trail(string.format("экран (общий): второй виден=%s (%s, %s, перед камерой=%s), первый за кадром=%s, счёт %d, разные комнаты %d",
          tostring(seen), p and p.x and string.format("%.2f", p.x) or "-", p and p.y and string.format("%.2f", p.y) or "-",
          tostring(p and p.inFront), tostring(p1Out), VIS.hiddenFor, VIS.diffFor or 0))
      end
      if p1Out and VIS.hiddenFor >= 8 then return true end
      return VIS.hiddenFor >= 12 or VIS.diffFor >= 20
    end
  end
  local ok, d = pcall(function() return S.p1:GetDistanceTo(S.buddy) end)
  if not ok then return S.split end
  local on = CFG.split_on_distance or 900; local off = on * 0.66
  if S.split then return d > off else return d > on end
end

-- Белая вспышка при появлении второй камеры — это «привыкание глаза» (автоэкспозиция)
-- с нуля. На первые секунды делаем его мгновенным, потом возвращаем обычным.
local function setFastExposure(fast)
  try("exposure", function()
    local cc = S.cam2.CameraComponent
    local pp = cc.PostProcessSettings
    pp.bOverride_AutoExposureSpeedUp = true
    pp.bOverride_AutoExposureSpeedDown = true
    pp.AutoExposureSpeedUp = fast and 60 or 3
    pp.AutoExposureSpeedDown = fast and 60 or 1
    pcall(function() cc.PostProcessSettings = pp end)
    cc.PostProcessBlendWeight = 1
  end)
end

-- v9.15.1 (#15): РАЗМЫТИЕ У ВТОРОГО ИГРОКА. У своей камеры игры глубина
-- резкости наводится на героя, а у нашей второй камеры — нет: резкость
-- оставалась на расстоянии из настроек уровня, и всё у игрока 2 было мыльным.
-- Наводим резкость второй камеры на героя игрока 2 (p2_depth_of_field = false
-- в settings.lua — выключить глубину резкости у второй камеры совсем).
S.cam2Focus = function()
  if not valid(S.cam2) or not valid(S.buddy) then return end
  local cc = S.cam2.CameraComponent
  if not valid(cc) then return end
  local d = dist(S.cam2:K2_GetActorLocation(), S.buddy:K2_GetActorLocation())
  local pp = cc.PostProcessSettings
  if not S.dofLogged then
    S.dofLogged = true
    pcall(function() trail(string.format("вторая камера: резкость была %s/%.0f см, диафрагма %s/%.1f; до героя %.0f см",
      tostring(pp.bOverride_DepthOfFieldFocalDistance), pp.DepthOfFieldFocalDistance or -1, tostring(pp.bOverride_DepthOfFieldFstop), pp.DepthOfFieldFstop or -1, d)) end)
  end
  local want = (CFG.p2_depth_of_field == false) and 0 or math.max(50, d)
  -- без лишних записей: только если расстояние заметно изменилось
  if pp.bOverride_DepthOfFieldFocalDistance and math.abs((pp.DepthOfFieldFocalDistance or 0) - want) < 5 then return end
  pp.bOverride_DepthOfFieldFocalDistance = true
  pp.DepthOfFieldFocalDistance = want
  pcall(function() cc.PostProcessSettings = pp end)
  cc.PostProcessBlendWeight = 1
end

-- Второй игрок создаётся ОДИН раз и дальше не удаляется (частое создание/удаление
-- игроков роняло игру). Когда экран общий — у второго «экрана» просто отключаем
-- контроллер, и движок его не рисует.
-- КАК ДЕЛИТЬ. В момент разделения смотрим, где герои на общем экране:
-- разошлись в стороны — экран делится слева/справа, по высоте — сверху/снизу.
-- Каждый получает ту половину, с какой стороны он находится.
S.decideSplitSides = function()
  S.splitLR, S.p2First = nil, false
  if CFG.split_layout_force == "left_right" or CFG.split_layout_force == "top_bottom" then return end
  pcall(function()
    local vs = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary"):GetViewportSize(S.pc1)
    local function sp(h) local out = {}; local on = S.pc1:ProjectWorldLocationToScreen(S.camCopyLoc(h), out, true); return out.X, out.Y end
    local ax, ay = sp(S.p1); local bx, by = sp(S.buddy)
    if not (ax and ay and bx and by) then return end
    local dx, dy = bx - ax, by - ay          -- в пикселях: сравнимо по обеим осям
    -- v9.15.7: убегание ВГЛУБЬ кадра на экране почти не видно (вдали всё
    -- сжимается), и раньше выходило «слева/справа», хотя герой убежал «вверх».
    -- Сравниваем в мире, в плоскости камеры: вбок (вдоль «вправо» камеры)
    -- против «вглубь + вверх».
    pcall(function()
      local cm = S.pc1.PlayerCameraManager
      local yaw = math.rad(cm:GetCameraRotation().Yaw)
      local a, b = S.camCopyLoc(S.p1), S.camCopyLoc(S.buddy)
      local wx, wy, wz = b.X - a.X, b.Y - a.Y, b.Z - a.Z
      local side = wx * (-math.sin(yaw)) + wy * math.cos(yaw)       -- вправо
      local depth = wx * math.cos(yaw) + wy * math.sin(yaw)          -- от камеры
      local up = math.sqrt(depth * depth + wz * wz) * ((depth + wz) >= 0 and 1 or -1)
      if math.abs(up) > math.abs(side) * 1.2 then
        -- на экране «вверх» — отрицательный dy
        dx, dy = side, -up
        S.splitWhy = string.format("в мире: вбок %.0f, вглубь/вверх %.0f", side, up)
      else
        S.splitWhy = nil
      end
    end)
    S.splitLR = math.abs(dx) >= math.abs(dy)
    local forced = S.sidesForced(); if forced ~= nil then S.splitLR = forced end
    S.p2First = S.splitLR and (dx < 0) or (not S.splitLR and dy < 0)
    -- v9.15.5: в наложенных копиях игрок 1 всегда первый по порядку: если
    -- первым стоит игрок 2, игра отдаёт ему камеру и видимость героев.
    -- v9.15.7: светлое пятно движок рисует только в первой половине экрана —
    -- первым ставим того, у кого кукла
    S.p2Geo = S.p2First
    if S.twoWorlds() then
      local hh = S.lightOwner()
      if hh then S.p2First = (hh == S.buddy) end
    end
    if S.splitWhy then trail("экран: решаю по положению в мире (" .. S.splitWhy .. ")") end
    trail(string.format("экран: второй %s первого (dx=%.0f, dy=%.0f) — делю %s, второй %s",
      S.splitLR and (dx < 0 and "левее" or "правее") or (dy < 0 and "выше" or "ниже"), dx, dy,
      S.splitLR and "слева/справа" or "сверху/снизу", S.p2First and (S.splitLR and "слева" or "сверху") or (S.splitLR and "справа" or "снизу")))
  end)
end
-- Без чёрных полос: камерам разрешаем подстраиваться под форму половины
-- экрана. Слева/справа сохраняется горизонтальный обзор, сверху/снизу —
-- вертикальный: герой не выходит из кадра раньше, чем на целом экране.
S.applySplitAspect = function(on)
  S.aspectSaved = S.aspectSaved or { lp = {}, cams = {} }
  local A = S.aspectSaved
  local lps = {}
  pcall(function() lps[#lps + 1] = S.pc1.Player end)
  if valid(S.lp2) then lps[#lps + 1] = S.lp2 end
  for _, lp in ipairs(lps) do
    pcall(function()
      local key = lp:GetFullName()
      if on then
        if A.lp[key] == nil then A.lp[key] = lp.AspectRatioAxisConstraint end
        -- держим обзор по той стороне, которая у половины стала меньше: слева/справа —
        -- ширину (1), сверху/снизу — высоту (0). Тогда в половину помещается не
        -- меньше, чем на целом экране, а по другой стороне видно даже больше.
        lp.AspectRatioAxisConstraint = S.layoutLR() and 1 or 0
      elseif A.lp[key] ~= nil then
        lp.AspectRatioAxisConstraint = A.lp[key]; A.lp[key] = nil
      end
    end)
  end
  if on then
    for _, c in ipairs(FindAllOf("CameraComponent") or {}) do
      pcall(function()
        if valid(c) and c.bConstrainAspectRatio then
          -- пропорции кадра запоминаем числом сразу: камеры выгруженных
          -- комнат потом удаляются, и читать их позже нельзя (вылет)
          local ar = c.AspectRatio
          if type(ar) == "number" and ar > 0.5 and ar < 4 then
            A.ar = A.ar or {}
            local k = string.format("%.3f", ar)
            A.ar[k] = (A.ar[k] or 0) + 1
          end
          A.cams[#A.cams + 1] = c; c.bConstrainAspectRatio = false
        end
      end)
    end
  else
    for _, c in ipairs(A.cams) do pcall(function() if valid(c) then c.bConstrainAspectRatio = true end end) end
    A.cams = {}
  end
end
-- Движок раскладывает половины экрана по порядку локальных игроков: первый
-- в списке — слева/сверху. Origin он пересчитывает каждый кадр, поэтому
-- меняем местами самих игроков в списке. Геймпады движок ищет по номеру
-- контроллера, а не по месту в списке, так что люди, герои и геймпады
-- остаются при своих — меняются только половины экрана.
S.localPlayers = function()
  local gi = nil
  pcall(function() gi = S.pc1:GetGameInstance() end)
  if not valid(gi) then pcall(function() gi = FindFirstOf("GameInstance") end) end
  if not valid(gi) then return nil end
  local arr = nil; pcall(function() arr = gi.LocalPlayers end)
  return arr
end
-- перед загрузкой уровня порядок игроков всегда возвращаем обычный: движок
-- раздаёт новые контроллеры по этому списку
pcall(function()
  RegisterLoadMapPreHook(function()
    if S.playersSwapped then pcall(S.setPlayerOrder, false) end
  end)
end)
S.setPlayerOrder = function(p2First)
  local arr = S.localPlayers()
  if not arr then return end
  local lp1 = nil; pcall(function() lp1 = S.pc1.Player end)
  local lp2 = S.lp2
  if not (valid(lp1) and valid(lp2)) then return end
  local n = 0; pcall(function() n = arr:GetArrayNum() end)
  if n ~= 2 then return end
  local a1, a2 = arr[1], arr[2]
  local firstIsP2 = valid(a1) and a1:GetAddress() == lp2:GetAddress()
  if firstIsP2 == (p2First and true or false) then return end
  local want1, want2 = (p2First and lp2 or lp1), (p2First and lp1 or lp2)
  local ok, err = pcall(function() arr[1] = want1; arr[2] = want2 end)
  local now1 = nil; pcall(function() now1 = arr[1] end)
  local held = valid(now1) and now1:GetAddress() == want1:GetAddress()
  S.playersSwapped = held and p2First or false
  trail(string.format("экран: порядок игроков %s — %s%s", p2First and "второй первым" or "обычный",
    held and "получилось" or "не получилось", ok and "" or (" (" .. tostring(err) .. ")")))
end
setSplitVisible = function(on)
  try("split visible", function()
    local g = gms()
    g.TwoPlayerSplitscreenLayout = S.layoutLR() and 1 or 0
    g.bUseSplitscreen = on
    local lp2 = S.lp2
    if valid(lp2) then
      -- С геймпадом второй игрок должен оставаться подключённым, иначе движок
      -- выбрасывает нажатия его геймпада. Без разделения движок и так рисует
      -- только первого игрока. С клавиатурой отключаем, как раньше (проверено).
      if on or CFG.device == "gamepad" then lp2.PlayerController = S.pc2
      else
        local ok = pcall(function() lp2.PlayerController = nil end)
        if not ok then lp2.PlayerController = CreateInvalidObject() end
      end
    end
  end)
  S.split = on
  if not on then
    pcall(S.applySplitAspect, false); S.splitLR, S.p2First = nil, false
    if S.playersSwapped then pcall(S.setPlayerOrder, false) end
  end
end

local function applyGamepadRouting()
  try("gamepad offset", function() gms().bOffsetPlayerGamepadIds = CFG.gamepad_goes_to_player2 end)
  if S.coop and setSplitVisible then setSplitVisible(S.split) end
end

local function updateSplit()
  if not usablePC2(S.pc2) then
    -- для разбора: вид игрока 2 не готов — делить нечем
    if not S.pc2WhyAt or S.frames - S.pc2WhyAt > 300 then
      S.pc2WhyAt = S.frames
      local a, b = "?", "?"
      pcall(function() a = tostring(valid(S.pc2)) end)
      pcall(function() b = tostring(valid(S.pc2.Player)) .. "/" .. tostring(valid(S.pc2.PlayerCameraManager)) end)
      trail("экран: вид игрока 2 не готов (контроллер " .. a .. ", игрок/камера " .. b .. ") — разделить нельзя")
    end
    return
  end
  if S.exposureResetAt and S.frames >= S.exposureResetAt then S.exposureResetAt = nil; if not S.nativeCam then setFastExposure(false) end end
  if S.split and not S.nativeCam and S.frames % 4 == 1 then
    local okF, eF = pcall(S.cam2Focus)
    if not okF and not S.dofErr then S.dofErr = true; trail("вторая камера: резкость — ошибка " .. tostring(eF)) end
  end
  -- камеры новых комнат, подгрузившихся при разделённом экране, — тоже без полос
  if S.split and S.frames % 120 == 0 then pcall(S.applySplitAspect, true) end
  local want = wantSplit()
  if want and not S.split and (not S.wantWhyAt or S.frames - S.wantWhyAt > 120) and now() - S.splitChangedAt < 1.0 then
    S.wantWhyAt = S.frames
    trail(string.format("экран: хочу разделить, но после прошлого переключения прошло %.1f с", now() - S.splitChangedAt))
  end
  if want == S.split or now() - S.splitChangedAt < 1.0 then return end
  S.splitChangedAt = now()
  if want then
    if not S.nativeCam then
      -- v9.15.2: в момент разделения сразу берём камеру комнаты, где стоит
      -- Alone (без «липкой» прежней) — иначе первую секунду показывалась
      -- камера комнаты Low, а потом картинка перескакивала
      RC.cur, RC.pickAt, RC.pending, RC.pendingAt, RC.pendingFor = nil, 0, nil, nil, 0
      S.camSnap = true; updateCam2Pose(); setFastExposure(true); S.exposureResetAt = S.frames + 120
      try("pc2 ViewTarget", function() S.pc2:SetViewTargetWithBlend(S.cam2, 0, 0, 0, false) end)
    end
  end
  VIS.hiddenFor, VIS.shownFor = 0, 0
  -- каждый игрок — на своей половине (выключается split_swap_sides = false)
  if want then
    pcall(function()
      local n = 0; local arr = S.localPlayers(); if arr then n = arr:GetArrayNum() end
      if n > 2 then
        local parts = {}
        for i = 1, n do
          pcall(function()
            local lp = arr[i]; local pc = lp.PlayerController
            parts[#parts + 1] = string.format("%d: контроллер %s%s", i, tostring(lp.ControllerId), (pc == S.pc1 and " (игрок 1)") or (pc == S.pc2 and " (игрок 2)") or (valid(pc) and " (лишний)") or " (без контроллера)")
          end)
        end
        trail(string.format("экран: локальных игроков %d вместо 2 (%s) — убираю лишних", n, table.concat(parts, ", ")))
        S.pruneLocalPlayers(S.pc2, "перед разделением экрана")
      end
    end)
    pcall(S.decideSplitSides); if CFG.split_swap_sides ~= false then pcall(S.setPlayerOrder, S.p2First) end
  end
  setSplitVisible(want)
  pcall(S.applySplitAspect, want)
  if not want then S.splitLR, S.p2First = nil, false; S.cam2External = nil end
  log(want and "экран разделён" or "экран общий")
  -- для разбора пропажи звука: состояние звука сразу и через 2 и 6 с
  S.audioProbe = { S.frames + 1, S.frames + 120, S.frames + 360 }
end

------------------------------------------------------------------ кооператив вкл/выкл
local function cname(o) if not valid(o) then return "nil" end local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end) return ok and n or "?" end
-- для разбора: кто кем управляет, если двух героев найти не удалось
local function dumpHeroes(why)
  if S.lastDump and now() - S.lastDump < 15 then return end
  S.lastDump = now()
  local out = { "герои: " .. why }
  for _, pc in ipairs(FindAllOf("Controller") or {}) do
    if valid(pc) then
      local okp, pawn = pcall(function() return pc.Pawn end)
      local okc, cid = pcall(function() return pc.Player.ControllerId end)
      out[#out + 1] = string.format("  контроллер %s id=%s пешка=%s", cname(pc), okc and tostring(cid) or "-", okp and cname(pawn) or "?")
    end
  end
  for _, h in ipairs(S.heroList()) do
    if valid(h) then
      local okc, c = pcall(function() return h.Controller end)
      out[#out + 1] = string.format("  герой %s %s управляет=%s", cname(h), h:GetFName():ToString(), okc and cname(c) or "?")
    end
  end
  -- для дополнений: если героев не нашлось — кто вообще есть из персонажей
  if #S.heroList() == 0 then
    local seen = {}
    for _, ch in ipairs(FindAllOf("KosmosBaseCharacter") or {}) do pcall(function() seen[#seen + 1] = cname(ch) end) end
    out[#out + 1] = "  персонажи: " .. (#seen > 0 and table.concat(seen, ", ") or "нет")
  end
  log("%s", table.concat(out, "\n"))
end
local function acquire()
  S.pc1 = findPC1(); if not valid(S.pc1) then dumpHeroes("не нашёл — нет игрока 1"); return false end
  S.p1 = S.pc1.Pawn; if not isHero(S.p1) then dumpHeroes("не нашёл — игрок 1 не герой: " .. cname(S.p1)); return false end
  local ai, buddy = findBuddy(S.p1)
  if not buddy then
    -- запасной путь: второй герой, которым управляет любой ИИ-контроллер
    for _, h in ipairs(S.heroList()) do
      if valid(h) and h ~= S.p1 then
        local okc, c = pcall(function() return h.Controller end)
        if okc and valid(c) and c:IsA(StaticFindObject("/Script/AIModule.AIController")) then ai, buddy = c, h end
      end
    end
  end
  if not buddy and valid(S.pc2) then
    -- в режиме «настоящего второго игрока» напарником уже управляет игрок 2
    local okb, pb = pcall(function() return S.pc2.Pawn end)
    if okb and isHero(pb) and pb ~= S.p1 then
      buddy = pb
      ai = valid(S.ai) and S.ai or nil
      if not ai then
        for _, a in ipairs(FindAllOf("KosmosAIController") or {}) do
          local okp, ap = pcall(function() return a.Pawn end)
          if valid(a) and okp and not valid(ap) then ai = a end
        end
      end
    end
  end
  if not buddy then dumpHeroes("не нашёл — нет напарника-ИИ"); return false end
  S.ai, S.buddy, S.prev, S.weaponOut = ai, buddy, {}, false
  if valid(ai) then
    local okp, ap = pcall(function() return ai.Pawn end)
    if okp and valid(ap) then setBrain(ai, false)
    else pcall(function() ai:SetActorTickEnabled(false) end) end  -- контроллер без героя трогать нельзя
  end
  log("Игрок 1: %s | Игрок 2: %s", heroName(S.p1), heroName(buddy))
  pcall(function() S.p1HeroClass = S.p1:GetClass():GetFName():ToString() end)
  return true
end

local function resetBuddyInput()
  if valid(S.buddy) then
    try("reset input", function() S.buddy:AI_SetRawInput({ X = 0, Y = 0, Z = 0 }) end)
    try("reset grab", function() S.buddy:AI_SetRawPressedInteract(false) end)
    try("reset sprint", function() S.buddy:PlaypalSetSprint(false) end)
  end
  S.prev = {}
end


------------------------------------------------------------------ язык интерфейса мода
-- Тексты мода написаны по-русски. Если игра не на русском — показываем
-- английский перевод. Язык берём у самой игры (можно задать в settings.lua:
-- language = "ru" / "en").
S.EN = {
  ["Сначала включите второго игрока"] = "Turn on Player 2 first",
  ["Нажимайте A на геймпаде игрока 2…"] = "Press A on Player 2's gamepad…",
  ["Геймпад игрока 2 найден!"] = "Player 2's gamepad found!",
  ["Геймпад игрока 2 не отвечает — проверьте подключение"] = "Player 2's gamepad is not responding — check the connection",
  ["Не нашёл двух героев — загрузите игру"] = "Couldn't find both heroes — load a game first",
  ["Игрок 2 подключён"] = "Player 2 joined",
  ["Игра будет вдвоём"] = "The game will be two-player", ["Сначала уберите вещь из рук"] = "Put the item away first", ["Подсадить может только второй игрок"] = "Only Player 2 can give the boost", ["Игра будет на одного"] = "The game will be single-player",
  ["Напарником снова управляет ИИ"] = "The AI controls the companion again",
  ["Настройки сброшены"] = "Settings reset",
  ["Назначено"] = "Assigned",
  ["Закройте паузу и нажимайте A на геймпаде игрока 2"] = "Close the pause menu and press A on Player 2's gamepad",
  ["Кооператив"] = "Co-op",
  ["КООПЕРАТИВ — LN3Couch"] = "CO-OP — LN3Couch",
  ["Второй игрок"] = "Player 2",
  ["ВКЛЮЧЁН"] = "ON", ["включён"] = "on", ["выключен"] = "off",
  ["Управление игрока 2"] = "Player 2 controls",
  ["Клавиатура (правая часть)"] = "Keyboard (right side)", ["Геймпад"] = "Gamepad",
  ["Геймпад №1 у"] = "Gamepad #1 belongs to", ["игрока 1"] = "Player 1", ["игрока 2"] = "Player 2",
  ["Найти геймпад игрока 2"] = "Find Player 2's gamepad",
  ["Экран"] = "Screen",
  ["Авто (когда не видно)"] = "Auto (split when needed)", ["По расстоянию"] = "By distance",
  ["Всегда разделён"] = "Always split", ["Всегда общий"] = "Always shared",
  ["Разделение"] = "Split", ["Авто (как стоят герои)"] = "Auto (by where heroes are)", ["Горизонтально"] = "Horizontal", ["Вертикально"] = "Vertical",
  ["Всегда горизонтально"] = "Always horizontal", ["Всегда вертикально"] = "Always vertical",
  ["Делить экран с расстояния"] = "Split at distance", ["Делить экран с"] = "Split at",
  ["Кнопки игрока 2  >"] = "Player 2 buttons  >", ["Кнопки игрока 2"] = "Player 2 buttons",
  ["Сбросить настройки"] = "Reset settings", ["Метка записана"] = "Marker saved", ["Закрыть  (F9)"] = "Close  (F9)",
  ["Назад"] = "Back", ["<  Назад"] = "<  Back",
  ["КНОПКИ ИГРОКА 2 — геймпад"] = "PLAYER 2 BUTTONS — gamepad", ["КЛАВИШИ ИГРОКА 2 — клавиатура"] = "PLAYER 2 KEYS — keyboard",
  ["Ходьба"] = "Move", ["левый стик"] = "left stick",
  ["…нажмите кнопку"] = "…press a button", ["по умолчанию"] = "default",
  ["Вперёд"] = "Forward", ["Влево"] = "Left", ["Вправо"] = "Right", ["Прыжок"] = "Jump",
  ["Схватить / нести (держать)"] = "Grab / carry (hold)", ["Бросить (или прыжок с предметом)"] = "Throw (or jump while carrying)",
  ["Достать/убрать ключ или лук"] = "Take out / put away wrench or bow", ["Присесть (держать)"] = "Crouch (hold)", ["Бег (держать)"] = "Run (hold)",
  ["Стрелка вверх"] = "Up arrow", ["Стрелка вниз"] = "Down arrow", ["Стрелка влево"] = "Left arrow", ["Стрелка вправо"] = "Right arrow",
  ["Пробел"] = "Space", ["Правый Shift"] = "Right Shift", ["Левый Shift"] = "Left Shift",
  ["Правый Ctrl"] = "Right Ctrl", ["Левый Ctrl"] = "Left Ctrl", ["Правый Alt"] = "Right Alt", ["Левый Alt"] = "Left Alt",
  ["A / Крест"] = "A / Cross", ["B / Круг"] = "B / Circle", ["X / Квадрат"] = "X / Square", ["Y / Треугольник"] = "Y / Triangle",
  ["Нажмите кнопку для назначения.  Backspace — отмена"] = "Press a button to assign.  Backspace — cancel",
  ["Стрелки — выбор,  ← → изменить,  Enter — выбрать,  Backspace — назад,  F9 — закрыть"] = "Arrows — select,  ← → change,  Enter — choose,  Backspace — back,  F9 — close",
}
S.gameLanguage = function()
  if S.lang then return S.lang end
  local want = CFG and CFG.language
  if want == "ru" or want == "en" then S.lang = want; return want end
  local code = nil
  pcall(function()
    local lib = StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary")
    local r = lib:GetCurrentLanguage()
    if type(r) == "string" then code = r else code = r:ToString() end
  end)
  if not code or code == "" then
    pcall(function()
      local lib = StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary")
      local r = lib:GetCurrentCulture()
      if type(r) == "string" then code = r else code = r:ToString() end
    end)
  end
  if not code or code == "" then return "ru" end   -- не узнали — не запоминаем, спросим позже
  S.lang = (code:sub(1, 2):lower() == "ru") and "ru" or "en"
  pcall(function() log("язык интерфейса мода: %s (язык игры %s)", S.lang, code) end)
  return S.lang
end
-- Разовая выгрузка таблиц строк игры (для перевода меню мода словами самой
-- игры). Пишется один раз в ue4ss/Mods/LN3Couch/game_strings.txt.
S.dumpStrings = function()
  if S.stringsDumped then return end
  S.stringsDumped = true
  local path = "ue4ss/Mods/LN3Couch/game_strings.txt"
  local ex = io.open(path, "r"); if ex then ex:close(); return end
  local lib = StaticFindObject("/Script/Engine.Default__KismetStringTableLibrary")
  if not valid(lib) then log("таблицы строк: библиотека не найдена"); return end
  local function list(x)
    local out = {}
    if type(x) == "table" then for _, v in ipairs(x) do out[#out + 1] = v end
    elseif x then pcall(function() x:ForEach(function(_, el) out[#out + 1] = el:get() end) end) end
    return out
  end
  local function str(v) if type(v) == "string" then return v end local ok, r = pcall(function() return v:ToString() end); return ok and r or tostring(v) end
  local f = io.open(path, "w"); if not f then return end
  f:write("-- таблицы строк игры: таблица | ключ | исходный текст | текст на текущем языке\n")
  local nT, nK = 0, 0
  pcall(function()
    for _, tid in ipairs(list(lib:GetRegisteredStringTables())) do
      nT = nT + 1
      local tname = str(tid)
      for _, key in ipairs(list(lib:GetKeysFromStringTable(tid))) do
        local kname = str(key)
        local src, loc = "", ""
        pcall(function() src = str(lib:GetTableEntrySourceString(tid, key)) end)
        pcall(function() loc = StaticFindObject("/Script/Engine.Default__KismetTextLibrary"):TextFromStringTable(tid, key):ToString() end)
        f:write(tname, " | ", kname, " | ", (src:gsub("\n", "\\n")), " | ", (loc:gsub("\n", "\\n")), "\n")
        nK = nK + 1
      end
    end
  end)
  f:close()
  log("таблицы строк игры: %d таблиц, %d строк — записал в game_strings.txt", nT, nK)
end
-- Слова самой игры. Надпись на кнопке игры приходит уже на языке игры,
-- поэтому для любого языка берём её прямо с экрана: ищем кнопку по её
-- внутреннему имени (оно от языка не зависит) и запоминаем надпись.
-- Пока нужная кнопка не встречалась — английский текст мода.
S.GAME_WORDS = {
  ["Назад"] = "ButtonPromptOverlay%.WidgetTree%.HUD_RightButton%.WidgetTree%.NormalText$",
  ["<  Назад"] = "ButtonPromptOverlay%.WidgetTree%.HUD_RightButton%.WidgetTree%.NormalText$",
  ["Сбросить настройки"] = "SettingsMenuWidget_C%.WidgetTree%.AreYouSureReset%.WidgetTree%.Comment%.WidgetTree%.txt_TITle$",
  ["Закрыть  (F9)"] = "ButtonPromptOverlay%.WidgetTree%.HUD_RightButton%.WidgetTree%.NormalText$",
}
S.PLACEHOLDERS = { ["SMG Text Block"] = true, ["DefaultText"] = true, ["Test Text"] = true, ["Testser"] = true }
S.langCode = function()
  local code = nil
  pcall(function()
    local r = StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary"):GetCurrentLanguage()
    code = type(r) == "string" and r or r:ToString()
  end)
  return code
end
S.harvestWords = function()
  local code = S.langCode()
  if not code or code == "" then return end
  CFG.game_words = CFG.game_words or {}
  local gw = CFG.game_words
  if gw.lang ~= code then
    -- язык игры поменялся: старые слова не годятся, язык мода выбираем заново
    CFG.game_words = { lang = code, w = {} }; gw = CFG.game_words; S.lang = nil
  end
  gw.w = gw.w or {}
  local need = false
  for k in pairs(S.GAME_WORDS) do if not gw.w[k] then need = true end end
  if not need then return end
  local changed = false
  for _, tb in ipairs(FindAllOf("TextBlock") or {}) do
    if valid(tb) then
      local okn, full = pcall(function() return tb:GetFullName() end)
      local path = (okn and full or ""):gsub("_%d%d%d%d+", "")
      for k, pat in pairs(S.GAME_WORDS) do
        if not gw.w[k] and path:find(pat) then
          local t = S.uiText(tb)
          if t and not S.PLACEHOLDERS[t] then
            t = t:gsub("%?$", ""):gsub("\\n.*$", "")
            if k == "<  Назад" then t = "<  " .. t end
            if k == "Закрыть  (F9)" then t = t .. "  (F9)" end
            gw.w[k] = t; changed = true
          end
        end
      end
    end
  end
  if changed then saveSettings(); log("слова игры (%s): обновлены", code) end
end
S.T = function(s)
  if type(s) ~= "string" or s == "" or S.gameLanguage() == "ru" then return s end
  local gw = CFG.game_words
  if gw and gw.w and gw.w[s] then return gw.w[s] end
  if S.EN[s] then return S.EN[s] end
  local a, b = s:match("^(.-): (.*)$")
  if a then return S.T(a) .. ": " .. S.T(b) end
  local n = s:match("^(%d+) м$"); if n then return n .. " m" end
  local k = s:match("^Цифр%. (.*)$"); if k then return "Num " .. k end
  return s
end
local function toast(msg) S.toast, S.toastUntil = S.T(msg), now() + 2.5 end

-- Режим «настоящий второй игрок»: героем напарника управляет второй
-- игровой контроллер — как у игрока 1, со всеми действиями игры (ящики,
-- рычаги, лестницы, оружие). Нужен геймпад у игрока 2.
local function wantReal() return CFG.device == "gamepad" and CFG.p2_mode ~= "ai" end
local function buddyOwned()
  local ok, c = pcall(function() return S.buddy.Controller end)
  if not ok then return false end
  if S.real then return c == S.pc2 end
  return valid(S.ai) and c == S.ai
end
local AUDIO = {}
local function audioMgr()
  local ok, m = pcall(function() return FindFirstOf("KosmosAudioManagerActor") end)
  if ok and valid(m) then return m end
end
local function listenerOwner()
  local m = audioMgr(); if not m then return nil end
  local ok, owner = pcall(function() return m:GetDefaultListenerComponent():GetOwner() end)
  if ok and valid(owner) then return owner end
end
local function rememberListener()
  local o = listenerOwner()
  if o then AUDIO.owner = o; trail("звук: слушатель " .. cname(o)) end
end
-- Фоновый звук игра включает при входе слушателя в «звуковую зону» комнаты.
-- Пока слушатель был у второго вида, он «вышел» из зоны, и звук затих; когда
-- мы вернули слушателя, повторного входа не было. Сообщаем игре о зоне сами.
local function refreshAmbience()
  local lib = StaticFindObject("/Script/Kosmos.Default__KosmosAudioBlueprintLibrary")
  local m = audioMgr()
  if not (valid(lib) and m) then return end
  local okv, av = pcall(function() return lib:GetActiveAudioVolume(S.pc1) end)
  if not (okv and valid(av)) and valid(S.p1) then
    -- запасной путь: зона, в которой стоит игрок 1
    local pl = S.p1:K2_GetActorLocation()
    for _, v in ipairs(FindAllOf("KosmosAudioVolume") or {}) do
      local t = {}
      local oke, inside = pcall(function() return v:EncompassesPoint(pl, 0, t) end)
      if oke and inside then av = v; break end
    end
  end
  if valid(av) then
    -- «выйти» в другую зону и сразу «войти» обратно — иначе игра считает,
    -- что ничего не поменялось, и звук не включает
    local other = nil
    if other then try("AV out", function() m:OnAudioVolumeTransition(other) end) end
    local target = av
    local function back()
      try("AV in", function() m:OnAudioVolumeTransition(target) end)
      local okm, muted = pcall(function() return target.mIsMuted end)
      local oka, act = pcall(function() return target.mIsActiveVolume end)
      trail(string.format("звук: зона %s активна=%s заглушена=%s", target:GetFName():ToString(), tostring(oka and act), tostring(okm and muted)))
    end
    if other and ExecuteWithDelay then ExecuteWithDelay(250, function() ExecuteInGameThread(function() pcall(back) end) end) else back() end
    log("звук: заново включил звуковую зону %s", av:GetFName():ToString())
  else
    log("звук: не нашёл звуковую зону")
  end
end
-- убираем «уши» второго вида, чтобы звук слушался только у игрока 1
local function dropP2Listeners()
  if not valid(S.pc2) then return end
  local cm2 = nil
  pcall(function() cm2 = S.pc2.PlayerCameraManager end)
  local n = 0
  for _, c in ipairs(FindAllOf("AkComponent") or {}) do
    local ok, owner = pcall(function() return c:GetOwner() end)
    if ok and valid(owner) and (owner == S.pc2 or owner == cm2) then
      pcall(function() c:K2_DestroyComponent(c) end); n = n + 1
    end
  end
  if n > 0 then log("звук: убрал %d «уха» второго вида", n) end
end
-- Главная причина пропажи фона: когда появляется второй игрок, игра делает
-- «ушами» его камеру, а фоновые звуки едут за «ушами». Перехватываем этот
-- вызов игры и подставляем камеру игрока 1 — тогда «уши» вообще не меняются.
S.listenerHookOk = pcall(function()
  RegisterHook("/Script/Kosmos.KosmosAudioBlueprintLibrary:RegisterDefaultListener", function(ctx, worldCtx, attachment)
    if not S.coop or not valid(AUDIO.owner) then return end
    local okg, a = pcall(function() return attachment:get() end)
    if okg and a ~= AUDIO.owner then
      local isP2 = false
      pcall(function() isP2 = (a == S.pc2) or (a == S.pc2.PlayerCameraManager) or (a == S.cam2) end)
      if isP2 or not valid(a) then
        pcall(function() attachment:set(AUDIO.owner) end)
        if not S.listenerHookLogged then S.listenerHookLogged = true; log("звук: игра хотела сделать «ушами» второй вид — оставил у игрока 1") end
      end
    end
  end)
end)
-- Записываем, какие «общие» звуки игра включает (фон уровня, музыка), чтобы
-- после переключения «ушей» включить их заново — так же, как это делает игра
-- после возрождения.
S.audioCalls = S.audioCalls or {}
for _, fn in ipairs({ "PostGlobalAmbience", "SetGlobalAudioSettings", "PostGlobalMusic", "PostMusicPlayback", "StopGlobalMusic", "StartGlobalMusic" }) do
  pcall(function()
    RegisterHook("/Script/Kosmos.KosmosAudioBlueprintLibrary:" .. fn, function(ctx, a1, a2, a3, a4, a5)
      local args = {}
      for _, a in ipairs({ a1, a2, a3, a4, a5 }) do
        local okg, v = pcall(function() return a:get() end)
        args[#args + 1] = okg and v or nil
      end
      S.audioCalls[fn] = args
      -- имя спрашиваем, только если это настоящий живой объект: в некоторых
      -- главах игра передаёт сюда пустой/не-объектный параметр, и запрос
      -- имени у него роняет загрузчик модов
      local n = nil
      local a2 = args[2]
      if type(a2) == "userdata" and valid(a2) then
        pcall(function() n = a2:GetFName():ToString() end)
      end
      trail("звук: игра вызвала " .. fn .. (n and (" (" .. n .. ")") or ""))
    end)
  end)
end
-- Для разбора звука: все вызовы звуковой системы игры и Wwise (кроме опросов
-- Get/Is/Has), не больше 3 записей на функцию за 10 с. Включается
-- audio_trace = true в settings.lua.
S.audioTraceArg = function(v)
  if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then return tostring(v) end
  if type(v) ~= "userdata" then return nil end
  local okt, t = pcall(function() return v:type() end)
  if okt and (t == "FName" or t == "FString" or t == "FText") then
    local oks, str = pcall(function() return v:ToString() end)
    if oks then return str end
  end
  -- объект (например, звуковое событие): только живой, и только имя
  if okt and type(t) == "string" and t ~= "FName" and t ~= "FString" and t ~= "FText" and valid(v) then
    local okn, nm = pcall(function() return v:GetFName():ToString() end)
    if okn then return nm end
  end
  return nil
end
S.installAudioTrace = function()
  if S.audioTraceOn or CFG.audio_trace ~= true then return end
  S.audioTraceOn = true
  local skip = { PostGlobalAmbience = 1, SetGlobalAudioSettings = 1, PostGlobalMusic = 1, PostMusicPlayback = 1,
    StopGlobalMusic = 1, StartGlobalMusic = 1, RegisterDefaultListener = 1 }
  local n = 0
  for _, path in ipairs({ "/Script/Kosmos.KosmosAudioBlueprintLibrary", "/Script/AkAudio.AkGameplayStatics" }) do
    local cls = StaticFindObject(path)
    if valid(cls) then
      local cn = path:match("%.([%w_]+)$")
      pcall(function()
        cls:ForEachFunction(function(f)
          pcall(function()
            local fname = f:GetFName():ToString()
            if skip[fname] or fname:find("^Get") or fname:find("^Is") or fname:find("^Has") then return end
            local full = f:GetFullName():gsub("^Function ", "")
            RegisterHook(full, function(ctx, ...)
              S.audioTraceCnt = S.audioTraceCnt or {}
              local c = S.audioTraceCnt[fname]
              local t = now()
              if not c or t - c.t > 10 then c = { t = t, n = 0 }; S.audioTraceCnt[fname] = c end
              c.n = c.n + 1
              if c.n > 3 then return end
              local parts = {}
              for _, prm in ipairs({ ... }) do
                local okg, v = pcall(function() return prm:get() end)
                local d = okg and S.audioTraceArg(v) or nil
                if d and #parts < 4 then parts[#parts + 1] = d end
              end
              trail("звук игры: " .. cn .. "." .. fname .. (#parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or ""))
            end)
            n = n + 1
          end)
        end)
      end)
    end
  end
  log("запись звуковых вызовов: %d функций", n)
end
pcall(S.installAudioTrace)
S.replayGlobalAudio = function()
  local lib = StaticFindObject("/Script/Kosmos.Default__KosmosAudioBlueprintLibrary")
  if not valid(lib) then return end
  local c = S.audioCalls
  if c.SetGlobalAudioSettings then
    local a = c.SetGlobalAudioSettings
    pcall(function() lib:SetGlobalAudioSettings(S.pc1, a[2], a[3], a[4], a[5]) end)
  end
  if c.PostGlobalAmbience and valid(c.PostGlobalAmbience[2]) then
    pcall(function() lib:PostGlobalAmbience(S.pc1, c.PostGlobalAmbience[2]) end)
  end
  trail("звук: заново включил общий фон")
end
-- Следим, играет ли фон комнаты. Если после включения второго игрока он
-- замолчал — запускаем звук зоны заново.
S.ambienceState = function()
  local lib = StaticFindObject("/Script/Kosmos.Default__KosmosAudioBlueprintLibrary")
  if not valid(lib) or not valid(S.pc1) then return nil end
  local st = {}
  pcall(function() st.vc = lib:GetAudioVolumeAmbienceComponent(S.pc1) end)
  pcall(function() st.gc = lib:GetGlobalAmbienceComponent(S.pc1) end)
  pcall(function() st.av = lib:GetActiveAudioVolume(S.pc1) end)
  st.v = valid(st.vc) and (select(2, pcall(function() return st.vc:HasActiveEvents() end)) == true)
  st.g = valid(st.gc) and (select(2, pcall(function() return st.gc:HasActiveEvents() end)) == true)
  return st
end
S.ambienceTick = function()
  local st = S.ambienceState(); if not st then return end
  local key = tostring(st.v) .. "/" .. tostring(st.g) .. "/" .. (valid(st.av) and st.av:GetFName():ToString() or "-")
  if key ~= S.ambKey then
    S.ambKey = key
    trail(string.format("звук: фон зоны=%s, общий фон=%s, зона=%s", tostring(st.v), tostring(st.g), valid(st.av) and st.av:GetFName():ToString() or "нет"))
  end
  -- общий фон молчит, а игра его включала — включаем заново (не чаще раза в 20 с)
  -- чиним звук только вскоре после того, как игра переключала «уши»: в
  -- остальное время тишина может быть задумана игрой
  local recent = S.lastListenerFix and now() - S.lastListenerFix < 40
  if recent and not st.g and (S.audioCalls.PostGlobalAmbience or S.audioCalls.SetGlobalAudioSettings) and (not S.gReplayAt or now() - S.gReplayAt > 20) then
    S.gReplayAt = now()
    pcall(S.replayGlobalAudio)
  end
  -- у зоны есть свой фон, а он не играет — включаем (не чаще раза в 20 с на зону)
  local zoneHasSound = false
  pcall(function() zoneHasSound = valid(st.av.mAudioEvent) end)
  S.zoneReplay = S.zoneReplay or {}
  local zk = valid(st.av) and st.av:GetFName():ToString() or ""
  if recent and zoneHasSound and not st.v and valid(st.vc) and (not S.zoneReplay[zk] or now() - S.zoneReplay[zk] > 20) then
    S.zoneReplay[zk] = now()
    local okn, ev = pcall(function() return st.av.mAudioEvent end)
    if okn and valid(ev) then
      local name = ev:GetFName():ToString()
      local okp = pcall(function() st.vc:PostAkEventByName(name) end)
      log("звук: фон зоны молчал — запустил заново (%s%s)", name, okp and "" or ", не удалось")
    end
  end

end
S.audioProbeTick = function()
  local due = false
  local left = false
  for i, f in ipairs(S.audioProbe) do if f and S.frames >= f then S.audioProbe[i] = false; due = true elseif f then left = true end end
  if not left then S.audioProbe = nil end
  if not due then return end
  local st = S.ambienceState() or {}
  local o = listenerOwner()
  local aks = {}
  pcall(function()
    for _, c in ipairs(FindAllOf("AkComponent") or {}) do
      local ok, ow = pcall(function() return c:GetOwner() end)
      if ok and valid(ow) then
        local cn = cname(ow)
        if cn:find("Camera") or cn:find("Controller") then aks[#aks + 1] = cn .. (ow == S.pc2 or (valid(S.pc2) and ow == S.pc2.PlayerCameraManager) and "(игрок 2)" or "") end
      end
    end
  end)
  local first = "?"
  pcall(function() local arr = S.localPlayers(); first = (valid(arr[1]) and valid(S.lp2) and arr[1]:GetAddress() == S.lp2:GetAddress()) and "игрок 2" or "игрок 1" end)
  local ids = string.format("контроллеры: игрок 1=%s, игрок 2=%s", tostring(pcId(S.pc1)), tostring(pcId(S.pc2)))
  local line = string.format("уши=%s, фон зоны=%s, общий фон=%s, первым в списке=%s, %s, Ak у камер/контроллеров: %s",
    cname(o), tostring(st.v), tostring(st.g), first, ids, table.concat(aks, ", "))
  local quiet = S.audioProbeQuiet; S.audioProbeQuiet = false
  if quiet and line == S.audioProbeLast then return end
  S.audioProbeLast = line
  trail(string.format("звук (%s): %s", S.split and "разделён" or "общий", line))
end
-- Звук: после подключения второго игрока весь звук иногда молчит до первой
-- смерти — его чинит возрождение героев. Вызываем возрождение игры один раз
-- сразу после подключения (без смерти). Параметры функции подбираем по их
-- типам, т.к. заранее их не знаем.
-- Вызов функции игры, параметры которой заранее не известны: подставляем
-- значения по типам (объект — герой игрока 1, число — 0, флаг — false...).
S.callGameFn = function(obj, fnPath, fnName)
  local args, desc = {}, {}
  pcall(function()
    StaticFindObject(fnPath):ForEachProperty(function(pr)
      local n = pr:GetFName():ToString()
      if n == "ReturnValue" then return end
      local cn = ""; pcall(function() cn = pr:GetClass():GetFName():ToString() end)
      local v
      if cn == "BoolProperty" then v = false
      elseif cn:find("Int") or cn == "FloatProperty" or cn == "DoubleProperty" or cn == "ByteProperty" or cn == "EnumProperty" then v = 0
      elseif cn == "StrProperty" then v = ""
      elseif cn == "NameProperty" then v = FName("None")
      elseif cn == "StructProperty" then v = {}
      elseif cn:find("Object") then v = S.p1 end
      args[#args + 1] = v
      desc[#desc + 1] = n .. ":" .. cn
    end)
  end)
  local ok, e = pcall(function() obj[fnName](obj, table.unpack(args, 1, #desc)) end)
  return ok, e, table.concat(desc, ", ")
end
-- Звук: при подключении второго игрока весь звук иногда молчит до первой
-- смерти. Чинить его так же, как смерть: сразу после подключения игрок 1
-- погибает и возрождается на контрольной точке (после загрузки сохранения
-- герои и так на ней). Выключается audio_kill = false.
-- Звук: контроллер игрока при появлении приглушает весь звук игры (так
-- игра делает при смерти и загрузке, а потом возвращает его). Новый
-- контроллер игрока 2 звук приглушает, а вернуть его некому — до первой
-- смерти, когда игра сама вызывает «вернуть звук». Вызываем это сами.
S.fadeInAudio = function(why)
  if CFG.audio_fadein == false then return end
  for i, pc in ipairs({ S.pc1 }) do
    if valid(pc) then
      local ok, e, d = S.callGameFn(pc, "/Script/Kosmos.KosmosPlayerController:FadeInAudio", "FadeInAudio")
      trail(string.format("звук: вернул звук через контроллер игрока %d (%s) [%s] — %s", i, why or "", d, ok and "сделано" or ("ошибка: " .. tostring(e))))
    end
  end
end
local function keepListener()
  if not valid(AUDIO.owner) then return end
  local o = listenerOwner()
  if o ~= AUDIO.owner then
    local lib = StaticFindObject("/Script/Kosmos.Default__KosmosAudioBlueprintLibrary")
    if valid(lib) then
      try("RegisterDefaultListener", function() lib:RegisterDefaultListener(S.pc1, AUDIO.owner) end)
      S.lastListenerFix = now()
      if ExecuteWithDelay and not S.audioRespawnDone then
        S.audioRespawnDone = true
        ExecuteWithDelay(1500, function() ExecuteInGameThread(function() pcall(S.fadeInAudio, "после подключения") end) end)
      end
      if not AUDIO.logged then AUDIO.logged = true; log("звук: игра переключила слушателя на %s — вернул на %s", cname(o), cname(AUDIO.owner)) end
      if ExecuteWithDelay then
        ExecuteWithDelay(300, function() ExecuteInGameThread(function() pcall(refreshAmbience) end) end)
      else pcall(refreshAmbience) end
    end
  end
end
-- Герои всегда считают свою анимацию, даже если их «не видно» в кадре
-- (иначе в разделённом экране герой мог скользить без анимации).
-- v9.17: и все остальные «скелетные» части героя (у героя их несколько, а
-- вид второго игрока игра может не считать «видом»), и без прореживания
-- анимации по расстоянию — второй игрок иногда скользил, не шагая.
S.keepAnimating = function()
  for _, h in ipairs({ S.p1, S.buddy }) do
    if valid(h) then
      local meshes = {}
      pcall(function() meshes[#meshes + 1] = h.Mesh end)
      pcall(function()
        local cls = StaticFindObject("/Script/Engine.SkeletalMeshComponent")
        local arr = h:K2_GetComponentsByClass(cls)
        if type(arr) == "table" then for _, c in ipairs(arr) do meshes[#meshes + 1] = c end
        elseif arr then arr:ForEach(function(_, e) meshes[#meshes + 1] = e:get() end) end
      end)
      for _, m in ipairs(meshes) do
        pcall(function()
          if valid(m) then
            -- v9.15.2: пишем в лог, если игра снова выключила анимацию героя
            -- (по этим строкам видно, повторилась ли «скользящая походка»)
            local was, uro = nil, nil
            pcall(function() was = m.VisibilityBasedAnimTickOption; uro = m.bEnableUpdateRateOptimizations end)
            if (was ~= nil and was ~= 0) or uro == true then
              S.animLogAt = S.animLogAt or {}
              local k = heroName(h) .. cname(m)
              if not S.animLogAt[k] or S.frames - S.animLogAt[k] > 600 then
                S.animLogAt[k] = S.frames
                trail(string.format("анимация героя %s (%s): игра выключала (режим %s, прореживание %s) — включил", heroName(h), cname(m), tostring(was), tostring(uro)))
              end
            end
            m.VisibilityBasedAnimTickOption = 0
            m.bEnableUpdateRateOptimizations = false
            m.bNoSkeletonUpdate = false
          end
        end)
      end
    end
  end
end
local function takeBuddy()
  if not (valid(S.pc2) and valid(S.buddy)) then return false end
  -- ИИ-контроллер напарника после передачи героя остаётся «без тела». Если он
  -- продолжит работать, на ближайшем кадре он обратится к своему герою, а героя
  -- уже нет — игра падала. Поэтому сначала полностью его останавливаем.
  if valid(S.ai) then
    -- v9.15.7: путь ИИ ведёт отдельный компонент со своим тиком — выключение
    -- тика контроллера его не останавливает. Если напарник в этот момент шёл
    -- по связке пути (прыжок, лаз), компонент доходил до связки уже без героя
    -- и игра падала (обращение к пустому движению в KosmosPlaypalNavLink).
    -- Поэтому сначала обрываем движение и команды ИИ.
    try("ai stop movement", function() S.ai:StopMovement() end)
    pcall(function() S.ai:StopAllAICommands() end)
    try("ai tick off", function() S.ai:SetActorTickEnabled(false) end)
    setBrain(S.ai, false)
  end
  resetBuddyInput()
  if not safePossess(S.pc2, S.buddy, "напарник → игрок 2") then
    if valid(S.ai) then try("ai tick on", function() S.ai:SetActorTickEnabled(true) end) end
    return false
  end
  local ok, c = pcall(function() return S.buddy.Controller end)
  if not (ok and c == S.pc2) then log("игрок 2 не смог взять героя"); return false end
  S.real = true
  applyCam()
  S.camCheckAt = S.frames + 10
  log("игрок 2 управляет героем %s напрямую", heroName(S.buddy))
  return true
end
local function releaseBuddy()
  pcall(function() S.bowRestore() end)
  pcall(function() S.twcRelease() end)
  if S.boost then S.boostEnd("кооператив выключен") end
  if not S.real then return end
  S.real = false
  if valid(S.buddy) and valid(S.ai) then
    pcall(dedupeRegistry, "перед передачей ИИ")
    safePossess(S.ai, S.buddy, "напарник → ИИ")
    pcall(dedupeRegistry, "после передачи ИИ")
    try("ai tick on", function() S.ai:SetActorTickEnabled(true) end)
  end
end


-- Поиск геймпада игрока 2. Windows раздаёт геймпадам «слоты» 1–4, и второй
-- геймпад не всегда получает слот №2. Перебираем номера, пока игрок 2 не нажмёт
-- кнопку на своём геймпаде.
local DETECT_KEYS = { "Gamepad_FaceButton_Bottom", "Gamepad_FaceButton_Right", "Gamepad_FaceButton_Left", "Gamepad_FaceButton_Top",
  "Gamepad_LeftStick_Up", "Gamepad_LeftStick_Down", "Gamepad_LeftStick_Left", "Gamepad_LeftStick_Right",
  "Gamepad_DPad_Up", "Gamepad_DPad_Down", "Gamepad_DPad_Left", "Gamepad_DPad_Right", "Gamepad_Special_Right" }
local DETECT_IDS = { 0, 1, 2, 3, 4 }
local function detectSkip(d)  -- геймпад игрока 1 не перебираем
  local p1 = pcId(S.pc1)
  for _ = 1, #DETECT_IDS do if DETECT_IDS[d.i] ~= p1 then return end d.i = d.i % #DETECT_IDS + 1 end
end
local function setP2Id(id) try("SetPlayerControllerID", function() UEHelpers.GetGameplayStatics():SetPlayerControllerID(S.pc2, id) end) end
local function startDetect()
  if not S.coop or not valid(S.pc2) then toast("Сначала включите второго игрока"); return end
  S.detect = { i = 1, frames = 0, total = 0, prevId = p2PadId() }
  detectSkip(S.detect)
  setP2Id(DETECT_IDS[S.detect.i])
  toast("Нажимайте A на геймпаде игрока 2…")
  log("поиск геймпада игрока 2 начат")
end
local function detectTick()
  local d = S.detect; if not d then return end
  d.frames, d.total = d.frames + 1, d.total + 1
  local hit = false
  for _, k in ipairs(DETECT_KEYS) do if isDown(S.pc2, k) then hit = true break end end
  if hit then
    CFG.p2_controller_id = DETECT_IDS[d.i]; CFG.p2_controller_confirmed = true; saveSettings()
    S.detect = nil
    toast("Геймпад игрока 2 найден!")
    log("геймпад игрока 2 найден: номер контроллера %d", CFG.p2_controller_id)
    S.audioProbe = { S.frames + 1, S.frames + 120, S.frames + 360 }
    return
  end
  if d.total > 60 * 20 then
    setP2Id(d.prevId); S.detect = nil
    toast("Геймпад игрока 2 не отвечает — проверьте подключение")
    log("геймпад игрока 2 не найден за 20 секунд")
    return
  end
  if d.frames >= 25 then
    d.frames = 0; d.i = d.i % #DETECT_IDS + 1; detectSkip(d)
    setP2Id(DETECT_IDS[d.i])
  end
  if d.total % 150 == 0 then toast("Нажимайте A на геймпаде игрока 2…") end
end

local function setCoop(on)
  if on == S.coop then return end
  if not on then pcall(function() S.roleRestore() end) end
  if on then
    pcall(function() S.checkApi() end)
    applyGamepadRouting()
    -- v9.15.7: счёт кадров при возобновлении больше не обнуляем. Многое
    -- запоминает «в каком кадре» (кэши двух миров, куклы, наложенных копий,
    -- съёмок): после обнуления старые отметки оказывались «в будущем», и после
    -- выхода в меню и возвращения два мира не распознавались по 10+ минут —
    -- вторая половина экрана показывала не то, ареол лез на неё.
    if S.crumbUntil then S.crumbUntil = S.frames + 300 end
    -- всё, что отсчитывается в кадрах, начинаем заново (иначе после
    -- возобновления подсадка «ждёт» паузу, оставшуюся с прошлого раза)
    S.boost, S.boostCooldown, S.pendingKill, S.localSwap = nil, nil, nil, nil
    S.enemy.listAt, S.enemy.killAt, S.enemy.bbAt, S.enemy.st, S.enemy.pos = -10000, -10000, {}, {}, {}
    -- объекты прошлого уровня (кукла, съёмки второго мира) — искать заново
    S.twAt, S.ownAt = nil, nil
    pcall(function() S.halo.doll, S.halo.dollAt, S.halo.cap = nil, nil, nil end)
    pcall(function() S.twc.list, S.twc.at = {}, -10000 end)
    if not acquire() then toast("Не нашёл двух героев — загрузите игру"); return end
    S.coop, S.split = true, false
    S.audioRespawnDone = false
    pcall(function() if valid(S.ai) and valid(S.buddy) then S.ai.mCurrentCharacter = S.buddy end end)
    S.itemOwners = {}
    pcall(S.snapshotItemOwners, "кооператив включён")
    pcall(S.installInvTrace)
    S.lastBuddyLoc, S.camFrozenAt = nil, nil   -- место героя с прошлого уровня не годится
    -- запоминаем мир, в котором включились: иначе проверка смены уровня,
    -- не успевшая заметить загрузку, сразу же приостановит кооператив
    pcall(function() S.worldName = UEHelpers.GetWorld():GetFullName() end)
    rememberListener()
    pcall(S.hookExternalCam)
    S.ambBase = S.ambienceState()
    if S.ambBase then trail(string.format("звук до кооператива: фон зоны=%s, общий фон=%s", tostring(S.ambBase.v), tostring(S.ambBase.g))) end
    ensurePC2()
    S.real = false
    if wantReal() then
      if registryWorks() then S.withHandsFree(S.buddy, takeBuddy, "перед передачей героя игроку 2") else log("режим второго игрока недоступен — управляю через ИИ") end
    end
    toast("Игрок 2 подключён: " .. heroName(S.buddy))
    S.audioProbe = { S.frames + 1, S.frames + 120, S.frames + 360 }
    if CFG.device == "gamepad" and not CFG.p2_controller_confirmed then S.detectPending = true end
  else
    -- вещь в руках героя при передаче его ИИ игра «роняет» (потом её не
    -- достать или игра падает) — сначала убираем её, как кнопкой
    if S.real and valid(S.buddy) and not S.handsFreeOK and S.p1EquipAbility(S.buddy) then
      S.withHandsFree(S.buddy, function() S.handsFreeOK = true; pcall(setCoop, false); S.handsFreeOK = nil end, "перед передачей героя ИИ")
      return
    end
    S.coop, S.resumeCoop, S.drag, S.cbox = false, false, nil, nil
    releaseBuddy()
    resetBuddyInput()
    if valid(S.ai) then setBrain(S.ai, true) end
    pcall(function() if valid(S.poi) then S.poi.mWeight = 0 end end)
    removePC2(); S.split = false
    toast("Напарником снова управляет ИИ")
  end
end

-- После смерти игра возрождает героя игрока 1 у контроллера с номером
-- геймпада 0. Если игрок 1 играет со второго геймпада (номер 1), а игроку 2
-- достался геймпад 0, герой игрока 1 оказывается у контроллера игрока 2 —
-- игрок 1 «теряет» героя, экран чёрный (issue #12). Возвращаем героя игроку 1.
S.rescueP1Hero = function()
  local pc1 = findPC1(); if not valid(pc1) then return false end
  local okp, own = pcall(function() return pc1.Pawn end)
  if okp and isHero(own) then return false end
  if not S.p1HeroClass then return false end
  for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
    if valid(pc) and pc ~= pc1 and isLocalPC(pc) then
      local ok, pawn = pcall(function() return pc.Pawn end)
      if ok and isHero(pawn) and pawn:GetClass():GetFName():ToString() == S.p1HeroClass then
        pcall(function() pc:UnPossess() end)
        -- через safePossess: без лишней записи в реестре персонажей игры
        local okP = safePossess(pc1, pawn, "вернуть героя игроку 1 после возрождения")
        log("после возрождения герой игрока 1 оказался у контроллера %s — вернул игроку 1 (%s)", tostring(pcId(pc)), okP and "ok" or "ошибка")
        return okP
      end
    end
  end
  return false
end

-- Кооператив «на паузе» на время выхода в меню/загрузки: второй вид убран,
-- экран не разделён; когда снова появятся оба героя — всё включится само.
suspendCoop = function(reason)
  if not S.coop then return end
  log("кооператив приостановлен: %s", reason)
  S.real, S.boost = false, nil
  resetBuddyInput()
  removePC2()
  -- второй «локальный игрок» переживает смену уровня — убираем всех, кроме первого
  local keep = findPC1()
  for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
    local id = pcId(pc)
    local okh, hp = pcall(function() return pc.Pawn end)
    if valid(pc) and id and pc ~= keep and isLocalPC(pc) and okh and isHero(hp) then
      -- у этого «лишнего» игрока герой — убирать его нельзя (экран стал бы чёрным)
      log("не убираю игрока (контроллер %d): у него герой %s", id, heroName(hp))
    elseif valid(pc) and id and pc ~= keep and isLocalPC(pc) then
      pcall(function() pc:UnPossess() end)
      pcall(function() UEHelpers.GetGameplayStatics():RemovePlayer(pc, false) end)
      log("убран лишний игрок (контроллер %d)", id)
    end
  end
  pcall(function() S.twcRelease() end)
  S.coop, S.split, S.resumeCoop, S.cmd, S.throwCheck, S.detect, S.drag, S.cbox = false, false, true, nil, nil, nil, nil, nil
  -- камеры комнат прошлого уровня после загрузки «мёртвые» — забываем их
  RC.list, RC.listAt, RC.cur, RC.pickAt, RC.errLogged = {}, -100000, nil, 0, false
  S.roomP1, S.roomP2 = nil, nil
  pcall(function() gms().bUseSplitscreen = false end)
end
if CFG.coop_enabled then S.resumeCoop = true end
local function resumeTick()
  if not S.resumeCoop or S.coop or S.frames % 60 ~= 0 then return end
  local pc = findPC1()
  if not (valid(pc) and isHero(pc.Pawn)) or not findBuddy(pc.Pawn) then
    S.resumeReady = 0
    -- для разбора (дополнения): в уровне, а героев мод не узнал — кто там есть
    S.resumeMiss = (S.resumeMiss or 0) + 1
    if S.resumeMiss % 10 == 0 and S.resumeMissLogged ~= S.worldName then
      pcall(function()
        local pawn = valid(pc) and pc.Pawn or nil
        local chars = {}
        for _, ch in ipairs(FindAllOf("KosmosBaseCharacter") or {}) do
          pcall(function()
            local ctl = ch.Controller
            chars[#chars + 1] = string.format("%s (герой=%s, управляет %s)", cname(ch), tostring(isHero(ch)), valid(ctl) and cname(ctl) or "никто")
          end)
        end
        if #chars > 0 then
          S.resumeMissLogged = S.worldName
          trail(string.format("кооператив ждёт героев: у игрока 1 %s (герой=%s); персонажи: %s", cname(pawn), tostring(isHero(pawn)), table.concat(chars, ", ")))
        end
      end)
    end
    return
  end
  S.resumeMiss = 0
  -- можно задать задержку (resume_delay_s, в секундах); по умолчанию сразу,
  -- чтобы напарником не успел побегать ИИ
  S.resumeReady = (S.resumeReady or 0) + 1
  if S.resumeReady < (CFG.resume_delay_s or 1) then return end
  S.resumeReady = 0
  S.resumeCoop = false
  log("кооператив возобновлён")
  setCoop(true)
  if not S.coop and CFG.coop_enabled then S.resumeCoop = true end
end
-- Выбор «на одного / на двоих» запоминается между запусками игры. Включить
-- можно и в главном меню: кооператив начнётся сам, как только появятся герои.
S.userSetCoop = function(on)
  CFG.coop_enabled = on and true or false
  saveSettings()
  if on then
    local pc = findPC1()
    if valid(pc) and isHero(pc.Pawn) and findBuddy(pc.Pawn) then setCoop(true)
    else S.resumeCoop = true; toast("Игра будет вдвоём") end
  else
    S.resumeCoop = false
    if S.coop then setCoop(false) else toast("Игра будет на одного") end
  end
end
S.coopWanted = function() return S.coop or (CFG.coop_enabled and true or false) end

-- Предметы. ИИ-напарник поднимает предметы не «кнопкой», а командой «подними
-- вот этот предмет». Поэтому по кнопке игрока 2 сами находим ближайший предмет
-- и отдаём напарнику эту команду; пока она выполняется — не мешаем ему.
local CARRY = { cls = nil, cmds = nil }
local function carriableClass()
  if not valid(CARRY.cls) then CARRY.cls = StaticFindObject("/Script/Kosmos.KosmosCarriable") end
  return CARRY.cls
end
local function carryCmds()
  if not valid(CARRY.cmds) then CARRY.cmds = StaticFindObject("/Script/Kosmos.Default__KosmosPlaypalCommandsCarriable") end
  return CARRY.cmds
end
local function heldItem()
  -- один запрос за кадр, и только когда напарник «на ногах»
  if S.heldFrame == S.frames then return S.heldVal end
  S.heldFrame, S.heldVal = S.frames, nil
  if not valid(S.buddy) then return nil end
  local cls = carriableClass(); if not valid(cls) then return nil end
  local ok, it = pcall(function() return S.buddy:GetHeldItemOfType(cls) end)
  if ok and valid(it) then S.heldVal = it end
  return S.heldVal
end
local function buddySteady()
  -- в воздухе, на лестнице/уступе или в сцене команды ИИ опасны
  local okf, falling = pcall(function() return S.buddy.CharacterMovement:IsFalling() end)
  if okf and falling then return false end
  local okm, mode = pcall(function() return S.buddy.CharacterMovement.MovementMode end)
  if okm and mode == 0 then return false end  -- 0 = движение отключено (сценка)
  return true
end
local function nearestCarriable()
  -- только предметы, которые игра сама считает доступными этому персонажу:
  -- рядом, по высоте, по углу и «можно схватить» (иначе ИИ мог уронить игру)
  local best, bestD
  for _, c in ipairs(FindAllOf("KosmosCarriable") or {}) do
    if valid(c) then
      local okd, d = pcall(function() return c:GetDistanceTo(S.buddy) end)
      if okd and d < 260 and (not bestD or d < bestD) then
        local function chk(f) local ok, r = pcall(f); return ok and r == true end
        -- по высоте — не выше/ниже ~0,8 м от напарника (предметы на полках и
        -- под полом ИИ поднять не может — с них игра и падала)
        local okz, dz = pcall(function() return math.abs(c:K2_GetActorLocation().Z - S.buddy:K2_GetActorLocation().Z) end)
        local good = chk(function() return c:GetCanPickup() end)
          and okz and dz < 80
        local okp, parent = pcall(function() return c:GetAttachParent() end)
        local okh, p1held = pcall(function() return S.p1:GetHeldItemOfType(carriableClass()) end)
        if okh and p1held == c then good = false end
        if good and not (okp and valid(parent)) then best, bestD = c, d end
      end
    end
  end
  if not best then
    -- для разбора: что было рядом и почему не подошло
    local lines = {}
    for _, c in ipairs(FindAllOf("KosmosCarriable") or {}) do
      if valid(c) then
        local okd, d = pcall(function() return c:GetDistanceTo(S.buddy) end)
        if okd and d < 500 then
          local okz, dz = pcall(function() return c:K2_GetActorLocation().Z - S.buddy:K2_GetActorLocation().Z end)
          local okp, can = pcall(function() return c:GetCanPickup() end)
          lines[#lines + 1] = string.format("%s: %.0f см, высота %+.0f, можно=%s", c:GetFName():ToString(), d, okz and dz or 0, tostring(okp and can))
        end
      end
    end
    log("поднять нечего; рядом: %s", #lines > 0 and table.concat(lines, "; ") or "ничего")
  end
  return best, bestD
end
local function runCmd(label, make)
  if not buddySteady() then log("напарнику: %s — пропущено (не стоит на ногах)", label); return false end
  trail("команда: " .. label)
  local ok, action = try(label, make)
  if ok and valid(action) then
    try(label .. " Activate", function() action:Activate() end)
    S.cmd = { untilT = now() + 4, startFrame = S.frames, label = label }
    log("напарнику: %s", label)
    return true
  end
  return false
end
local function tryPickupOrPutdown()
  local held = heldItem()
  if held then
    return runCmd("положить", function() return S.cmdCall("Carriable", "PlaypalCarriable_Putdown", S.buddy, false, { X = 0, Y = 0, Z = 0 }) end)
  end
  local c, d = nearestCarriable()
  if c then
    return runCmd(string.format("поднять (%.0f см)", d), function() return S.cmdCall("Carriable", "PlaypalCarriable_Pickup", S.buddy, c) end)
  end
  return false
end
-- Бросок. ИИ бросает «из точки в цель»; без них команда ничего не делает.
-- Ставим две невидимые метки: где стоит напарник и куда лететь (вперёд по взгляду).
local function spawnMarker(loc)
  local ok, a = try("spawn marker", function()
    local cls = StaticFindObject("/Script/Engine.TargetPoint")
    if not valid(cls) then cls = StaticFindObject("/Script/Engine.Actor") end
    local gs = UEHelpers.GetGameplayStatics()
    local t = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = loc, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local actor = gs:BeginDeferredActorSpawnFromClass(S.pc1, cls, t, 1, S.pc1)
    return gs:FinishSpawningActor(actor, t)
  end)
  if ok and valid(a) then return a end
end
local function placeMarker(key, loc)
  -- Метки НИКОГДА не удаляем: команда ИИ (выстрел, бросок) хранит ссылку на
  -- метку, и если метку удалить, пока команда ещё идёт, игра падает.
  -- Ставим метку один раз, делаем её подвижной и дальше только переносим.
  local m = S[key]
  if valid(m) then
    local ok = pcall(function()
      m:K2_SetActorLocation(loc, false, {}, true)
    end)
    local okl, l = pcall(function() return m:K2_GetActorLocation() end)
    if ok and okl and math.abs(l.X - loc.X) < 5 and math.abs(l.Y - loc.Y) < 5 then return m end
    -- не сдвинулась — старую оставляем как есть, ставим новую
  end
  m = spawnMarker(loc)
  if valid(m) then
    pcall(function() m.RootComponent:SetMobility(2) end)  -- 2 = подвижный
    S[key] = m
  end
  return m
end
local THROW_DIST = 700
local function throwPoints()
  local l = S.buddy:K2_GetActorLocation()
  local fw = S.buddy:GetActorForwardVector()
  local stand = { X = l.X, Y = l.Y, Z = l.Z }
  local target = { X = l.X + fw.X * THROW_DIST, Y = l.Y + fw.Y * THROW_DIST, Z = l.Z + 20 }
  return stand, target
end
local function directThrow(target)
  -- запасной путь: бросок напрямую через «ручку» предмета, без анимации ИИ
  local item = heldItem(); if not item then return end
  local ok = try("direct throw", function()
    local pc = item.PickupComponent
    pc:Throw(S.buddy, S.buddy.CharacterThrowSettings, target)
  end)
  ExecuteInGameThreadWithDelay(800, function()
    log(heldItem() and "бросок напрямую: предмет всё ещё в руках" or "бросок напрямую: сработал")
  end)
end
local function tryThrow()
  if not heldItem() then return end
  local okp, stand, target = pcall(throwPoints)
  if not okp then log("бросок: не удалось посчитать направление: %s", tostring(stand)); return end
  local sm, tm = placeMarker("throwStand", stand), placeMarker("throwTarget", target)
  if not (valid(sm) and valid(tm)) then log("бросок: метки не создались"); return end
  runCmd("бросить", function() return S.cmdCall("Carriable", "PlaypalCarriable_Throw", S.buddy, sm, tm) end)
  S.throwCheck = { at = S.frames + 75, target = target }
end
local function throwCheckTick()
  local c = S.throwCheck; if not c or S.frames < c.at then return end
  S.throwCheck = nil
  if heldItem() then
    log("бросок командой ИИ не сработал (предмет в руках)")
  else
    log("бросок: предмет брошен")
  end
end
-- Оружие/инструмент напарника (ключ у Alone, лук у Low): ИИ пользуется им
-- командой «ударь/выстрели туда». Используем, если поднимать нечего.
local function weaponCmds()
  if not valid(CARRY.wcmds) then CARRY.wcmds = StaticFindObject("/Script/Kosmos.Default__KosmosPlaypalCommandsWeaponTools") end
  return CARRY.wcmds
end
-- Цель для лука — как у игры: мишени лука помечены KosmosTargetComponent
-- с категорией «прицел лука» (EKosmosTargetType.BowAiming = 0, бит 1).
-- Берём включённую мишень перед героем (в конусе), самую прямую по углу.
S.bowTarget = function(l, fw)
  local BOW_RANGE, BOW_CONE = CFG.bow_range or 3000, CFG.bow_cone or 50
  local best, bestScore, bestLoc = nil, nil, nil
  local seen, cand = 0, 0
  for _, tc in ipairs(FindAllOf("KosmosTargetComponent") or {}) do
    pcall(function()
      if not valid(tc) then return end
      local cats = tc.CurrentCategories or 0
      if cats % 2 ~= 1 then return end                       -- не мишень лука
      seen = seen + 1
      if tc.bIsTargetEnabled == false then return end
      local p = tc:K2_GetComponentLocation()
      if tc.bShouldusePrecisePosition then pcall(function() p = tc:GetPrecisePosition() end) end
      local dx, dy, dz = p.X - l.X, p.Y - l.Y, p.Z - l.Z
      local dh = math.sqrt(dx * dx + dy * dy)
      local d = math.sqrt(dh * dh + dz * dz)
      if d > BOW_RANGE or dh < 50 then return end
      local cosA = (dx * fw.X + dy * fw.Y) / dh / math.max(1e-3, math.sqrt(fw.X * fw.X + fw.Y * fw.Y))
      local ang = math.deg(math.acos(math.max(-1, math.min(1, cosA))))
      if ang > BOW_CONE then return end
      cand = cand + 1
      local score = ang * 100000 + d                           -- главное — угол, расстояние только при равенстве
      if not bestScore or score < bestScore then best, bestScore, bestLoc = tc, score, p end
    end)
  end
  return best, bestLoc, seen, cand
end
local function tryWeapon()
  local okp, l = pcall(function() return S.buddy:K2_GetActorLocation() end)
  local okf, fw = pcall(function() return S.buddy:GetActorForwardVector() end)
  if not (okp and okf) then return false end
  local isLow = heroName(S.buddy) == "Low"
  local dist = isLow and 1000 or 140
  local stand = { X = l.X, Y = l.Y, Z = l.Z }
  local target = { X = l.X + fw.X * dist, Y = l.Y + fw.Y * dist, Z = l.Z + (isLow and 40 or 0) }
  local tm = nil
  if isLow then
    local tc, tl, seen, cand = S.bowTarget(l, fw)
    local owner = nil
    pcall(function() owner = tc:GetOwner() end)
    if valid(tc) and valid(owner) then
      target, tm = { X = tl.X, Y = tl.Y, Z = tl.Z }, owner
      trail(string.format("лук игрока 2: цель %s (%.0f см), мишеней лука в уровне %d, перед героем %d",
        cname(owner), math.sqrt((tl.X - l.X) ^ 2 + (tl.Y - l.Y) ^ 2 + (tl.Z - l.Z) ^ 2), seen, cand))
    else
      trail(string.format("лук игрока 2: цели впереди нет — стреляю прямо (мишеней лука в уровне %d)", seen))
    end
  end
  local sm = placeMarker("weapStand", stand)
  if not valid(tm) then tm = placeMarker("weapTarget", target) end
  if not (valid(sm) and valid(tm)) then return false end
  return runCmd(isLow and "выстрелить из лука" or "ударить ключом", function()
    return S.cmdCall("WeaponTools", "PlaypalWeaponAttack", S.buddy, sm, stand, tm, target, false, 1, 60)
  end)
end

local function cmdRunning()
  if not S.cmd then return false end
  if now() > S.cmd.untilT then S.cmd = nil; return false end
  if S.frames - S.cmd.startFrame > 20 then
    local ok, busy = pcall(function() return S.ai:IsAiCommand() end)
    if ok and not busy then S.cmd = nil; return false end
  end
  return true
end

-- Ящики и прочее, что тащат. ИИ-напарник тащит их не «кнопкой», а командой
-- «тащи вот это вот туда». Пока игрок 2 держит «схватить», ставим невидимую
-- метку туда, куда он наклоняет стик, и напарник тащит ящик к метке.
local function interactCmds()
  if not valid(CARRY.icmds) then CARRY.icmds = StaticFindObject("/Script/Kosmos.Default__KosmosPlaypalCommandsInteractions") end
  return CARRY.icmds
end
-- v9.15.7: КОМАНДЫ НАПАРНИКУ ПРИ ДРУГОЙ ВЕРСИИ ИГРЫ. В обновлённой игре у
-- команд (подсадка, ящики) появился ещё один параметр, и вызов с прежним
-- набором падал («UFunction expected 3 parameters, received 2») — подсадка
-- у таких игроков не работала совсем. Теперь параметры берём у самой
-- функции игры: наши значения раскладываем по параметрам того же вида (объект,
-- число, флаг, структура) в прежнем порядке, недостающим даём значение по
-- умолчанию. Если набор параметров не такой, как мы знаем, пишем его в лог.
-- v9.15.9: ТИП ПЕРСОНАЖА В КОМАНДАХ. В новой версии игры подсадка получает не
-- героя, а «тип персонажа» (CompanionCharacterType, перечисление), и по нему
-- игра сама ищет героя. Мы подставляли 0 — игра не находила героя и падала.
-- Теперь тип ищем по имени героя среди значений перечисления (Low, Alone,
-- Dime…), а если не нашли — в свойстве самого героя того же перечисления
-- (кроме свойств «про другого»: Companion, Other, Buddy…). Если тип узнать
-- не удалось, команду НЕ вызываем (лучше без подсадки, чем вылет).
S.enumKey = function(e)
  local ok, n = pcall(function() return e:GetFullName() end)
  return ok and n or nil
end
S.enumEntries = function(e)
  local out = {}
  pcall(function()
    e:ForEachName(function(name, value)
      local s = ""; pcall(function() s = name:ToString() end)
      out[#out + 1] = { name = s, value = value }
    end)
  end)
  return out
end
-- Общий переходник для команд напарнику (подсадка, ящики, переноска, оружие):
-- если у функции игры столько же параметров, сколько передаём мы (версия
-- игры, под которую сделан мод), вызываем как есть. Иначе раскладываем наши
-- значения по параметрам функции этой версии игры.
S.CMD_CLASSES = {
  Interactions = "/Script/Kosmos.KosmosPlaypalCommandsInteractions",
  Carriable    = "/Script/Kosmos.KosmosPlaypalCommandsCarriable",
  WeaponTools  = "/Script/Kosmos.KosmosPlaypalCommandsWeaponTools",
}
S.cmdObj = function(group)
  if group == "Interactions" then return interactCmds() end
  if group == "Carriable" then return carryCmds() end
  if group == "WeaponTools" then return weaponCmds() end
end
S.propKind = function(cn)
  if cn:find("Object") or cn:find("Class") or cn:find("Interface") then return "object"
  elseif cn == "BoolProperty" then return "bool"
  elseif cn:find("Int") or cn == "FloatProperty" or cn == "DoubleProperty" or cn == "ByteProperty" or cn == "EnumProperty" then return "number"
  elseif cn == "StructProperty" then return "struct"
  elseif cn == "NameProperty" then return "name" end
  return "other"
end
-- перечисление параметра: у самого параметра, а если не отдаёт — по имени
S.propEnum = function(pr, n, cn)
  if not (cn == "ByteProperty" or cn == "EnumProperty") then return nil end
  local okE, e = pcall(function() return pr:GetEnum() end)
  if okE and e then
    local okv, v = pcall(function() return e:IsValid() end)
    if not okv or v then return e end
  end
  local base = n:gsub("^In", ""):gsub("^New", "")
  for _, cand in ipairs({ "E" .. base, "EKosmos" .. base, "E" .. base .. "s" }) do
    local okf, f = pcall(function() return StaticFindObject("/Script/Kosmos." .. cand) end)
    if okf and valid(f) then return f end
  end
  return nil
end
S.readSig = function(classPath, fnName)
  local sig, ret = {}, nil
  pcall(function()
    StaticFindObject(classPath .. ":" .. fnName):ForEachProperty(function(pr)
      local n = pr:GetFName():ToString()
      local cn = ""; pcall(function() cn = pr:GetClass():GetFName():ToString() end)
      if n == "ReturnValue" then ret = cn; return end
      local kind = S.propKind(cn)
      local pcls = nil
      if kind == "object" then pcall(function() pcls = pr:GetPropertyClass() end) end
      local enum = S.propEnum(pr, n, cn)
      sig[#sig + 1] = { name = n, cls = cn, kind = kind, pcls = pcls, enum = enum,
        heroType = (cn == "ByteProperty" or cn == "EnumProperty") and S.isTypeParam(n) }
    end)
  end)
  return sig, ret
end
S.sigText = function(sig)
  local d = {}
  for _, p in ipairs(sig) do d[#d + 1] = p.name .. ":" .. p.cls end
  return table.concat(d, ", ")
end
S.enumText = function(e)
  local parts = {}
  for _, en in ipairs(S.enumEntries(e)) do parts[#parts + 1] = en.name .. "=" .. tostring(en.value) end
  return #parts > 0 and table.concat(parts, ", ") or "значения не прочитались"
end
-- Снимок «API» команд напарнику этой версии игры — один раз за запуск, в
-- trail.txt. По нему видно, чем версия игры игрока отличается от нашей.
S.apiFingerprint = function()
  if S.apiDone then return end
  S.apiDone = true
  local enums = {}
  for group, path in pairs(S.CMD_CLASSES) do
    local names = {}
    pcall(function()
      StaticFindObject(path):ForEachFunction(function(f) names[#names + 1] = f:GetFName():ToString() end)
    end)
    table.sort(names)
    trail(string.format("API %s: %d функций", group, #names))
    for _, fn in ipairs(names) do
      local sig, ret = S.readSig(path, fn)
      trail(string.format("API   %s(%s)%s", fn, S.sigText(sig), ret and (" -> " .. ret) or ""))
      for _, p in ipairs(sig) do
        local k = p.enum and S.enumKey(p.enum)
        if k and not enums[k] then enums[k] = true; trail(string.format("API   перечисление %s: %s", k, S.enumText(p.enum))) end
      end
    end
  end
end
-- ТИП ПЕРСОНАЖА (CompanionCharacterType) В НОВОЙ ВЕРСИИ ИГРЫ. Параметр —
-- байт, и UE4SS не всегда отдаёт его перечисление, поэтому тип ищем тремя
-- путями (раз за запуск, всё пишем в trail.txt):
--  1) функции игры Get…/Find…(…CharacterType) -> объект: перебираем значения
--     и смотрим, по какому игра возвращает нашего героя — это ответ самой игры;
--  2) свойство героя …CharacterType (берём, только если у героев оно разное);
--  3) перечисления игры с Companion/CharacterType в имени — по имени героя.
S.isTypeParam = function(n) return n:find("CharacterType") ~= nil or n:find("CompanionType") ~= nil end
S.fnSig = function(f)
  local sig, ret = {}, nil
  pcall(function()
    f:ForEachProperty(function(pr)
      local n = pr:GetFName():ToString()
      local cn = ""; pcall(function() cn = pr:GetClass():GetFName():ToString() end)
      if n == "ReturnValue" then ret = cn; return end
      sig[#sig + 1] = { name = n, cls = cn, kind = S.propKind(cn) }
    end)
  end)
  return sig, ret
end
S.typeDiscover = function()
  if S.typeInfo then return S.typeInfo end
  local info = { enums = {}, lookups = {}, fns = {} }
  S.typeInfo = info
  pcall(function()
    ForEachUObject(function(o)
      pcall(function()
        local cn = o:GetClass():GetFName():ToString()
        if cn == "Enum" or cn == "UserDefinedEnum" then
          local n = o:GetFName():ToString()
          if n:find("Companion") or n:find("CharacterType") or n:find("Playpal") then info.enums[#info.enums + 1] = o end
        elseif cn == "Function" then
          local full = o:GetFullName()
          if full:find("/Script/Kosmos%.") then
            local has = false
            o:ForEachProperty(function(pr) if S.isTypeParam(pr:GetFName():ToString()) then has = true end end)
            if has then info.fns[#info.fns + 1] = o end
          end
        end
      end)
    end)
  end)
  for _, e in ipairs(info.enums) do
    trail(string.format("тип героя: перечисление %s: %s", S.enumKey(e) or "?", S.enumText(e)))
  end
  for _, f in ipairs(info.fns) do
    local fn = f:GetFName():ToString()
    local owner = ""; pcall(function() owner = f:GetOuter():GetFName():ToString() end)
    local sig, ret = S.fnSig(f)
    if not fn:find("^Playpal") then
      trail(string.format("тип героя: функция %s:%s(%s)%s", owner, fn, S.sigText(sig), ret and (" -> " .. ret) or ""))
    end
    -- годится для проверки: Get…/Find…, возвращает объект, параметры — только
    -- контекст (объект) и один тип
    if (fn:find("^Get") or fn:find("^Find")) and ret and S.propKind(ret) == "object" then
      local typeAt, ok = nil, true
      for i, p in ipairs(sig) do
        if S.isTypeParam(p.name) and (p.kind == "number") then
          if typeAt then ok = false else typeAt = i end
        elseif not (p.kind == "object" and p.name:find("Context")) then ok = false end
      end
      if ok and typeAt then
        info.lookups[#info.lookups + 1] = { fn = fn, owner = owner, sig = sig, typeAt = typeAt }
      end
    end
  end
  local d = {}
  for _, l in ipairs(info.lookups) do d[#d + 1] = l.owner .. ":" .. l.fn end
  trail(string.format("тип героя: функций проверки %d%s", #d, #d > 0 and (" — " .. table.concat(d, ", ")) or ""))
  return info
end
-- объект, у которого вызывать функцию проверки: живой экземпляр класса или CDO
S.lookupOwner = function(l)
  local o = nil
  pcall(function() o = FindFirstOf(l.owner) end)
  if valid(o) then return o end
  pcall(function() o = StaticFindObject("/Script/Kosmos.Default__" .. l.owner) end)
  if valid(o) then return o end
  return nil
end
S.lookupHero = function(l, value, ctx)
  local obj = S.lookupOwner(l)
  if not obj then return nil, false end
  local args = {}
  for i = 1, #l.sig do args[i] = (i == l.typeAt) and value or ctx end
  local ok, r = pcall(function() return obj[l.fn](obj, table.unpack(args, 1, #l.sig)) end)
  if not ok then return nil, false end
  return valid(r) and r or nil, true
end
-- свойства героя, похожие на «тип персонажа»: { имя = значение }
S.heroTypeProps = function(hero)
  local out = {}
  pcall(function()
    local c, depth = hero:GetClass(), 0
    while valid(c) and depth < 16 do
      c:ForEachProperty(function(pr)
        local n = pr:GetFName():ToString()
        local cn = ""; pcall(function() cn = pr:GetClass():GetFName():ToString() end)
        if (cn == "ByteProperty" or cn == "EnumProperty") and S.isTypeParam(n) then
          local nl = n:lower()
          if not (nl:find("other") or nl:find("buddy") or nl:find("partner") or nl:find("target")) then
            local okV, v = pcall(function() return hero[n] end)
            if okV and type(v) == "number" then out[n] = v end
          end
        end
      end)
      local oks, sup = pcall(function() return c:GetSuperStruct() end)
      c = oks and sup or nil; depth = depth + 1
    end
  end)
  return out
end
S.otherHero = function(hero)
  if hero == S.p1 then return S.buddy end
  if hero == S.buddy then return S.p1 end
  return nil
end
-- РОЛЬ «НАПАРНИК-БОТ». В новой версии тип — это EKosmosCompanionCharacter:
-- Companion_Playpal (бот-напарник), Companion01… Игра сама передаёт
-- Companion_Playpal для Alone. Значение этой роли:
S.playpalValue = function()
  local learned = CFG.learned_types and valid(S.buddy) and CFG.learned_types[heroName(S.buddy)]
  if type(learned) == "number" then return learned, "игра сама (запомнено)" end
  local info = S.typeDiscover()
  for _, e in ipairs(info.enums) do
    if (S.enumKey(e) or ""):find("CompanionCharacter") then
      for _, en in ipairs(S.enumEntries(e)) do
        if en.name:gsub("^.*::", "") == "Companion_Playpal" then return en.value, "роль " .. en.name end
      end
    end
  end
  return nil
end
-- Где игра хранит роль героя: свойства-перечисления CompanionCharacter у
-- самого героя и у его компонентов. { ключ = { obj, name, value } }
S.roleSites = function(actor)
  local out = {}
  local function scan(obj, prefix)
    pcall(function()
      local c, depth = obj:GetClass(), 0
      while valid(c) and depth < 16 do
        c:ForEachProperty(function(pr)
          local n = pr:GetFName():ToString()
          local cn = ""; pcall(function() cn = pr:GetClass():GetFName():ToString() end)
          if cn == "EnumProperty" or cn == "ByteProperty" then
            local ek = ""
            pcall(function() local e = pr:GetEnum(); if e then ek = S.enumKey(e) or "" end end)
            if ek:find("CompanionCharacter") or (ek == "" and n:find("Companion")) then
              local okV, v = pcall(function() return obj[n] end)
              if okV and type(v) == "number" then out[prefix .. n] = { obj = obj, name = n, value = v } end
            end
          end
        end)
        local oks, sup = pcall(function() return c:GetSuperStruct() end)
        c = oks and sup or nil; depth = depth + 1
      end
    end)
  end
  scan(actor, "")
  pcall(function()
    local comps = actor:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ActorComponent"))
    comps:ForEach(function(_, el)
      local comp = el:get()
      if valid(comp) then scan(comp, clsName(comp) .. ".") end
    end)
  end)
  return out
end
S.roleText = function(sites)
  local parts = {}
  for k, st in pairs(sites) do parts[#parts + 1] = k .. "=" .. tostring(st.value) end
  table.sort(parts)
  return #parts > 0 and table.concat(parts, ", ") or "нет"
end
-- на время подсадки делаем «напарником-ботом» героя hero (обычно Low):
-- меняем роль местами с героем игрока 2; вернуть — S.roleRestore()
S.roleSwapFor = function(hero)
  if S.roleSwap then return S.roleSwap.value end
  local P = S.playpalValue()
  local buddy = S.buddy
  if P == nil or not valid(buddy) or hero == buddy then return nil end
  local mine, theirs = S.roleSites(hero), S.roleSites(buddy)
  local aiSites = valid(S.ai) and S.roleSites(S.ai) or {}
  trail(string.format("роль: у %s %s | у %s %s | у ИИ %s", heroName(hero), S.roleText(mine), heroName(buddy), S.roleText(theirs), S.roleText(aiSites)))
  local done = {}
  for k, b in pairs(theirs) do
    local m = mine[k]
    if m and b.value == P and m.value ~= P then
      local okA = pcall(function() m.obj[m.name] = P end)
      local okB = pcall(function() b.obj[b.name] = m.value end)
      if okA and okB then done[#done + 1] = { m = m, b = b, k = k } end
    end
  end
  -- ИИ.Playpal: к этому моменту герой уже передан ИИ, и игра могла сама
  -- поменять Playpal (на этого героя или на пусто). Нужен этот герой;
  -- после подсадки вернём героя игрока 2.
  local aiPrev = nil
  if valid(S.ai) then
    local before = S.aiPlaypal()
    if before ~= hero then pcall(function() S.ai.Playpal = hero end) end
    local after = S.aiPlaypal()
    trail(string.format("роль: ИИ.Playpal был %s, стал %s", valid(before) and heroName(before) or "пусто", valid(after) and heroName(after) or "пусто"))
    if after == hero then aiPrev = buddy end
  end
  if #done == 0 and not aiPrev then
    trail(string.format("роль: не нашёл, где игра хранит роль «напарник» — подсадку %s не начинаю", heroName(hero)))
    return nil
  end
  local ks = {}
  for _, d in ipairs(done) do ks[#ks + 1] = d.k end
  if aiPrev then ks[#ks + 1] = "ИИ.Playpal" end
  trail(string.format("роль: %s на время подсадки — напарник (%s)", heroName(hero), table.concat(ks, ", ")))
  S.roleSwap = { hero = hero, value = P, list = done, aiPrev = aiPrev }
  return P
end
-- кого ИИ-контроллер ведёт как напарника (поле Playpal), или nil
S.aiPlaypal = function()
  if not valid(S.ai) then return nil end
  local ok, v = pcall(function() return S.ai.Playpal end)
  if ok and valid(v) then return v end
  return nil
end
-- ДИАГНОСТИКА ДЛЯ НОВОЙ ВЕРСИИ ИГРЫ (только чтение, по разу за запуск).
-- Нужна, чтобы найти, как дать подсаживать и герою игрока 1.
-- значения полей объекта (флаги, числа, перечисления, имена, объекты — классом)
S.objFields = function(obj, stopAt)
  local parts = {}
  pcall(function()
    local c, depth = obj:GetClass(), 0
    while valid(c) and depth < 12 do
      local cn0 = c:GetFName():ToString()
      if cn0 == (stopAt or "Actor") or cn0 == "Object" or cn0 == "ActorComponent" then break end
      c:ForEachProperty(function(pr)
        local n = pr:GetFName():ToString()
        local cn = ""; pcall(function() cn = pr:GetClass():GetFName():ToString() end)
        local okV, v = pcall(function() return obj[n] end)
        if not okV then return end
        local t = type(v)
        if t == "number" or t == "boolean" then parts[#parts + 1] = n .. "=" .. tostring(v)
        elseif cn:find("Object") or cn:find("Class") then
          parts[#parts + 1] = n .. "=" .. (valid(v) and (isHero(v) and heroName(v) or clsName(v)) or "пусто")
        elseif cn == "NameProperty" then pcall(function() parts[#parts + 1] = n .. "=" .. v:ToString() end) end
      end)
      local oks, sup = pcall(function() return c:GetSuperStruct() end)
      c = oks and sup or nil; depth = depth + 1
    end
  end)
  return table.concat(parts, ", ")
end
-- место подсадки: класс и поля (раз на класс места)
S.diagSpot = function(spot)
  if not valid(spot) then return end
  S.diagSpotDone = S.diagSpotDone or {}
  local k = clsName(spot)
  if S.diagSpotDone[k] then return end
  S.diagSpotDone[k] = true
  trail(string.format("диагностика: место подсадки %s: %s", k, S.objFields(spot)))
end
-- объект-команда, которую вернула игра (подсадка Alone работает — смотрим, что внутри)
S.diagAction = function(fnName, action)
  if not (S.newApi and valid(action)) then return end
  S.diagActionDone = S.diagActionDone or {}
  if S.diagActionDone[fnName] then return end
  S.diagActionDone[fnName] = true
  trail(string.format("диагностика: команда %s → %s: %s", fnName, clsName(action), S.objFields(action, "Object")))
end
-- где игра ссылается на героев и чем отличаются их компоненты
S.diagRoles = function()
  if S.diagRolesDone or not (valid(S.p1) and valid(S.buddy)) then return end
  S.diagRolesDone = true
  local function comps(h)
    local out = {}
    pcall(function()
      local arr = h:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ActorComponent"))
      arr:ForEach(function(_, el) local c = el:get(); if valid(c) then out[clsName(c)] = c end end)
    end)
    return out
  end
  local cl, ca = comps(S.p1), comps(S.buddy)
  local onlyL, onlyA = {}, {}
  for k in pairs(cl) do if not ca[k] then onlyL[#onlyL + 1] = k end end
  for k in pairs(ca) do if not cl[k] then onlyA[#onlyA + 1] = k end end
  table.sort(onlyL); table.sort(onlyA)
  trail(string.format("диагностика: компоненты только у %s: %s | только у %s: %s", heroName(S.p1), #onlyL > 0 and table.concat(onlyL, ", ") or "нет",
    heroName(S.buddy), #onlyA > 0 and table.concat(onlyA, ", ") or "нет"))
  -- поля компонентов «про напарника» у обоих героев
  for k, c in pairs(ca) do
    if k:find("Playpal") or k:find("Companion") or k:find("Buddy") or k:find("AI") then
      trail(string.format("диагностика: %s у %s: %s", k, heroName(S.buddy), S.objFields(c, "ActorComponent")))
      if cl[k] then trail(string.format("диагностика: %s у %s: %s", k, heroName(S.p1), S.objFields(cl[k], "ActorComponent"))) end
    end
  end
  -- кто ссылается на героев: подсистема персонажей, PIP, ИИ, контроллеры, режим игры
  local holders = {}
  local function add(label, o) if valid(o) then holders[#holders + 1] = { label = label, o = o } end end
  pcall(function() add("KosmosCharactersSubsystem", FindFirstOf("KosmosCharactersSubsystem")) end)
  pcall(function() add("KosmosPIPManager", FindFirstOf("KosmosPIPManager")) end)
  pcall(function() add("ИИ", S.ai) end)
  pcall(function() add("контроллер 1", S.pc1) end)
  pcall(function() add("контроллер 2", S.pc2) end)
  pcall(function() add("режим игры", UEHelpers.GetGameModeBase()) end)
  pcall(function() add("состояние игры", UEHelpers.GetGameplayStatics():GetGameState(UEHelpers.GetWorld())) end)
  for _, hd in ipairs(holders) do
    local refs = {}
    pcall(function()
      local c, depth = hd.o:GetClass(), 0
      while valid(c) and depth < 12 do
        c:ForEachProperty(function(pr)
          local n = pr:GetFName():ToString()
          local cn = ""; pcall(function() cn = pr:GetClass():GetFName():ToString() end)
          if cn:find("Object") then
            local okV, v = pcall(function() return hd.o[n] end)
            if okV and valid(v) and isHero(v) then refs[#refs + 1] = n .. "→" .. heroName(v) end
          elseif cn == "ArrayProperty" then
            pcall(function()
              local i = 0
              hd.o[n]:ForEach(function(_, el)
                i = i + 1
                local v = el:get()
                if valid(v) and isHero(v) then refs[#refs + 1] = string.format("%s[%d]→%s", n, i, heroName(v)) end
              end)
            end)
          elseif cn == "ByteProperty" or cn == "EnumProperty" then
            if n:find("Companion") or n:find("Character") or n:find("Playpal") then
              local okV, v = pcall(function() return hd.o[n] end)
              if okV then refs[#refs + 1] = n .. "=" .. tostring(v) end
            end
          end
        end)
        local oks, sup = pcall(function() return c:GetSuperStruct() end)
        c = oks and sup or nil; depth = depth + 1
      end
    end)
    trail(string.format("диагностика: %s (%s) ссылается: %s", hd.label, clsName(hd.o), #refs > 0 and table.concat(refs, ", ") or "ни на кого из героев"))
  end
end
-- что делает сама игра, когда Low жмёт «схватить» у места подсадки (мод не вмешивается)
S.nativeWatchTick = function()
  local w = S.nativeWatch; if not w then return end
  if now() > w.untilT then
    trail(string.format("диагностика: игра сама за 4 с: монтажи Low=%s, Alone=%s", w.lowM or "нет", w.aloneM or "нет"))
    S.nativeWatch = nil
    return
  end
  pcall(function()
    local m = S.p1:GetCurrentMontage(); if valid(m) then w.lowM = m:GetFName():ToString() end
    local m2 = S.buddy:GetCurrentMontage(); if valid(m2) then w.aloneM = m2:GetFName():ToString() end
  end)
end
-- может ли герой hero на время подсадки стать «напарником-ботом»
S.canTakeRole = function(hero)
  -- только для другой версии игры (там команды получают тип, а не героя);
  -- на версии, под которую сделан мод, подсадка работает как раньше
  if not S.newApi then return true end
  local P = S.playpalValue()
  if P == nil then return true end          -- старая версия игры: роль не нужна
  if hero == S.buddy then return true end
  -- результат запоминаем для этой пары героев (после смены уровня — заново)
  local pair = tostring(hero) .. "|" .. tostring(S.buddy)
  if S.canRolePair ~= pair then S.canRole, S.canRolePair = nil, pair end
  if S.canRole == nil then
    local mine, theirs = S.roleSites(hero), S.roleSites(S.buddy)
    S.canRole = false
    for k, b in pairs(theirs) do
      if mine[k] and b.value == P and mine[k].value ~= P then S.canRole = true end
    end
    -- v9.15.9: роль хранит ИИ-контроллер — поле Playpal (кого он ведёт как
    -- напарника). Его на время подсадки и меняем.
    if not S.canRole and S.aiPlaypal() == S.buddy then S.canRole = true end
    local ap = S.aiPlaypal()
    trail(string.format("роль: у %s %s | у %s %s | ИИ.Playpal=%s — %s", heroName(hero), S.roleText(mine), heroName(S.buddy), S.roleText(theirs),
      valid(ap) and heroName(ap) or "нет", S.canRole and "можно поменять на время подсадки" or "поменять нельзя"))
  end
  return S.canRole
end
S.roleRestore = function()
  local sw = S.roleSwap; if not sw then return end
  S.roleSwap = nil
  for _, d in ipairs(sw.list) do
    pcall(function() d.m.obj[d.m.name] = d.m.value end)
    pcall(function() d.b.obj[d.b.name] = d.b.value end)
  end
  if sw.aiPrev then pcall(function() S.ai.Playpal = sw.aiPrev end) end
  trail("роль: вернул как было")
end
S.resolveHeroType = function(hero, p)
  S.typeCache = S.typeCache or {}
  local hn = heroName(hero)
  -- роль на время подсадки
  if S.roleSwap and S.roleSwap.hero == hero then return S.roleSwap.value, "роль на время подсадки" end
  -- герой игрока 2 — бывший бот-напарник: его роль известна сразу
  if hero == S.buddy and not (CFG.learned_types and CFG.learned_types[hn]) then
    local P, from = S.playpalValue()
    if P ~= nil then return P, from end
  end
  -- герой игрока 1 в новой версии: только через подмену роли
  if hero == S.p1 and S.playpalValue() ~= nil then
    return S.roleSwapFor(hero), "роль на время подсадки"
  end
  if S.typeCache[hn] then return S.typeCache[hn].v, S.typeCache[hn].from end
  -- 0) значение, которое игра сама передавала этому герою (запомнено)
  local learned = CFG.learned_types and CFG.learned_types[hn]
  if type(learned) == "number" then
    S.typeCache[hn] = { v = learned, from = "игра сама (запомнено)" }
    return learned, "игра сама (запомнено)"
  end
  local info = S.typeDiscover()
  local function done(v, from)
    S.typeCache[hn] = { v = v, from = from }
    return v, from
  end
  -- 1) спросить саму игру
  for _, l in ipairs(info.lookups) do
    local map, relevant, match = {}, false, nil
    for v = 0, 7 do
      local who, called = S.lookupHero(l, v, hero)
      if called then
        local h = valid(who) and isHero(who)
        if h then relevant = true end
        map[#map + 1] = tostring(v) .. "→" .. (h and heroName(who) or (valid(who) and clsName(who) or "пусто"))
        if who == hero and match == nil then match = v end
      end
    end
    trail(string.format("тип героя: %s:%s находит %s", l.owner, l.fn, table.concat(map, ", ")))
    if relevant then
      if match ~= nil then return done(match, "игра: " .. l.fn) end
      trail(string.format("тип героя: %s не находит %s ни по одному значению", l.fn, hn))
      return nil
    end
  end
  -- 2) свойство самого героя (если у второго героя оно другое)
  local mine = S.heroTypeProps(hero)
  local other = S.otherHero(hero)
  local theirs = valid(other) and S.heroTypeProps(other) or {}
  local parts = {}
  for n, v in pairs(mine) do parts[#parts + 1] = n .. "=" .. tostring(v) .. (theirs[n] ~= nil and (" (у " .. heroName(other) .. " " .. tostring(theirs[n]) .. ")") or "") end
  if #parts > 0 then trail(string.format("тип героя: свойства %s: %s", hn, table.concat(parts, ", "))) end
  local best = nil
  for n, v in pairs(mine) do
    if theirs[n] == nil or theirs[n] ~= v then
      local score = (n == p.name and 3) or (n:find(p.name, 1, true) and 2) or 1
      if not best or score > best.score then best = { n = n, v = v, score = score } end
    end
  end
  if best then return done(best.v, "свойство " .. best.n) end
  -- 3) перечисление по имени героя
  local enums = {}
  if p.enum then enums[#enums + 1] = p.enum end
  for _, e in ipairs(info.enums) do enums[#enums + 1] = e end
  table.sort(enums, function(a, b)
    local ka, kb = S.enumKey(a) or "", S.enumKey(b) or ""
    local sa = (ka:find(p.name, 1, true) and 2) or (ka:find("CharacterType") and 1) or 0
    local sb = (kb:find(p.name, 1, true) and 2) or (kb:find("CharacterType") and 1) or 0
    return sa > sb
  end)
  -- имя героя должно совпасть со значением целиком (или отдельным словом):
  -- «SlowWalk» — не «Low»
  local lhn = hn:lower()
  for _, e in ipairs(enums) do
    local key = S.enumKey(e) or ""
    if key:find("Companion") or key:find("CharacterType") then
      for _, en in ipairs(S.enumEntries(e)) do
        local short = en.name:gsub("^.*::", ""):lower()
        local hit = (short == lhn)
        for w in short:gmatch("[%a%d]+") do if w == lhn then hit = true end end
        if lhn ~= "" and lhn ~= "?" and hit then return done(en.value, "по имени " .. en.name) end
      end
    end
  end
  return nil
end
-- Слушаем команды, которые игра сама даёт ИИ-напарнику (когда второй игрок
-- выключен): из них узнаём тип героя «из первых рук» и запоминаем в настройках.
S.learnHooks = function()
  if S.learnHooked then return end
  S.learnHooked = true
  local n = 0
  for group, path in pairs(S.CMD_CLASSES) do
    local names = {}
    pcall(function() StaticFindObject(path):ForEachFunction(function(f) names[#names + 1] = f:GetFName():ToString() end) end)
    for _, fn in ipairs(names) do
      local sig = S.readSig(path, fn)
      local at = nil
      for i, prm in ipairs(sig) do if prm.heroType then at = i end end
      if at then
        local ok = pcall(function()
          RegisterHook(path .. ":" .. fn, function(ctx, ...)
            if S.inCmd then return end
            local args = { ... }
            pcall(S.learnFromGame, fn, args[at])
          end)
        end)
        if ok then n = n + 1 end
      end
    end
  end
  trail(string.format("тип героя: слушаю команды игры напарнику (%d функций)", n))
end
S.learnFromGame = function(fn, param)
  local v = nil; pcall(function() v = param:get() end)
  if type(v) ~= "number" then return end
  -- кому игра даёт команду: герою под ИИ-контроллером
  local heroesAI = {}
  for _, ai in ipairs(FindAllOf("KosmosAIController") or {}) do
    local okp, pawn = pcall(function() return ai.Pawn end)
    if okp and valid(pawn) and isHero(pawn) then heroesAI[#heroesAI + 1] = pawn end
  end
  if #heroesAI ~= 1 then
    trail(string.format("тип героя: игра дала %s с типом %d, но героев под ИИ %d — не запоминаю", fn, v, #heroesAI))
    return
  end
  local hn = heroName(heroesAI[1])
  CFG.learned_types = CFG.learned_types or {}
  if CFG.learned_types[hn] ~= v then
    CFG.learned_types[hn] = v
    pcall(saveSettings)
    S.typeCache = nil
    trail(string.format("тип героя: игра сама дала %s герою %s с типом %d — запомнил", fn, hn, v))
  end
end
S.cmdSig = {}
S.cmdCall = function(group, fnName, ...)
  local cmds = S.cmdObj(group)
  local given = table.pack(...)
  local key = group .. ":" .. fnName
  local sig = S.cmdSig[key]
  if not sig then
    sig = S.readSig(S.CMD_CLASSES[group], fnName)
    S.cmdSig[key] = sig
    if #sig ~= 0 and #sig ~= given.n then
      S.newApi = true
      trail(string.format("команды напарнику: у %s другие параметры (%d вместо %d): %s — подбираю по видам", fnName, #sig, given.n, S.sigText(sig)))
      for _, p in ipairs(sig) do
        if p.enum then trail(string.format("команды напарнику: %s.%s — перечисление %s: %s", fnName, p.name, S.enumKey(p.enum) or "?", S.enumText(p.enum))) end
      end
      pcall(S.apiFingerprint)
    end
  end
  if #sig == 0 or #sig == given.n then return cmds[fnName](cmds, ...) end
  local function kindOf(v)
    local t = type(v)
    if t == "number" then return "number" elseif t == "boolean" then return "bool" elseif t == "table" then return "struct" end
    if t == "userdata" then
      if pcall(function() return v:GetFullName() end) then return "object" end
      if pcall(function() return v:ToString() end) then return "name" end
    end
    return "other"
  end
  local used, args, desc, missing = {}, {}, {}, {}
  local hasType = false
  for _, p in ipairs(sig) do if p.heroType then hasType = true end end
  for i, p in ipairs(sig) do
    local v, found = nil, false
    -- тип персонажа — у героя, которому даём команду; наши числа на него не тратим
    if p.heroType then
      local hero = isHero(given[1]) and given[1] or S.buddy
      local hv, from = nil, nil
      hv, from = S.resolveHeroType(hero, p)
      if hv == nil then
        trail(string.format("команды напарнику: %s — не узнал %s для %s, команду не даю", fnName, p.name, heroName(hero)))
        return nil
      end
      S.typeLogged = S.typeLogged or {}
      if S.typeLogged[key] ~= hv then
        S.typeLogged[key] = hv
        trail(string.format("команды напарнику: %s.%s = %s для %s (%s)", fnName, p.name, tostring(hv), heroName(hero), from or "?"))
      end
      v, found = hv, true
    end
    -- «контекст мира» — любой объект уровня; наши значения на него не тратим
    if not found and p.kind == "object" and (p.name:find("WorldContext") or p.name:find("Context")) then
      v, found = given[1], true
      -- герой, которому раньше давали команду, теперь передаётся через контекст и тип
      if hasType then used[1] = true end
    end
    -- объект — тот из наших, что подходит по классу параметра
    if not found and p.kind == "object" and p.pcls then
      for j = 1, given.n do
        if not used[j] and kindOf(given[j]) == "object" then
          local okIs, is = pcall(function() return given[j]:IsA(p.pcls) end)
          if okIs and is then v, found = given[j], true; used[j] = true; break end
        end
      end
    end
    if not found then
      for j = 1, given.n do
        if not used[j] and kindOf(given[j]) == p.kind then v, found = given[j], true; used[j] = true; break end
      end
    end
    -- значения для параметра нет: вызов «наугад» может уронить игру
    -- (так было с подсадкой), поэтому такую команду не даём, а пишем, чего не хватило
    if not found then missing[#missing + 1] = p.name .. ":" .. p.cls end
    args[i] = v
    desc[#desc + 1] = p.name .. "=" .. (kindOf(v) == "object" and clsName(v) or tostring(v))
  end
  if #missing > 0 then
    S.missLogged = S.missLogged or {}
    if not S.missLogged[key] then
      S.missLogged[key] = true
      trail(string.format("команды напарнику: %s — нечем заполнить %s, команду не даю", fnName, table.concat(missing, ", ")))
    end
    return nil
  end
  S.argsLogged = S.argsLogged or {}
  if not S.argsLogged[key] then S.argsLogged[key] = true; trail(string.format("команды напарнику: вызываю %s(%s)", fnName, table.concat(desc, ", "))) end
  S.inCmd = true
  local okc, res = pcall(function() return cmds[fnName](cmds, table.unpack(args, 1, #sig)) end)
  S.inCmd = false
  if not okc then error(res, 0) end
  return res
end
S.playpalCall = function(fnName, ...) return S.cmdCall("Interactions", fnName, ...) end
-- При старте кооператива: сверяем число параметров у всех команд, которые
-- даёт мод. Отличается хоть одна — пишем в лог весь API этой версии игры.
S.CMD_EXPECT = {
  { "Interactions", "PlaypalBoost", 2 }, { "Interactions", "PlaypalFreeDraggable", 5 },
  { "Interactions", "PlaypalPushPull", 4 }, { "Carriable", "PlaypalCarriable_Putdown", 3 },
  { "Carriable", "PlaypalCarriable_Pickup", 2 }, { "Carriable", "PlaypalCarriable_Throw", 3 },
  { "WeaponTools", "PlaypalWeaponAttack", 8 }, { "WeaponTools", "PlaypalWeaponShowHide", 2 },
}
S.checkApi = function()
  if S.apiChecked then return end
  S.apiChecked = true
  local diff = {}
  for _, e in ipairs(S.CMD_EXPECT) do
    local sig = S.readSig(S.CMD_CLASSES[e[1]], e[2])
    if #sig == 0 then diff[#diff + 1] = e[2] .. ": нет в игре"
    elseif #sig ~= e[3] then diff[#diff + 1] = string.format("%s: %d вместо %d", e[2], #sig, e[3]) end
  end
  if #diff == 0 then trail("команды напарнику: версия игры совпадает с той, под которую сделан мод")
  else
    S.newApi = true
    trail("команды напарнику: ДРУГАЯ ВЕРСИЯ ИГРЫ — " .. table.concat(diff, "; "))
    pcall(S.apiFingerprint)
    pcall(S.learnHooks)
    pcall(S.typeDiscover)
  end
end
local function nearestDraggable()
  local best, bestD
  for _, d in ipairs(FindAllOf("KosmosDraggable") or {}) do
    if valid(d) then
      local ok, dist = pcall(function() return d:GetDistanceTo(S.buddy) end)
      local okz, dz = pcall(function() return math.abs(d:K2_GetActorLocation().Z - S.buddy:K2_GetActorLocation().Z) end)
      if ok and dist < 280 and okz and dz < 150 and (not bestD or dist < bestD) then best, bestD = d, dist end
    end
  end
  return best, bestD
end
local function viewYaw()
  local ok, rot
  if S.split and S.nativeCam then ok, rot = pcall(function() return S.pc2.PlayerCameraManager:GetCameraRotation() end)
  elseif S.split and valid(S.cam2) then ok, rot = pcall(function() return S.cam2:K2_GetActorRotation() end)
  else ok, rot = pcall(function() return S.pc1.PlayerCameraManager:GetCameraRotation() end) end
  if ok and rot then return math.rad(rot.Yaw) end
  return 0
end
local DRAG_REACH = 250
local function dragTarget(f, r)
  local okb, bl = pcall(function() return S.drag.box:K2_GetActorLocation() end)
  if not okb then return nil end
  if f == 0 and r == 0 then return { X = bl.X, Y = bl.Y, Z = bl.Z } end
  local y = viewYaw()
  local fx, fy = math.cos(y), math.sin(y)
  local rx, ry = -fy, fx
  local wx, wy = fx * f + rx * r, fy * f + ry * r
  local len = math.sqrt(wx * wx + wy * wy); if len > 1 then wx, wy = wx / len, wy / len end
  return { X = bl.X + wx * DRAG_REACH, Y = bl.Y + wy * DRAG_REACH, Z = bl.Z }
end
local function issueDrag()
  local loc = dragTarget(S.drag.f or 0, S.drag.r or 0); if not loc then return false end
  local m = placeMarker("dragTarget", loc); if not valid(m) then return false end
  local ok, action = try("FreeDraggable", function()
    return S.playpalCall("PlaypalFreeDraggable", S.buddy, S.drag.box, m, loc, 40)
  end)
  if ok and valid(action) then
    try("FreeDraggable Activate", function() action:Activate() end)
    S.drag.issuedAt = S.frames
    trail("команда: тащить")
    return true
  end
  return false
end
local function startDrag(box)
  S.drag = { box = box, f = 0, r = 0 }
  if issueDrag() then log("напарник: тащить %s", box:GetFName():ToString()); return true end
  S.drag = nil
  return false
end
local function endDrag()
  if not S.drag then return end
  S.drag = nil
  try("drag stop", function() S.ai:StopAllAICommands() end)
  try("drag release", function() S.buddy:AI_SetRawPressedInteract(false) end)
  log("напарник отпустил ящик")
end
local function dragTick(f, r, grab)
  if not grab or not valid(S.drag.box) then endDrag(); return end
  S.drag.f, S.drag.r = f, r
  local loc = dragTarget(f, r)
  if loc and valid(S.dragTarget) then pcall(function() S.dragTarget:K2_SetActorLocation(loc, false, {}, true) end) end
  -- команда закончилась (дотащил до метки), а игрок ещё держит и тянет — даём новую
  if S.frames - (S.drag.issuedAt or 0) > 30 then
    local ok, busy = pcall(function() return S.ai:IsAiCommand() end)
    if ok and not busy and (f ~= 0 or r ~= 0) and S.frames - (S.drag.issuedAt or 0) > 45 then issueDrag() end
  end
end

-- Ящики «на направляющей» (ConstrainedBox): ходят только вперёд-назад.
-- ИИ двигает их командой «доведи ящик до положения N» (0…1). Пока игрок 2
-- держит «схватить», переводим наклон стика в нужное положение ящика.
local function nearestCBox()
  local best, bestD
  for _, o in ipairs(FindAllOf("KosmosEnvironmentInteractable") or {}) do
    if valid(o) and cname(o):find("ConstrainedBox") then
      local ok, d = pcall(function() return o:GetDistanceTo(S.buddy) end)
      if ok and d < 300 and (not bestD or d < bestD) then best, bestD = o, d end
    end
  end
  return best, bestD
end
local function cboxProgress(box)
  local t1, t2 = {}, {}
  local ok = pcall(function() box:GetPlaypalInteractInfo(t1, t2) end)
  if ok and type(t1.OutProgress) == "number" then return t1.OutProgress end
end
local function stickWorld(f, r)
  if f == 0 and r == 0 then return nil end
  local y = viewYaw()
  local fx, fy = math.cos(y), math.sin(y)
  return fx * f - fy * r, fy * f + fx * r
end
local function cboxIssue(target)
  local c = S.cbox
  local ok, action = try("PushPull", function()
    return S.playpalCall("PlaypalPushPull", S.buddy, c.box, target, 3)
  end)
  if ok and valid(action) then
    try("PushPull Activate", function() action:Activate() end)
    c.action, c.target, c.issuedAt = action, target, S.frames
    trail(string.format("команда: ящик → %.2f", target))
    return true
  end
  return false
end
local function startCBox(box)
  local p = cboxProgress(box)
  S.cbox = { box = box, lastP = p, lastLoc = nil, D = nil, trial = 1 }
  pcall(function() S.cbox.lastLoc = box:K2_GetActorLocation() end)
  log("напарник: ящик на направляющей %s, положение %s", box:GetFName():ToString(), p and string.format("%.2f", p) or "?")
  if not p then S.cbox = nil; return false end
  if cboxIssue(p) then return true end
  S.cbox = nil
  return false
end
local function endCBox()
  if not S.cbox then return end
  S.cbox = nil
  try("cbox stop", function() S.ai:StopAllAICommands() end)
  try("cbox release", function() S.buddy:AI_SetRawPressedInteract(false) end)
  log("напарник отпустил ящик")
end
local function cboxTick(f, r, grab)
  local c = S.cbox
  if not grab or not valid(c.box) then endCBox(); return end
  local p = cboxProgress(c.box); if not p then return end
  local okl, loc = pcall(function() return c.box:K2_GetActorLocation() end)
  -- узнаём, в какую сторону ящик едет при росте положения
  if okl and c.lastP and c.lastLoc and math.abs(p - c.lastP) > 0.02 then
    local dp = p - c.lastP
    local dx, dy = (loc.X - c.lastLoc.X) / dp, (loc.Y - c.lastLoc.Y) / dp
    local len = math.sqrt(dx * dx + dy * dy)
    if len > 1 then
      if not c.D then log("ящик: направление движения определено") end
      c.D = { X = dx / len, Y = dy / len }
    end
    c.lastP, c.lastLoc = p, loc
  elseif not c.lastP then c.lastP, c.lastLoc = p, okl and loc or nil end
  local wx, wy = stickWorld(f, r)
  local target
  if wx then
    local dir
    if c.D then dir = (wx * c.D.X + wy * c.D.Y) >= 0 and 1 or -1
    else
      -- направление ещё не знаем: пробуем, и если ящик не сдвинулся — в другую сторону
      if c.trialAt and S.frames - c.trialAt > 60 and math.abs(p - (c.trialP or p)) < 0.01 then c.trial = -c.trial; c.trialAt = nil end
      if not c.trialAt then c.trialAt, c.trialP = S.frames, p end
      dir = c.trial
    end
    target = math.max(0, math.min(1, p + dir * 0.35))
  else
    target = p
  end
  -- пробуем менять цель на ходу, не перезапуская команду
  if c.action then pcall(function() local cc = c.action.CurrentCommand; if cc and cc:IsValid() then cc.EndValue = target end end) end
  local okb, busy = pcall(function() return S.ai:IsAiCommand() end)
  local need = math.abs(target - (c.target or -1)) > 0.12 or (okb and not busy and wx ~= nil)
  if need and S.frames - (c.issuedAt or 0) > 20 then cboxIssue(target) end
end

-- Подсадка. Места для подсадки (BP_Boost) в одиночной игре рассчитаны только
-- на напарника-ИИ: живой герой за них «схватиться» не может. Поэтому, когда
-- игрок 2 жмёт «схватить» у такого места, мод на время подсадки отдаёт героя
-- ИИ и даёт ему команду «подсади», а потом возвращает героя игроку 2.
-- ПОДСАДКА — как в самой игре, только в отмеченных местах (BP_Boost).
-- Кто первым нажал «схватить» (RT) у такого места, тот подсаживает: его героя мод на время
-- отдаёт ИИ с командой игры «подсади» (анимации и всё остальное — родные).
-- Второй игрок запрыгивает сам, как в обычной игре с ИИ-напарником.
-- Когда подсадка закончилась, герой возвращается своему игроку.
S.BOOST_RADIUS = 330
S.nearestBoostTo = function(hero)
  local best, bestD
  local okb, bl = pcall(function() return hero:K2_GetActorLocation() end)
  if not okb then return nil end
  for _, o in ipairs(FindAllOf("KosmosEnvironmentInteractable") or {}) do
    if valid(o) and cname(o):find("Boost") then
      local okd, d, dz = pcall(function() local ol = o:K2_GetActorLocation(); return dist(ol, bl), math.abs(ol.Z - bl.Z) end)
      -- место должно быть на том же уровне (не подсаживать «сверху» уступа)
      if okd and d < S.BOOST_RADIUS and dz < 150 and (not bestD or d < bestD) then best, bestD = o, d end
    end
  end
  return best
end
-- Пока ИИ ведёт героя к месту подсадки, второй герой рядом мешает: игра
-- «расталкивает» персонажей друг от друга, и герой топчется в метре от места.
-- На время подсадки героям разрешено проходить друг сквозь друга, а
-- расталкивание выключено; после подсадки всё возвращается.
S.boostPassThrough = function(on)
  local a, b = S.p1, S.buddy
  if not (valid(a) and valid(b)) then return end
  pcall(function()
    if on then a:MoveIgnoreActorAdd(b); b:MoveIgnoreActorAdd(a)
    else a:MoveIgnoreActorRemove(b); b:MoveIgnoreActorRemove(a) end
  end)
  pcall(function()
    local sub = charsSub()
    if on then
      if S.repulsionWas == nil then S.repulsionWas = sub.AgentRepulsionStrength end
      sub.AgentRepulsionStrength = 0
    elseif S.repulsionWas ~= nil then
      sub.AgentRepulsionStrength = S.repulsionWas; S.repulsionWas = nil
    end
  end)
end
-- Вещи героев (лук, ключ, фонарик…) — отдельные «актёры», у которых есть
-- владелец. Когда на время подсадки героя игрока 1 ведёт ИИ, игра при
-- возврате героя оставляла вещь без владельца, и при следующем «достать
-- вещь» игра падала (обращалась к месту владельца, которого нет). Запоминаем
-- владельцев вещей и возвращаем, если игра их потеряла.
S.itemOwners = S.itemOwners or {}
S.snapshotItemOwners = function(why)
  local n = 0
  for _, o in ipairs({ S.p1, S.buddy, S.pc1, S.pc2, S.ai }) do
    if valid(o) then
      pcall(function()
        o.Children:ForEach(function(_, el)
          local a = el:get()
          local isCarry = false
          pcall(function() local cc = carriableClass(); isCarry = valid(cc) and a:IsA(cc) end)
          if valid(a) and not isCarry then
            local key = a:GetFullName()
            if not S.itemOwners[key] then n = n + 1 end
            S.itemOwners[key] = { a = a, owner = o }
          end
        end)
      end)
    end
  end
  if n > 0 then trail(string.format("вещи героев: запомнил владельцев ещё у %d (%s)", n, why or "")); pcall(S.installInvTrace) end
end
S.fixItemOwners = function(why)
  local fixed = {}
  for key, rec in pairs(S.itemOwners) do
    if not valid(rec.a) then S.itemOwners[key] = nil
    else
      local cur = nil; pcall(function() cur = rec.a.Owner end)
      if not valid(cur) and valid(rec.owner) then
        local okS, eS = pcall(function() rec.a:SetOwner(rec.owner) end)
        local now2 = nil; pcall(function() now2 = rec.a.Owner end)
        fixed[#fixed + 1] = cname(rec.a) .. " → " .. cname(rec.owner) .. (valid(now2) and "" or (" (не держится" .. (okS and "" or (": " .. tostring(eS))) .. ")"))
      end
    end
  end
  if #fixed > 0 then trail("вещи героев: вернул владельцев (" .. (why or "") .. "): " .. table.concat(fixed, ", ")) end
end
-- Разбор «после подсадки не включается фонарик»: записываем вызовы функций
-- инвентаря и самих вещей (что игра делает с вещью во время подсадки и после)
S.installInvTrace = function()
  S.invHooked = S.invHooked or {}
  local classes, seen = {}, S.invHooked
  local function add(c) if valid(c) then local k = c:GetFullName(); if not seen[k] then seen[k] = true; classes[#classes + 1] = c end end end
  pcall(function() for _, c in ipairs(FindAllOf("InventoryComponent") or {}) do add(c:GetClass()) end end)
  for _, rec in pairs(S.itemOwners) do pcall(function() if valid(rec.a) then add(rec.a:GetClass()) end end) end
  local n = 0
  for _, cls in ipairs(classes) do
    local c, depth = cls, 0
    while valid(c) and depth < 4 do
      local cn = ""; pcall(function() cn = c:GetFName():ToString() end)
      if cn == "Actor" or cn == "ActorComponent" or cn == "Object" then break end
      if cn:find("Inventory") or cn:find("Flashlight") or cn:find("Weapon") or cn:find("Item") then
        local names = {}
        pcall(function() c:ForEachFunction(function(f) names[#names + 1] = f:GetFName():ToString() end) end)
        if CFG.inv_trace == true then trail("вещи: функции " .. cn .. ": " .. table.concat(names, ", ")) end
      end
      pcall(function()
        c:ForEachFunction(function(f)
          pcall(function()
            local fname = f:GetFName():ToString()
            -- v9.15.5: ВЫЛЕТЫ. Раньше здесь перехватывались все функции вещи и её
            -- родителей — в том числе внутренние функции игры (сетевые, «снимок
            -- чекпоинта»…), а «вещью» оказывались и люки, и рычаги. Игра падала
            -- через несколько секунд или минут. Для работы нужны только «достал»
            -- и «убрал»; остальное — запись для разбора, только с inv_trace.
            if CFG.inv_trace ~= true and fname ~= "OnWeaponTakeOut" and fname ~= "OnWeaponStashed" then return end
            if fname:find("^Get") or fname:find("^Is") or fname:find("^Has") or fname:find("Tick") or fname:find("Ubergraph") or fname:find("^Can") or fname:find("^Does") then return end
            local full = f:GetFullName():gsub("^Function ", "")
            RegisterHook(full, function(ctx, ...)
              -- какая вещь у героя сейчас в руках (для подсадки)
              if fname == "OnWeaponTakeOut" or fname == "OnWeaponStashed" then
                pcall(function()
                  local it = ctx:get(); local ow = it:GetOwner()
                  S.heldItem = S.heldItem or {}
                  S.heldItemKnown = S.heldItemKnown or {}
                  if valid(ow) then S.heldItem[ow:GetFullName()] = (fname == "OnWeaponTakeOut") and it or nil; S.heldItemKnown[ow:GetFullName()] = true end
                  -- вещи, которые прячутся, когда их убирают (а не висят на виду)
                  S.toolSeenOut = S.toolSeenOut or {}
                  if fname == "OnWeaponTakeOut" then S.toolSeenOut[it:GetFullName()] = true; S.wantGATrace = true end
                end)
              end
              if CFG.inv_trace ~= true then return end
              S.invTraceCnt = S.invTraceCnt or {}
              local cc = S.invTraceCnt[full]; local t = now()
              if not cc or t - cc.t > 10 then cc = { t = t, n = 0 }; S.invTraceCnt[full] = cc end
              cc.n = cc.n + 1; if cc.n > 4 then return end
              local who = ""; pcall(function() local o = ctx:get(); who = cname(o); local ow = o:GetOwner(); if valid(ow) then who = who .. "@" .. cname(ow) end end)
              local parts = {}
              for _, prm in ipairs({ ... }) do
                local okg, v = pcall(function() return prm:get() end)
                local d = okg and S.audioTraceArg(v) or nil
                if d and #parts < 4 then parts[#parts + 1] = d end
              end
              trail("вещи: " .. who .. "." .. fname .. (#parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or ""))
            end)
            n = n + 1
          end)
        end)
      end)
      local ok, sup = pcall(function() return c:GetSuperStruct() end)
      c = ok and sup or nil; depth = depth + 1
    end
  end
  if #classes > 0 then trail(string.format("вещи: слежу за %d новыми классами (%d функций)", #classes, n)) end
end
-- Вызвать функцию вещи по имени, подставив параметры по типам
S.itemCall = function(item, fname, given)
  local f = nil
  local c, depth = item:GetClass(), 0
  while valid(c) and not f and depth < 6 do
    pcall(function() c:ForEachFunction(function(ff) if not f and ff:GetFName():ToString() == fname then f = ff end end) end)
    local ok, sup = pcall(function() return c:GetSuperStruct() end); c = ok and sup or nil; depth = depth + 1
  end
  if not f then return false, "нет функции" end
  local args, nargs = {}, 0
  pcall(function()
    f:ForEachProperty(function(pr)
      local n = pr:GetFName():ToString(); if n == "ReturnValue" then return end
      local cn = ""; pcall(function() cn = pr:GetClass():GetFName():ToString() end)
      local v = nil
      if cn == "BoolProperty" then v = false
      elseif cn:find("Int") or cn == "FloatProperty" or cn == "ByteProperty" or cn == "EnumProperty" then v = 0
      elseif cn == "StructProperty" then v = {} end
      nargs = nargs + 1
      if given and given[nargs] ~= nil then v = given[nargs] end
      args[nargs] = v
    end)
  end)
  return pcall(function() item[fname](item, table.unpack(args, 1, nargs)) end)
end
-- Если у героя игрока 1 в руках вещь (фонарик), то при передаче героя ИИ на
-- время подсадки игра эту вещь уничтожает, а потом при попытке её достать
-- падает. Поэтому перед подсадкой вещь убираем, как это делает сам игрок,
-- а после подсадки достаём снова.
S.p1HeldItem = function(hero)
  hero = hero or S.p1
  local it, known = nil, false
  pcall(function()
    local k = hero:GetFullName()
    if S.heldItem and S.heldItem[k] ~= nil then known = true; it = S.heldItem[k] end
    if S.heldItem and S.heldItemKnown and S.heldItemKnown[k] then known = true end
  end)
  if valid(it) then return it end
  if known then return nil end
  -- до первого «достал/убрал» спрашиваем саму вещь: в руках ли она
  for _, rec in pairs(S.itemOwners or {}) do
    local found = nil
    pcall(function() if valid(rec.a) and rec.owner == hero and rec.a:IsInUse() == true then found = rec.a end end)
    if found then return found end
  end
  return nil
end
-- Вещи героя игрока 1, которые ещё не спрятаны (в руках или ещё убираются).
-- Игра прячет вещь на пояс чуть позже события «убрал»; если в этот момент
-- героя забирает ИИ, игра считает вещь брошенной: она теряет владельца,
-- улетает с героя, а при попытке её достать игра падает.
S.p1UnhiddenItems = function(hero)
  hero = hero or S.p1
  local out = {}
  for _, rec in pairs(S.itemOwners or {}) do
    pcall(function()
      if valid(rec.a) and rec.owner == hero and rec.a.bHidden == false then
        local seen = S.toolSeenOut and S.toolSeenOut[rec.a:GetFullName()]
        local inUse = false; pcall(function() inUse = rec.a:IsInUse() == true end)
        if seen or inUse then out[#out + 1] = rec.a end
      end
    end)
  end
  return out
end
-- Сделать fn, когда у героя пустые руки. Если вещь в руках — «нажимаем»
-- кнопку «убрать» и ждём, пока игра её спрячет (не дольше 3 с).
S.withHandsFree = function(hero, fn, why)
  local ga = valid(hero) and S.p1EquipAbility(hero) or nil
  if not ga then fn(); return end
  if S.handsFree then return end
  local ok, e = S.gaPress(ga)
  trail(string.format("%s: у %s в руках вещь — нажимаю за игрока «убрать» (%s)", why or "передача героя", heroName(hero), ok and "ок" or tostring(e)))
  S.handsFree = { hero = hero, ga = ga, fn = fn, at = S.frames, why = why }
end
S.handsFreeTick = function()
  local h = S.handsFree; if not h then return end
  local active = false
  pcall(function() active = valid(h.ga) and h.ga.bIsActive == true end)
  local hidden = #S.p1UnhiddenItems(h.hero) == 0
  local done = not active and hidden and S.frames - h.at >= 10
  if done or S.frames - h.at > 180 or S.frames < h.at then
    S.handsFree = nil
    trail(string.format("%s: вещь %s", h.why or "передача героя", done and "убрана — продолжаю" or "не убралась за 3 с — продолжаю как есть"))
    local ok, e = pcall(h.fn)
    if not ok then log("ошибка после уборки вещи: %s", tostring(e)) end
  end
end
-- «Нажать кнопку» за игрока: событие способности OnPress_<GUID>(TimeWaited)
S.gaPress = function(ga)
  local fn = nil
  pcall(function()
    ga:GetClass():ForEachFunction(function(f)
      local n = f:GetFName():ToString()
      if not fn and n:find("^OnPress_") then fn = n end
    end)
  end)
  if not fn then return false, "нет OnPress" end
  local ok, e = pcall(function() ga[fn](ga, 0.0) end)
  return ok, ok and fn or e
end
-- Разбор: какие функции способности вызываются при нажатии кнопки
S.traceEquipAbility = function(ga)
  if S.gaTraced or CFG.inv_trace ~= true then return end
  S.gaTraced = true
  pcall(function()
    ga:GetClass():ForEachFunction(function(f)
      pcall(function()
        local n = f:GetFName():ToString()
        if n:find("Ubergraph") then return end
        local full = f:GetFullName():gsub("^Function ", "")
        RegisterHook(full, function(ctx, ...)
          local parts = {}
          for _, prm in ipairs({ ... }) do
            local okg, v = pcall(function() return prm:get() end)
            local d = okg and S.audioTraceArg(v) or nil
            if d and #parts < 4 then parts[#parts + 1] = d end
          end
          trail("способность: " .. cname(ga) .. "." .. n .. (#parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or ""))
        end)
      end)
    end)
  end)
end
-- Активная способность «экипировать вещь» героя игрока 1 (пока вещь в руках)
S.p1EquipAbility = function(hero)
  hero = hero or S.p1
  local found = nil
  pcall(function()
    local me = hero:GetAddress()
    -- фонарик/зонт держит GA_EquipTool, гаечный ключ Alone — GA_WeaponWrench;
    -- у обеих есть своё событие нажатия «убрать» (OnPress_…)
    for _, cls in ipairs({ "GA_EquipTool_C", "GA_WeaponWrench_C" }) do
      for _, ga in ipairs(FindAllOf(cls) or {}) do
        if found then break end
        pcall(function()
          local cp = ga.CurrentPlayer
          if valid(cp) and cp:GetAddress() == me and ga.bIsActive == true then found = ga end
        end)
      end
    end
  end)
  return found
end
S.boostPendingTick = function()
  local pb = S.pendingBoost; if not pb then return end
  -- ждём, пока вещь не только «убрана», но и спрятана игрой на пояс
  local unhidden = S.p1UnhiddenItems(pb.hero)
  local gaActive = false
  if pb.ga then pcall(function() gaActive = valid(pb.ga) and pb.ga.bIsActive == true end) end
  if pb.ga and not gaActive and not pb.gaEndedAt then
    pb.gaEndedAt = S.frames
    trail(string.format("подсадка: способность «вещь в руках» закончилась через %.1f с", (S.frames - pb.at) / 60))
  end
  local stashed = not gaActive and S.p1HeldItem(pb.hero) == nil and #unhidden == 0
  if stashed and not pb.stashedAt then pb.stashedAt = S.frames end
  if (stashed and S.frames - pb.stashedAt >= 10) or S.frames - pb.at > 180 then
    S.pendingBoost = nil
    trail(string.format("подсадка: вещь %s", stashed and "убрана и спрятана — начинаю" or "не спряталась за 3 с — подсадку не начинаю (иначе вещь сломается)"))
    if stashed then S.boostStart(pb.hero, pb.owner, pb.spot)
    else toast("Сначала уберите вещь из рук") end
  end
end
-- Разбор: что хранит инвентарь (поля-объекты и массивы) до и после подсадки
S.invDiag = function(label, force)
  if CFG.inv_trace ~= true and not force then return end
  -- класс инвентаря ищем по его функции EnableItem (имя класса заранее не знаем)
  if not S.invClassName then
    pcall(function()
      ForEachUObject(function(o)
        if S.invClassName then return end
        pcall(function()
          if o:GetFName():ToString() == "EnableItem" and o:GetClass():GetFName():ToString() == "Function" then
            S.invClassName = o:GetOuter():GetFName():ToString()
          end
        end)
      end)
    end)
    trail("инвентарь: класс " .. tostring(S.invClassName))
  end
  local out = {}
  -- поля самой вещи (объекты, флаги): кто её «хозяин» для игры
  pcall(function()
    for _, a in ipairs(FindAllOf("BP_Flashlight_Inventory_C") or {}) do
      local parts = {}
      local cls, depth = a:GetClass(), 0
      while valid(cls) and depth < 5 do
        local cn = cls:GetFName():ToString(); if cn == "Actor" then break end
        pcall(function()
          cls:ForEachProperty(function(pr)
            local n = pr:GetFName():ToString()
            local pt = ""; pcall(function() pt = pr:GetClass():GetFName():ToString() end)
            pcall(function()
              local x = a[n]
              if pt:find("Object") and not pt:find("Class") then
                local v = valid(x) and cname(x) or "nil"
                if not (v:find("Component") or v:find("Curve") or v:find("Material") or v:find("Montage") or v:find("Anim")) then parts[#parts + 1] = n .. "=" .. v end
              elseif pt == "BoolProperty" then parts[#parts + 1] = n .. "=" .. tostring(x)
              end
            end)
          end)
        end)
        local ok, sup = pcall(function() return cls:GetSuperStruct() end); cls = ok and sup or nil; depth = depth + 1
      end
      out[#out + 1] = "поля фонарика: " .. table.concat(parts, "; ")
    end
  end)
  -- все фонарики и их состояние
  pcall(function()
    local fl = {}
    for _, a in ipairs(FindAllOf("BP_Flashlight_Inventory_C") or {}) do
      local st = "?"; pcall(function() st = (a:IsPendingKill() and "уничтожен" or "жив") end)
      local ow = "nil"; pcall(function() ow = valid(a.Owner) and cname(a.Owner) or "nil" end)
      local par = "nil"; pcall(function() local pa = a:GetAttachParentActor(); par = valid(pa) and cname(pa) or "nil" end)
      local d = -1; pcall(function() d = dist(a:K2_GetActorLocation(), S.p1:K2_GetActorLocation()) end)
      local d2 = -1; pcall(function() d2 = dist(a:K2_GetActorLocation(), S.buddy:K2_GetActorLocation()) end)
      local sock = "?"; pcall(function() sock = a.RootComponent:GetAttachSocketName():ToString() end)
      local hid = "?"; pcall(function() hid = tostring(a.bHidden) end)
      local inst = "?"; pcall(function() inst = tostring(a:GetInstigator() and cname(a:GetInstigator())) end)
      local use = "?"; pcall(function() use = tostring(a:IsInUse()) end)
      local th = "?"; pcall(function() th = tostring(a:GetToolHidden()) end)
      fl[#fl + 1] = a:GetFName():ToString() .. "(" .. st .. ", владелец " .. ow .. ", прикреплён к " .. par .. " [" .. sock .. "]" .. string.format(", до Low %.0f см, до Alone %.0f см", d, d2) .. ", скрыт " .. hid .. ", ToolHidden " .. th .. ", в руках " .. use .. ", инициатор " .. inst .. ")"
    end
    out[#out + 1] = "фонарики: " .. table.concat(fl, ", ")
  end)
  -- вещи, лежащие в мире (то, что можно подобрать): чьи, где, подобраны ли
  pcall(function()
    local pk = {}
    for _, c in ipairs(FindAllOf("KosmosInventoryItemComponent") or {}) do
      pcall(function()
        local a = c:GetOwner()
        local nm = "?"; pcall(function() nm = c.ItemName.ItemName:ToString() end)
        if nm == "?" then pcall(function() nm = tostring(c.ItemName) end) end
        local loc = "?"; pcall(function() local v = a:K2_GetActorLocation(); loc = string.format("%.0f %.0f %.0f", v.X, v.Y, v.Z) end)
        local par = "nil"; pcall(function() local pa = a:GetAttachParentActor(); par = valid(pa) and cname(pa) or "nil" end)
        local d = -1; pcall(function() d = dist(a:K2_GetActorLocation(), S.p1:K2_GetActorLocation()) end)
        local d2 = -1; pcall(function() d2 = dist(a:K2_GetActorLocation(), S.buddy:K2_GetActorLocation()) end)
        local hid = "?"; pcall(function() hid = tostring(a.bHidden) end)
        local col = "?"; pcall(function() col = tostring(c.IsItemCollected) end)
        local phys = "?"; pcall(function() phys = tostring(a.ItemMesh:IsSimulatingPhysics()) end)
        local use = "?"; pcall(function() use = tostring(a.CarriableUsage) end)
        pk[#pk + 1] = string.format("%s (подобрана %s, скрыта %s, физика %s, состояние %s, прикреплена к %s, место %s, до Low %.0f, до Alone %.0f)", cname(a), col, hid, phys, use, par, loc, d, d2)
      end)
    end
    out[#out + 1] = "вещи в мире: " .. table.concat(pk, ", ")
  end)
  for _, comp in ipairs(FindAllOf(S.invClassName or "InventoryComponent") or {}) do
    pcall(function()
      if not valid(comp) then return end
      local ow = comp:GetOwner()
      local parts = {}
      local cls, depth = comp:GetClass(), 0
      while valid(cls) and depth < 3 do
        local cn = cls:GetFName():ToString(); if cn == "ActorComponent" then break end
        pcall(function()
          cls:ForEachProperty(function(pr)
            local n = pr:GetFName():ToString()
            local pt = ""; pcall(function() pt = pr:GetClass():GetFName():ToString() end)
            pcall(function()
              local x = comp[n]
              if pt:find("Object") then
                local v = "nil"; if valid(x) then v = cname(x); pcall(function() if x.IsPendingKill and x:IsPendingKill() then v = v .. "(уничтожен)" end end) end
                parts[#parts + 1] = n .. "=" .. v
              elseif pt == "ArrayProperty" then
                local items = {}
                -- элементы-структуры: печатаем их поля
                local fields = {}
                pcall(function() pr:GetInner():GetStruct():ForEachProperty(function(fp) fields[#fields + 1] = { fp:GetFName():ToString(), (select(2, pcall(function() return fp:GetClass():GetFName():ToString() end))) } end) end)
                pcall(function() x:ForEach(function(_, el)
                  local e = el:get()
                  if #items >= 6 then return end
                  if #fields > 0 then
                    local fs = {}
                    for _, fd in ipairs(fields) do
                      pcall(function()
                        local v = e[fd[1]]
                        local str
                        if type(v) == "userdata" then
                          local okv = pcall(function() str = valid(v) and cname(v) or nil end)
                          if not str then local okt, t2 = pcall(function() return v:ToString() end); str = okt and t2 or (fd[2] or "?") end
                        else str = tostring(v) end
                        fs[#fs + 1] = fd[1] .. ":" .. tostring(str)
                      end)
                    end
                    items[#items + 1] = "{" .. table.concat(fs, " ") .. "}"
                  else
                    items[#items + 1] = (type(e) == "userdata" and (valid(e) and cname(e) or "nil")) or tostring(e)
                  end
                end) end)
                parts[#parts + 1] = n .. "=[" .. table.concat(items, ",") .. "]"
              elseif pt == "BoolProperty" or pt:find("Int") or pt == "NameProperty" or pt == "ByteProperty" or pt == "EnumProperty" then
                parts[#parts + 1] = n .. "=" .. tostring(type(x) == "userdata" and select(2, pcall(function() return x:ToString() end)) or x)
              end
            end)
          end)
        end)
        local ok, sup = pcall(function() return cls:GetSuperStruct() end); cls = ok and sup or nil; depth = depth + 1
      end
      out[#out + 1] = cname(ow) .. ": " .. table.concat(parts, "; ")
    end)
  end
  trail("инвентарь (" .. label .. "): " .. table.concat(out, " || "))
end
-- v9.15.2: РАЗБОР «СКОЛЬЗЯЩЕЙ ПОХОДКИ». Состояние анимации героя: скорость,
-- монтаж, ускорение, пауза анимации — и «переменные» его анимационного
-- блюпринта (снимок до и после подсадки, при F8 — сравнение со снимком).
S.animState = function(h)
  local t = {}
  pcall(function() local v = h:GetVelocity(); t[#t + 1] = string.format("скорость %.0f", math.sqrt(v.X * v.X + v.Y * v.Y)) end)
  pcall(function() local a = h.CharacterMovement:GetCurrentAcceleration(); t[#t + 1] = string.format("ускорение %.0f", math.sqrt(a.X * a.X + a.Y * a.Y)) end)
  pcall(function() t[#t + 1] = "режим " .. tostring(h.CharacterMovement.MovementMode) end)
  pcall(function() local m = h:GetCurrentMontage(); t[#t + 1] = "монтаж " .. (valid(m) and m:GetFName():ToString() or "нет") end)
  pcall(function() t[#t + 1] = "у " .. clsName(h.Controller) end)
  pcall(function()
    local m = h.Mesh
    t[#t + 1] = string.format("пауза %s, темп %.2f, тик %s, скелет-стоп %s", tostring(m.bPauseAnims), m.GlobalAnimRateScale or -1, tostring(m.VisibilityBasedAnimTickOption), tostring(m.bNoSkeletonUpdate))
    local ai = m:GetAnimInstance()
    t[#t + 1] = "аним " .. (valid(ai) and cname(ai) or "нет")
  end)
  return table.concat(t, ", ")
end
S.animSnapOf = function(h)
  local res = {}
  pcall(function()
    local ai = h.Mesh:GetAnimInstance()
    if not valid(ai) then return end
    for k, v in pairs(S.propSnap(ai)) do
      if not tostring(v):find("%.") then res[k] = v end   -- без дробных чисел: ищем «застрявшие» флаги и состояния
    end
  end)
  return res
end
S.animDiff = function(h, base, label)
  if not base then return end
  local cur = S.animSnapOf(h)
  local ch = {}
  for k, v in pairs(cur) do if base[k] ~= nil and base[k] ~= v then ch[#ch + 1] = k .. ": " .. tostring(base[k]) .. "→" .. tostring(v) end end
  table.sort(ch)
  trail(string.format("анимация %s %s: %s | изменилось: %s", heroName(h), label, S.animState(h), #ch > 0 and table.concat(ch, "; ", 1, math.min(#ch, 40)) or "ничего"))
end
S.boostEnd = function(reason)
  pcall(S.roleRestore)
  local b = S.boost; if not b then return end
  -- разбор: через 1,5 с после подсадки сравним анимацию героев со снимком до неё
  S.animCheckAt = S.frames + 90
  S.boost = nil
  -- не переключать героя туда-обратно слишком часто; после совсем короткой
  -- (сорвавшейся) подсадки ждём дольше
  S.boostCooldown = S.frames + ((b.startFrame and S.frames - b.startFrame < 90) and 180 or 45)
  pcall(S.boostPassThrough, false)
  try("boost stop", function() S.ai:StopAllAICommands() end)
  try("ai tick off", function() S.ai:SetActorTickEnabled(false) end)
  if valid(b.hero) and valid(b.owner) then
    pcall(dedupeRegistry, "после подсадки")
    if b.hero == S.p1 and S.cam1PawnHack then
      -- контроллер игрока 1 и так «считает» Low своим героем. Сначала ИИ честно
      -- отпускает героя, тогда возврат игроку 1 пройдёт полностью, как обычно.
      try("ai unpossess", function() S.ai:UnPossess() end)
      S.cam1PawnHack, S.cam1PawnLost = false, nil
    end
    safePossess(b.owner, b.hero, "подсадка: герой → своему игроку")
    -- ИИ-контроллер снова «помнит» напарника, а не героя игрока 1. Иначе игра
    -- считает героя игрока 1 напарником ИИ и через пару секунд обращается к
    -- ИИ без героя — игра падала после подсадки, которую делал игрок 1.
    pcall(function()
      local want = S.buddy   -- напарник ИИ — всегда герой игрока 2
      if S.ai.mCurrentCharacter ~= want then
        S.ai.mCurrentCharacter = want
        trail("после подсадки: ИИ снова «помнит» " .. heroName(want))
      end
    end)
    if b.hero == S.p1 then
      pcall(function() trail(string.format("после подсадки: Low у %s, герой ИК1=%s", clsName(S.p1.Controller), clsName(S.pc1.Pawn))) end)
    end
    pcall(S.keepAnimating)
    if b.hero == S.buddy then
      local ok, c = pcall(function() return S.buddy.Controller end)
      S.real = ok and c == S.pc2
      applyCam()
      S.camSnap = true
    else
      pcall(S.freezeCam1, false)
      pcall(function() S.pc1:SetViewTargetWithBlend(S.p1, 0.25, 0, 0, false) end)
    end
  end
  pcall(S.invDiag, "после подсадки")
  pcall(S.fixItemOwners, "после подсадки")
  local item = S.restoreItemAfterBoost; S.restoreItemAfterBoost = nil
  if valid(item) and b.hero == S.p1 then
    local function back()
      if valid(item) and S.p1HeldItem() == nil and not S.boost then
        local ok, e = S.itemCall(item, "RequestItem")
        trail("после подсадки: достаю " .. cname(item) .. " обратно (" .. (ok and "ок" or tostring(e)) .. ")")
      end
    end
    if ExecuteWithDelay then ExecuteWithDelay(700, function() ExecuteInGameThread(function() pcall(back) end) end) else pcall(back) end
  end
  log("подсадка закончилась (%s)", reason)
end
-- Камера игрока 1 «живёт» от его героя. Пока героя на время подсадки ведёт
-- ИИ, она теряет его и улетает. Поэтому на это время ставим неподвижную
-- камеру ровно туда, где была камера игрока 1, и смотрим через неё.
S.freezeCam1 = function(on)
  local cm = S.pc1.PlayerCameraManager
  if on then
    local l, r, f
    pcall(function() l, r, f = cm:GetCameraLocation(), cm:GetCameraRotation(), cm:GetFOVAngle() end)
    if not l then return end
    if not valid(S.cam1fix) then
      pcall(function()
        local cls = StaticFindObject("/Script/Engine.CameraActor")
        local gs = UEHelpers.GetGameplayStatics()
        local t = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = vec(l), Scale3D = { X = 1, Y = 1, Z = 1 } }
        local actor = gs:BeginDeferredActorSpawnFromClass(S.pc1, cls, t, 1, S.pc1)
        S.cam1fix = gs:FinishSpawningActor(actor, t)
      end)
    end
    if not valid(S.cam1fix) then return end
    pcall(function()
      S.cam1fix:K2_SetActorLocationAndRotation(vec(l), { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }, false, {}, true)
      S.cam1fix.CameraComponent:SetFieldOfView(f)
    end)
    S.cam1Frozen = true
  else
    if not S.cam1Frozen then return end
    S.cam1Frozen = false
    S.cam1FixLoc, S.cam1FixRot = nil, nil
    -- быстро вернуть обычную камеру комнаты (без долгого «подъезда»)
    S.camSelf = true
    pcall(function() cm:StopExternalOverTime(0.2, 0) end)
    pcall(function() cm:ResetViewOverTime(0.3, 0) end)
    S.camSelf = false
    pcall(function() cm:SetOverrideExternalCamera(false) end)
  end
end
S.applyCam1Freeze = function()
  if not (S.cam1Frozen and valid(S.cam1fix)) then return end
  local cm = S.pc1.PlayerCameraManager
  S.camSelf = true; local ok1, e1 = pcall(function() cm:StopExternalOverTime(0, 0) end); S.camSelf = false
  local ok2, e2 = true, nil
  local ok3, e3 = pcall(function() S.pc1:SetViewTargetWithBlend(S.cam1fix, 0, 0, 0, false) end)
  trail(string.format("камера 1: заморозка (внешняя=%s, переход=%s%s, вид=%s)", tostring(ok1), tostring(ok2), ok2 and "" or (" " .. tostring(e2)), tostring(ok3)))
  S.cam1FixLoc = S.cam1fix:K2_GetActorLocation()
  S.cam1FixRot = S.cam1fix:K2_GetActorRotation()
  -- Главное: камера игры ведёт «героя своего игрока». Пока героя ведёт ИИ,
  -- у игрока 1 героя нет, и камера начинает смотреть куда попало. Поэтому
  -- (не меняя, кто управляет героем) говорим контроллеру игрока 1, что его
  -- герой — по-прежнему Low. Камера тогда работает как обычно.
  S.cam1PawnHack = false
  if CFG.boost_cam_pawn ~= false then
    local okp, ep = pcall(function() S.pc1.Pawn = S.p1 end)
    local okv = pcall(function() S.pc1:SetViewTargetWithBlend(S.p1, 0, 0, 0, false) end)
    local now = nil; pcall(function() now = S.pc1.Pawn end)
    S.cam1PawnHack = okp and now == S.p1
    trail(string.format("камера 1: герой для камеры = Low (%s%s, вид=%s)", tostring(S.cam1PawnHack), okp and "" or (" " .. tostring(ep)), tostring(okv)))
  end
end
-- пока героем игрока 1 управляет ИИ: если камера игрока 1 всё же уехала от
-- замороженной точки — возвращаем её туда каждый кадр
S.holdCam1 = function()
  if not (S.cam1Frozen and S.cam1FixLoc) then return end
  if S.cam1PawnHack then
    -- держим «героя для камеры» и ничего не подкручиваем
    pcall(function()
      if S.pc1.Pawn ~= S.p1 then
        S.pc1.Pawn = S.p1
        if not S.cam1PawnLost then S.cam1PawnLost = true; trail("камера 1: игра сбросила героя для камеры — вернул") end
      end
      if S.pc1:GetViewTarget() ~= S.p1 then S.pc1:SetViewTargetWithBlend(S.p1, 0, 0, 0, false) end
    end)
    local age = S.boost and (S.frames - S.boost.startFrame) or 999
    -- раз в секунду (каждый кадр — только при разборе: CFG.inv_trace = true)
    if (CFG.inv_trace == true and age < 60) or S.frames % 60 == 0 then
      pcall(function() trail(string.format("камера 1 при подсадке (%.2f с): %s", age / 60, S.cam1Info())) end)
    end
    return
  end
  -- место подсадки переключает камеру игрока на свою «камеру подсадки» —
  -- пока подсаживает игрок 1, не даём ей это сделать
  if S.frames % 5 == 0 then
    S.camSelf = true; pcall(function() S.pc1.PlayerCameraManager:StopExternalOverTime(0, 0) end); S.camSelf = false
  end
  -- камера игры без героя может «цепляться» за сам контроллер игрока 1 —
  -- держим контроллер там, где стоит его герой
  pcall(function() S.pc1:K2_SetActorLocation(S.p1:K2_GetActorLocation(), false, {}, true) end)
  local cm = S.pc1.PlayerCameraManager
  -- первые 3 секунды — 4 раза в секунду, дальше раз в секунду
  local age = S.boost and (S.frames - S.boost.startFrame) or 999
  if (age < 180 and S.frames % 15 == 0) or S.frames % 60 == 0 then
    pcall(function()
      trail(string.format("камера 1 при подсадке (%.1f с): от точки %.0f см | %s", age / 60, dist(cm:GetCameraLocation(), S.cam1FixLoc), S.cam1Info()))
    end)
  end
  local cl = cm:GetCameraLocation()
  local d = dist(cl, S.cam1FixLoc)
  if S.cam1FixRot then
    pcall(function()
      local cr = cm:GetCameraRotation()
      local function ad(a, b) return ((a - b + 180) % 360) - 180 end
      local dp, dy = ad(S.cam1FixRot.Pitch, cr.Pitch), ad(S.cam1FixRot.Yaw, cr.Yaw)
      if math.abs(dp) + math.abs(dy) > 1 then cm:AddOverriddenCameraRotation({ Pitch = dp, Yaw = dy, Roll = 0 }) end
    end)
  end
  if d > 30 then
    pcall(function() cm:AddOverriddenCameraLocation({ X = S.cam1FixLoc.X - cl.X, Y = S.cam1FixLoc.Y - cl.Y, Z = S.cam1FixLoc.Z - cl.Z }) end)
    if not S.cam1HoldLogged then S.cam1HoldLogged = true; trail(string.format("камера 1: уезжала на %.0f см — удерживаю", d)) end
  end
end
-- v9.15.1 (жалоба с Nexus): «после смерти камера приближается слишком сильно,
-- помогает только загрузка контрольной точки». Если в момент смерти у
-- камеры игрока 1 была включена «внешняя» камера (место подсадки, рычаг,
-- крупный план), после возрождения она могла так и остаться. Через 2 с после
-- возрождения проверяем и, если она ещё включена, возвращаем обычную камеру.
-- Плюс пишем в trail.txt снимки камеры — чтобы по логу игрока понять причину.
S.cam1Dist = function()
  local d = -1
  pcall(function() d = dist(S.pc1.PlayerCameraManager:GetCameraLocation(), S.p1:K2_GetActorLocation()) end)
  return d
end
S.afterRespawnCam = function()
  local age = S.frames - S.respawnAt
  -- v9.15.3: «после каждой смерти камера всё ближе». В логе видно: во время
  -- смерти игра вызывает AddCameraZoom (0,2 на канале 1), а снятия
  -- (ClearCameraZoom) после возрождения нет — приближения копятся.
  -- Через 0,5 с после возрождения снимаем их (ClearCameraZoom по номерам) и
  -- пишем в лог расстояние камеры до Low до и через 2 с после.
  local open = S.zoomOpen or {}
  if (#open > 0 or S.zoomFixing) and CFG.reset_death_zoom ~= false then
    local cm = S.pc1.PlayerCameraManager
    if age == 30 then
      S.zoomD0 = S.cam1Dist()
      -- v9.15.3: копия списка и флаг «это мы» — наш же вызов AddCameraZoom
      -- попадал в перехват и дописывался в перебираемый список (бесконечный
      -- цикл, игра зависала после смерти)
      local list, seen = {}, {}
      for _, z in ipairs(open) do
        local key = tostring(z.ch or 1)
        if not seen[key] and #list < 4 then seen[key] = true; list[#list + 1] = z end
      end
      S.zoomOpen = {}
      S.zoomSelf = true
      -- AddCameraZoom возвращает номер приближения; снимают его ClearCameraZoom
      -- по номеру. Номер «смертельного» приближения нам не виден, поэтому
      -- узнаём текущий номер своим пустым приближением и снимаем несколько
      -- последних номеров (своё пустое — тоже)
      local ids = {}
      for _, z in ipairs(list) do
        local okA, id = pcall(function() return cm:AddCameraZoom(cm, 0.0, 0.0, z.ch or 1, 6) end)
        if okA and type(id) == "number" then
          for i = math.max(0, id - 6), id do ids[#ids + 1] = i end
        end
      end
      local cleared = 0
      for _, i in ipairs(ids) do
        if pcall(function() cm:ClearCameraZoom(i, 0.5, 6) end) then cleared = cleared + 1 end
      end
      S.zoomSelf = false
      S.zoomFixing = true
      trail(string.format("камера 1: после смерти остались приближения (%d) — обнуляю (до Low %.0f см)", #list, S.zoomD0))
    elseif age == 120 then
      trail(string.format("камера 1: через 2 с до Low %.0f см (было %.0f)", S.cam1Dist(), S.zoomD0 or -1))
      S.zoomOpen = {}; S.zoomFixing = nil
    end
  end
  if age == 120 then
    local cm = S.pc1.PlayerCameraManager
    -- «приближение» камеры игры (AddCameraZoom): после возрождения его быть не должно
    local z = 0; pcall(function() z = cm:GetGlobalCameraZoom() or 0 end)
    if math.abs(z) > 0.01 and not S.boost and not S.cam1Frozen then
      local okc, ec = pcall(function() cm:ClearCameraZoom() end)
      local z2 = -1; pcall(function() z2 = cm:GetGlobalCameraZoom() or -1 end)
      trail(string.format("камера 1: после возрождения осталось приближение %.2f — сбросил (%s, стало %.2f)", z, okc and "ок" or tostring(ec), z2))
    end
    local ext = false; pcall(function() ext = cm:GetOverrideExternalCamera() end)
    if ext == true and not S.boost and not S.cam1Frozen then
      pcall(function() cm:StopExternalOverTime(0.3, 0) end)
      pcall(function() cm:SetOverrideExternalCamera(false) end)
      trail("камера 1: после возрождения осталась внешняя камера — вернул обычную")
    end
  end
  if age >= 600 then S.respawnAt = nil end
end
-- полный снимок камеры игрока 1: где стоит, куда смотрит, что показывает
S.cam1Info = function()
  local cm = S.pc1.PlayerCameraManager
  local l, r, f = cm:GetCameraLocation(), cm:GetCameraRotation(), cm:GetFOVAngle()
  local hl = S.p1:K2_GetActorLocation()
  local bl = valid(S.buddy) and S.buddy:K2_GetActorLocation() or hl
  -- угол между направлением камеры и направлением на героя (0 = герой в центре кадра)
  local function offAngle(t)
    local yaw, pitch = math.rad(r.Yaw), math.rad(r.Pitch)
    local fx, fy, fz = math.cos(pitch) * math.cos(yaw), math.cos(pitch) * math.sin(yaw), math.sin(pitch)
    local dx, dy, dz = t.X - l.X, t.Y - l.Y, t.Z - l.Z
    local len = math.max(math.sqrt(dx * dx + dy * dy + dz * dz), 1)
    local c = (fx * dx + fy * dy + fz * dz) / len
    return math.deg(math.acos(math.max(-1, math.min(1, c))))
  end
  local ext, zoom, fade = "?", "?", "?"
  pcall(function() ext = tostring(cm:GetOverrideExternalCamera()) end)
  pcall(function() zoom = string.format("%.2f", cm:GetGlobalCameraZoom()) end)
  pcall(function() fade = string.format("%.2f", cm:GetFadeAmount()) end)
  local pawn = "?"; pcall(function() pawn = clsName(S.pc1.Pawn) end)
  local ctrl = "?"; pcall(function() ctrl = clsName(S.p1.Controller) end)
  return string.format("поз (%.0f %.0f %.0f) пов (p%.0f y%.0f r%.0f) FOV %.0f | до Low %.0f см, Low от центра %.0f° | до Alone %.0f см, Alone от центра %.0f° | вид=%s пешка ИК1=%s Low у=%s внешняя=%s зум=%s затемн=%s экран=%s",
    l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll, f, dist(l, hl), offAngle(hl), dist(l, bl), offAngle(bl),
    clsName(S.pc1:GetViewTarget()), pawn, ctrl, ext, zoom, fade, S.split and "разделён" or "общий")
end
-- может ли игра «убить» каждого героя и кем она его считает
S.kosmosLib = function()
  if not valid(S.klib) then S.klib = StaticFindObject("/Script/Kosmos.Default__KosmosBlueprintFunctionLibrary") end
  return S.klib
end
S.deathComp = function(hero)
  local c = nil
  pcall(function() c = hero:GetComponentByClass(StaticFindObject("/Script/Kosmos.KosmosCharacterDeathComponent")) end)
  return c
end
S.heroDiag = function(hero)
  local lib = S.kosmosLib()
  local function q(f) local ok, r = pcall(f); return ok and tostring(r) or "?" end
  local dc = S.deathComp(hero)
  local mon = "нет"; pcall(function() local m = hero:GetCurrentMontage(); if valid(m) then mon = m:GetFName():ToString() end end)
  return string.format("%s: можно убить=%s, игрок=%s, напарник=%s, стадия смерти=%s, убивают=%s, у=%s, анимация=%s",
    heroName(hero), q(function() return lib:CanKillPlayer(hero, hero) end),
    q(function() return lib:IsActorPlayer(hero, hero) end), q(function() return lib:IsActorPlaypal(hero, hero) end),
    q(function() return dc.CurrentDeathStage end), q(function() return dc.bIsCurrentlyBeingKilled end),
    clsName(hero.Controller), mon)
end
S.killDiag = function()
  local a = S.heroDiag(S.p1)
  local b = valid(S.buddy) and S.heroDiag(S.buddy) or "?"
  return a .. " | " .. b
end
-- Подсадка запрещает игре «убивать» обоих героев, хотя тот, кого не
-- подсаживают, в ней пока не участвует. Пока он не запрыгивает — разрешаем.
S.boostKillFix = function()
  local b = S.boost; if not b then return end
  local other = (b.hero == S.p1) and S.buddy or S.p1
  if not valid(other) then return end
  local mon = ""; pcall(function() local m = other:GetCurrentMontage(); if valid(m) then mon = m:GetFName():ToString() end end)
  local lib = S.kosmosLib()
  if mon:find("ReceiveBoost") then
    -- запрыгивает — теперь он участник, защищаем на время прыжка, как игра
    if b.killFixLogged and not b.reDisabled then
      b.reDisabled = true
      pcall(function() lib:DisableKillPlayer(other, other, 4.0) end)
      trail(string.format("подсадка: %s запрыгивает — на время прыжка снова не убивается", heroName(other)))
    end
    return
  end
  local ok, can = pcall(function() return lib:CanKillPlayer(other, other) end)
  if ok and can == false then
    local okE, e = pcall(function() lib:EnableKillPlayer(other, other) end)
    local ok2, can2 = pcall(function() return lib:CanKillPlayer(other, other) end)
    if not b.killFixLogged then
      b.killFixLogged = true
      trail(string.format("подсадка: игра запретила убивать %s — разрешил (%s%s), теперь можно=%s", heroName(other), tostring(okE), okE and "" or (" " .. tostring(e)), tostring(can2)))
    end
  end
end
-- «память» врага: все ключи его чёрной доски (цель, состояние, флаги)
S.bbDump = function(en)
  S.bbPairs = {}
  local ctrl = en.Controller
  local bb = ctrl.Blackboard
  if not valid(bb) then return "доски нет" end
  local out = {}
  local function keysOf(asset, depth)
    if not valid(asset) or depth > 4 then return end
    pcall(function() keysOf(asset.Parent, depth + 1) end)
    pcall(function()
      asset.Keys:ForEach(function(_, el)
        pcall(function()
          local e = el:get()
          local name = e.EntryName
          local ns = name:ToString()
          local kt = clsName(e.KeyType)
          local v = "?"
          if kt:find("Object") then local o = bb:GetValueAsObject(name); v = valid(o) and (o == S.p1 and "Low" or o == S.buddy and "Alone" or cname(o)) or "пусто"
          elseif kt:find("Bool") then v = tostring(bb:GetValueAsBool(name))
          elseif kt:find("Float") then v = string.format("%.1f", bb:GetValueAsFloat(name))
          elseif kt:find("Int") then v = tostring(bb:GetValueAsInt(name))
          elseif kt:find("Enum") then v = tostring(bb:GetValueAsEnum(name))
          elseif kt:find("Name") then v = bb:GetValueAsName(name):ToString()
          elseif kt:find("Vector") then local x = bb:GetValueAsVector(name); v = string.format("(%.0f %.0f %.0f)", x.X, x.Y, x.Z)
          elseif kt:find("Class") then v = clsName(bb:GetValueAsClass(name)) end
          out[#out + 1] = ns .. "=" .. v
          S.bbPairs[ns] = v
        end)
      end)
    end)
  end
  local asset = nil
  pcall(function() asset = bb.BlackboardAsset end)
  if not valid(asset) then pcall(function() asset = bb.DefaultBlackboardAsset end) end
  keysOf(asset, 0)
  return #out > 0 and table.concat(out, ", ") or "ключей не прочитал"
end
-- кого игра считает главным, вторым, напарником, «своим» героем
S.roleDiag = function()
  local lib = S.kosmosLib()
  local function who(f) local ok, o = pcall(f); if not ok then return "?" end; return valid(o) and (o == S.p1 and "Low" or o == S.buddy and "Alone" or cname(o)) or "нет" end
  local function q(f) local ok, r = pcall(f); return ok and tostring(r) or "?" end
  local w = S.p1
  local gpc = who(function() return UEHelpers.GetGameplayStatics():GetPlayerCharacter(w, 0) end)
  local pcc = who(function() return S.pc1.Character end)
  return "персонаж игрока 0=" .. gpc .. ", ИК1.Character=" .. pcc .. " | " .. string.format("главный=%s, второй=%s, напарник=%s, не-напарник=%s, свой=%s, другой=%s | Low: главный=%s второй=%s свой=%s | Alone: главный=%s второй=%s свой=%s",
    who(function() return lib:GetPrimaryCharacter(w) end), who(function() return lib:GetSecondaryCharacter(w) end),
    who(function() return lib:GetPlayPalCharacter(w) end), who(function() return lib:GetNonPlayPalCharacter(w) end),
    who(function() return lib:GetLocalKosmosCharacter(w) end), who(function() return lib:GetOtherKosmosCharacter(w) end),
    q(function() return lib:IsActorPrimaryCharacter(w, S.p1) end), q(function() return lib:IsActorSecondaryCharacter(w, S.p1) end), q(function() return lib:IsActorLocalCharacter(w, S.p1) end),
    q(function() return lib:IsActorPrimaryCharacter(w, S.buddy) end), q(function() return lib:IsActorSecondaryCharacter(w, S.buddy) end), q(function() return lib:IsActorLocalCharacter(w, S.buddy) end))
end
-- снимок врагов рядом с героями
S.enemyInfo = function()
  local out = {}
  for _, en in ipairs(FindAllOf("KosmosAntagonistCharacter") or {}) do
    if valid(en) then pcall(function()
      local el = en:K2_GetActorLocation()
      local d1 = dist(el, S.p1:K2_GetActorLocation())
      local d2 = valid(S.buddy) and dist(el, S.buddy:K2_GetActorLocation()) or -1
      if math.min(d1, d2 >= 0 and d2 or 1e9) < 1500 then
        local ctrl = en.Controller
        local focus = nil; pcall(function() focus = ctrl:GetFocusActor() end)
        out[#out + 1] = string.format("%s до Low %.0f, до Alone %.0f, контроллер %s, смотрит на %s", cname(en), d1, d2, clsName(ctrl), valid(focus) and cname(focus) or "никого")
      end
    end) end
  end
  return #out > 0 and table.concat(out, "; ") or "рядом никого"
end
S.boostStart = function(hero, owner, spot)
  pcall(function() S.animPre = { [1] = S.animSnapOf(S.p1), [2] = S.animSnapOf(S.buddy) } end)
  if not S.animBase then S.animBase = S.animPre end
  S.hadBoost = true
  if not (valid(S.ai) and valid(hero) and valid(owner)) then log("подсадка: нет ИИ-контроллера"); return false end
  pcall(function() trail("камера 1 перед подсадкой: " .. S.cam1Info()) end)
  pcall(function() trail("герои перед подсадкой: " .. S.killDiag()) end)
  if hero == S.p1 then pcall(S.freezeCam1, true) end
  pcall(dedupeRegistry, "перед подсадкой")
  pcall(S.snapshotItemOwners, "перед подсадкой")
  pcall(S.invDiag, "перед подсадкой")
  try("ai tick on", function() S.ai:SetActorTickEnabled(true) end)
  if not safePossess(S.ai, hero, "подсадка: герой → ИИ") then
    try("ai tick off", function() S.ai:SetActorTickEnabled(false) end)
    return false
  end
  -- ИИ-контроллер запоминает «своего» героя; после смены героя обновляем
  -- (а после подсадки возвращаем как было — см. S.boostEnd)
  local prevChar = nil
  pcall(function() prevChar = S.ai.mCurrentCharacter end)
  pcall(function() S.ai.mCurrentCharacter = hero end)
  if hero == S.buddy then S.real = false
  else
    -- камера игрока 1 замирает на месте на время подсадки
    pcall(S.applyCam1Freeze)
  end
  S.boost = { hero = hero, owner = owner, spot = spot, startFrame = S.frames, startT = now(), prevChar = prevChar }
  pcall(S.boostPassThrough, true)
  local ok, action = try("PlaypalBoost", function() return S.playpalCall("PlaypalBoost", hero, spot) end)
  if ok and valid(action) then
    pcall(S.diagAction, "PlaypalBoost", action)
    -- v9.15.9 (новая версия игры, подсаживает герой игрока 1): команде явно
    -- указываем наш ИИ-контроллер, который сейчас ведёт этого героя
    if S.newApi and S.roleSwap and valid(S.ai) then
      pcall(function()
        local cur = action.AIController
        if not valid(cur) then action.AIController = S.ai; trail("подсадка: команде указан ИИ-контроллер") end
      end)
    end
    try("PlaypalBoost Activate", function() action:Activate() end)
    log("подсадка: %s подсаживает (%s)", heroName(hero), spot:GetFName():ToString())
    return true
  end
  S.boostEnd("команда не создалась")
  return false
end
S.RB = "Gamepad_RightTrigger"   -- та же кнопка, что «схватить / поднять предмет»
-- нажатия RB обоих игроков (фронт нажатия)
-- v9.15.4: ПОДСАДКА С КЛАВИАТУРЫ. Раньше подсадку начинал только курок RT
-- геймпада. Теперь — та же кнопка, что «схватить» у этого игрока:
--  * игрок 2 на клавиатуре — его клавиша «схватить» из настроек (keyboard.grab);
--  * игрок 1 на клавиатуре — клавиши действия «схватить» из настроек ввода
--    самой игры (ищем по имени действия; можно задать boost_key_p1 вручную).
S.p1GrabKeys = function()
  if S.p1GrabKeyList then return S.p1GrabKeyList end
  local list, names = {}, {}
  if type(CFG.boost_key_p1) == "string" and CFG.boost_key_p1 ~= "" then
    list[1] = CFG.boost_key_p1
  else
    pcall(function()
      local ins = StaticFindObject("/Script/Engine.Default__InputSettings")
      ins.ActionMappings:ForEach(function(_, el)
        pcall(function()
          local m = el:get()
          local an = m.ActionName:ToString()
          local kn = m.Key.KeyName:ToString()
          if an:lower():find("grab") then
            names[#names + 1] = an .. "=" .. kn
            if not kn:find("^Gamepad") then list[#list + 1] = kn end
          end
        end)
      end)
    end)
  end
  S.p1GrabKeyList = list
  trail(string.format("подсадка: клавиши игрока 1 для подсадки: %s (действия игры: %s)", #list > 0 and table.concat(list, ", ") or "не нашёл", #names > 0 and table.concat(names, ", ") or "нет"))
  return list
end
-- держит ли игрок кнопку «схватить» (для подсадки); pc — его контроллер
S.grabDown = function(isP1)
  if isP1 then
    local pc = S.pc1
    if isDown(pc, S.RB) or analog(pc, "Gamepad_RightTriggerAxis") > 0.35 then return true end
    -- клавиатура у игрока 1, только если она не отдана игроку 2
    if CFG.device ~= "keyboard" then
      for _, k in ipairs(S.p1GrabKeys()) do if isDown(pc, k) then return true end end
    end
    return false
  end
  if CFG.device == "keyboard" then return isDown(S.pc1, CFG.keyboard and CFG.keyboard.grab or "RightShift") end
  local pc = p2Source()
  return isDown(pc, S.RB) or analog(pc, "Gamepad_RightTriggerAxis") > 0.35
end
S.rbEdges = function()
  -- Курок читаем как «ось»: когда герой переходит к ИИ и обратно, игра
  -- сбрасывает «нажатые кнопки», и удержание курка как кнопки теряется.
  local r1, r2 = S.grabDown(true), S.grabDown(false)
  local e1, e2 = r1 and not S.prevRB1, r2 and not S.prevRB2
  S.prevRB1, S.prevRB2 = r1, r2
  -- с какого момента курок держат (для начала подсадки) — в секундах
  if r1 then S.rbAt1 = S.rbAt1 or now() else S.rbAt1, S.rbFired1 = nil, nil end
  if r2 then S.rbAt2 = S.rbAt2 or now() else S.rbAt2, S.rbFired2 = nil, nil end
  return e1, e2
end
S.boostTick = function(e1, e2)
  local b = S.boost
  if not b.poseAt then
    pcall(function()
      local m = b.hero:GetCurrentMontage()
      if valid(m) and m:GetFName():ToString():find("GiveBoost") then
        b.poseAt = S.frames
        b.poseT = now()
        local hl, sl = b.hero:K2_GetActorLocation(), b.spot:K2_GetActorLocation()
        trail(string.format("подсадка: %s встал в позу через %.1f с (до места %.0f см)", heroName(b.hero), now() - (b.startT or now()), dist(hl, sl)))
      end
    end)
    if not b.poseAt and (S.frames - b.startFrame) % 60 == 59 then
      pcall(function()
        local hl, sl = b.hero:K2_GetActorLocation(), b.spot:K2_GetActorLocation()
        local v = b.hero:GetVelocity()
        trail(string.format("подсадка: %s ещё идёт к месту — %.0f см, скорость %.0f, ИИ занят=%s", heroName(b.hero), dist(hl, sl), math.sqrt(v.X * v.X + v.Y * v.Y), tostring(S.ai:IsAiCommand())))
      end)
    end
  end
  local okc, busy = pcall(function() return S.ai:IsAiCommand() end)
  local age = S.frames - b.startFrame
  if age > 60 and okc and not busy then S.boostEnd("готово") return end
  -- подсадка идёт, пока подсаживающий держит кнопку (как «схватить» везде).
  -- Когда героя забирает ИИ, игра «забывает» зажатый курок, и до следующего
  -- движения курка его не видно. Поэтому отпусканием считаем либо явное
  -- отпускание (курок был виден и пропал), либо момент, когда курок почти
  -- отпущен (маленькое значение оси — палец уже отпускает).
  local isP1 = (b.owner == S.pc1)
  local pc = isP1 and S.pc1 or p2Source()
  local v = analog(pc, "Gamepad_RightTriggerAxis")
  local bd = S.grabDown(isP1) and v <= 0.001 or isDown(pc, S.RB)
  local held = true
  -- сразу после передачи героя ИИ игра «забывает» зажатый курок и шлёт 0;
  -- это не отпускание. Удержание засчитываем только после этого момента.
  -- v9.15.9 (только для новой версии игры): удержание засчитываем только
  -- после того, как подсаживающий встал в позу. В новой версии игры курок героя под ИИ то виден, то нет, и
  -- «увиденный, а потом пропавший» курок отменял подсадку ещё до позы.
  if bd or v > 0.35 then if age > 5 and (not S.newApi or (b.poseAt and S.frames - b.poseAt > 3)) then b.sawHeld = true end; b.lowFrames = 0
  elseif v > 0.001 and v < 0.25 then b.lowFrames = (b.lowFrames or 0) + 1; if b.lowFrames >= 2 then held = false end
  elseif b.sawHeld then held = false end
  -- отпускание засчитываем, только если кнопку не видно 15 кадров подряд
  if held then b.offFrames = 0 else b.offFrames = (b.offFrames or 0) + 1 end
  if b.offFrames == 1 then
    local pc = (b.owner == S.pc1) and S.pc1 or p2Source()
    trail(string.format("подсадка: курок не виден (кнопка=%s, ось=%.2f)", tostring(isDown(pc, S.RB)), analog(pc, "Gamepad_RightTriggerAxis")))
  end
  if b.offFrames >= 8 and age > 20 then
    -- если второй уже запрыгивает — даём закончить, иначе отменяем
    local other = (b.hero == S.p1) and S.buddy or S.p1
    local okm, m = pcall(function() return other:GetCurrentMontage() end)
    local receiving = okm and valid(m) and m:GetFName():ToString():find("ReceiveBoost")
    if not receiving then S.boostEnd("отпустил кнопку") return end
  end
  -- не встал в позу за 5 с — отменяем (а не ждём 25 с)
  if S.newApi and not b.poseAt and b.startT and now() - b.startT > 5 then S.boostEnd("не встал в позу") return end
  -- в позе, но курок после позы ни разу не виден (новая версия игры): ждём,
  -- пока второй запрыгнет, но не дольше 8 с
  if S.newApi and b.poseT and not b.sawHeld and now() - b.poseT > 8 then
    local other = (b.hero == S.p1) and S.buddy or S.p1
    local okm, m = pcall(function() return other:GetCurrentMontage() end)
    local receiving = okm and valid(m) and m:GetFName():ToString():find("ReceiveBoost")
    if not receiving then S.boostEnd("никто не запрыгнул") return end
  end
  if age > 60 * 25 then S.boostEnd("слишком долго") return end
  if age % 60 == 30 then pcall(function() trail(string.format("враги при подсадке (%.0f с, Low у %s): %s", age / 60, clsName(S.p1.Controller), S.enemyInfo())) end) end
  if age % 60 == 31 then pcall(function() trail(string.format("герои при подсадке (%.0f с): %s", age / 60, S.killDiag())); trail("роли при подсадке: " .. S.roleDiag()) end) end

end
-- вызывается каждый кадр в режиме двух игроков
-- кто-то из героев сейчас умирает (его схватили, идёт сцена смерти)
S.anyDying = function()
  for _, h in ipairs({ S.p1, S.buddy }) do
    if valid(h) then
      local dc = S.deathComp(h)
      if valid(dc) then
        local st, k = 0, false
        pcall(function() st = dc.CurrentDeathStage; k = dc.bIsCurrentlyBeingKilled end)
        if k == true or (type(st) == "number" and st ~= 0) then return true end
      end
    end
  end
  return false
end
S.boostInput = function()
  local e1, e2 = S.rbEdges()
  if S.nativeWatch then pcall(S.nativeWatchTick) end
  -- во время сцены смерти подсадку не начинаем, а идущую — заканчиваем:
  -- иначе герой остаётся у ИИ, когда игра возрождает героев, и игра падает
  if S.frames % 6 == 0 then S.dyingNow = S.anyDying() end
  if S.dyingNow then
    S.deathSeenAt = S.frames
    if S.boost then S.boostEnd("сцена смерти") end
    S.boostCooldown = S.frames + 60
    return
  end
  if S.wantGATrace and not S.gaTraced then
    S.wantGATrace = nil
    pcall(function() local g = S.p1EquipAbility(); if g then S.traceEquipAbility(g) end end)
  end
  if S.boost then S.boostTick(e1, e2) return end
  if S.pendingBoost then pcall(S.boostPendingTick); return end
  if S.boostCooldown and S.frames < S.boostCooldown then return end
  -- подсадку начинаем, когда курок держат ~0,4 с, а не от любого нажатия:
  -- короткие нажатия у места подсадки (схватить что-то, в погоне) раньше
  -- то начинали, то сразу отменяли подсадку, и каждый раз героя забирали у
  -- игрока и возвращали — в погоне это роняло игру
  local HOLD = CFG.boost_hold_seconds or 0.4
  local t = now()
  if S.rbAt1 and not S.rbFired1 and t - S.rbAt1 >= HOLD then S.rbFired1 = true; S.tryBoost(S.p1, S.pc1, "Low")
  elseif S.rbAt2 and not S.rbFired2 and t - S.rbAt2 >= HOLD then S.rbFired2 = true; S.tryBoost(S.buddy, S.pc2, "Alone") end
end
-- Начать подсадку героем hero. Если у него в руках вещь (фонарик, ключ),
-- сначала убираем её: при передаче героя ИИ игра обрывает способность
-- «вещь в руках» и «роняет» вещь — потом при попытке её достать или
-- использовать игра падает. Убираем «нажатием» кнопки за игрока: вызываем
-- событие способности GA_EquipTool, которое получает она сама при нажатии.
S.tryBoost = function(hero, owner, who)
  local spot = S.nearestBoostTo(hero)
  if not spot then return end
  -- v9.15.9: в новой версии игры подсаживает только «напарник-бот». Если
  -- герою игрока 1 эту роль на время дать нельзя — подсаживает герой
  -- игрока 2, а Low запрыгивает (подсадка работает, просто даёт её Alone).
  -- Подсаживает только тот, кто может: героя игрока 2 не забираем, а
  -- нажатие игрока 1 оставляем самой игре (и записываем, что она делает).
  if hero == S.p1 and valid(S.buddy) and not S.canTakeRole(hero) then
    if not S.roleFallbackSaid then S.roleFallbackSaid = true; trail("подсадка: Low не может быть напарником в этой версии игры — подсаживать может только второй игрок") end
    toast("Подсадить может только второй игрок")
    pcall(S.diagRoles)
    pcall(S.diagSpot, spot)
    S.nativeWatch = { untilT = now() + 4, spot = spot }
    return
  end
  if S.newApi then pcall(S.diagRoles) end
  local stash = CFG.boost_stash ~= false
  local ga = stash and S.p1EquipAbility(hero) or nil
  local item = stash and S.p1HeldItem(hero) or nil
  if ga then
    S.traceEquipAbility(ga)
    local ok, e = S.gaPress(ga)
    trail("подсадка: у " .. who .. " в руках вещь — нажимаю за игрока «убрать» (" .. (ok and "ок" or tostring(e)) .. ")")
    S.pendingBoost = { hero = hero, owner = owner, spot = spot, at = S.frames, ga = ga }
  elseif stash and (item or #S.p1UnhiddenItems(hero) > 0) then
    local gl = {}
    pcall(function()
      for _, g in ipairs(FindAllOf("GA_EquipTool_C") or {}) do
        pcall(function() gl[#gl + 1] = cname(g.CurrentPlayer) .. "/" .. tostring(g.bIsActive) .. "/" .. cname(g.CurrentTool) end)
      end
    end)
    trail("подсадка: вещь " .. who .. " ещё убирается — жду, пока спрячется (в руках=" .. cname(item) .. ", способности: " .. table.concat(gl, ", ") .. ")")
    S.pendingBoost = { hero = hero, owner = owner, spot = spot, at = S.frames }
  else
    S.boostStart(hero, owner, spot)
  end
end

-- ОБЩИЙ ЭКРАН: камера игры следит за героем игрока 1. Сдвигаем её так,
-- чтобы в центре кадра была середина между героями (сдвиг только вбок и
-- вверх-вниз относительно камеры, без приближения), плавно.
-- Сдвиги камеры игра учитывает только в режиме «подмены камеры»
-- (SetOverrideCamera). Включаем его на общем экране, пока есть сдвиг, и
-- следим, чтобы камера не «улетела»: если первый герой уходит с экрана или
-- камера уезжает далеко — режим выключаем навсегда (до перезапуска игры).
-- ОБЩИЙ ЭКРАН. Камера игры следит за героем первого игрока. Своих «сдвигов»
-- камеры (AddOverriddenCameraLocation) игра не применяет. Но у камеры игры
-- есть собственный механизм «точек интереса» (PointOfInterestComponent):
-- камера учитывает их вместе с героем. Вешаем такую точку на героя второго
-- игрока — и камера сама учитывает обоих, своими же правилами и плавностью.
S.POI_CLASS = "/Script/CameraSystemRuntime.PointOfInterestComponent"
S.ensurePOI = function()
  if valid(S.poi) and S.poiOwner == S.buddy then return S.poi end
  S.poi, S.poiOwner = nil, nil
  local cls = StaticFindObject(S.POI_CLASS)
  if not valid(cls) then
    if not S.poiErrLogged then S.poiErrLogged = true; trail("общий экран: класс точки интереса не найден") end
    return nil
  end
  local ok, c = pcall(function()
    return S.buddy:AddComponentByClass(cls, false, { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }, false)
  end)
  if not ok or not valid(c) then
    if not S.poiErrLogged then S.poiErrLogged = true; trail("общий экран: не удалось добавить точку интереса — " .. tostring(c)) end
    return nil
  end
  S.poi, S.poiOwner, S.poiDz, S.poiAbs = c, S.buddy, nil, nil
  pcall(function()
    trail(string.format("общий экран: точка интереса на втором игроке (по умолчанию: вес %.2f, радиусы %.0f/%.0f, скорость %.2f, зум %.2f, менеджер камеры %s)",
      c.mWeight, c.mInnerRadius, c.mOuterRadius, c.mLerpSpeedWeight, c.mCameraZoom, clsName(c.mCameraManager)))
  end)
  pcall(function()
    c.mInnerRadius = CFG.shared_poi_inner or 1500
    c.mOuterRadius = CFG.shared_poi_outer or 2500
    c.mCameraZoom, c.mCameraZoomInner, c.mCameraZoomOuter = 0, 0, 0
  end)
  pcall(function() if not valid(c.mCameraManager) then c.mCameraManager = S.pc1.PlayerCameraManager end end)
  return c
end
-- v9.15.5: КАК ИГРА НАКЛАДЫВАЕТ ВТОРОЙ МИР. Кукла светит сферой, внутри
-- которой виден второй мир. Его снимает съёмка «двух миров» (мост светильника)
-- — это копия камеры игры, сдвинутая на 200 м во второй мир, с тем же
-- обзором; картинка одна на всех (2WorldsRenderTarget) и вклеивается в кадр
-- внутри сферы. Камера игры у нас — камера игрока 1, поэтому сфера на
-- половине второго показывала второй мир «с точки зрения» первого. Когда
-- кукла у Alone и экран разделён, ставим эту съёмку туда же, где камера
-- игрока 2 (с тем же сдвигом), — и сфера на его половине показывает то, что
-- надо. Иначе съёмку не трогаем — её ведёт игра.
S.twc = { list = {}, at = -10000 }
-- поставить съёмку туда, куда смотрит камера игрока 2 (во втором мире)
-- v9.15.7: на разделённом экране съёмкой второго мира управляет мод:
-- она повторяет камеру ПЕРВОЙ половины (в неё движок вклеивает пятно) —
-- место, поворот и обзор по ширине этой половины (половина уже целого
-- экрана, и картинка второго мира должна совпасть с ней, а не с целым).
S.twcSource = function()
  if S.p2First and S.playersSwapped and valid(S.cam2) then
    local f = 60
    pcall(function() f = S.cam2.CameraComponent.FieldOfView end)
    return S.cam2:K2_GetActorLocation(), S.cam2:K2_GetActorRotation(), f, "камера 2"
  end
  local cm = S.pc1.PlayerCameraManager
  return cm:GetCameraLocation(), cm:GetCameraRotation(), cm:GetFOVAngle(), "камера игры"
end
S.halfAspect = function()
  if not S.twc.vs or S.frames - (S.twc.vsAt or -1000) > 120 then
    pcall(function() S.twc.vs = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary"):GetViewportSize(S.pc1) end)
    S.twc.vsAt = S.frames
  end
  local vs = S.twc.vs
  if not (vs and vs.X and vs.Y and vs.X > 0 and vs.Y > 0) then return 16 / 9, true end
  local lr = S.layoutLR()
  if lr then return (vs.X / 2) / vs.Y, true end
  return vs.X / (vs.Y / 2), false
end
-- пропорции кадра камер игры (те, что держались до разделения)
S.frameAspect = function()
  if S.twc.R and S.frames - (S.twc.RAt or -10000) < 600 then return S.twc.R end
  local counts, best, bn = {}, nil, 0
  -- только числа, записанные при отключении пропорций у камер (S.applySplitAspect):
  -- сами камеры к этому времени могут быть уже удалены
  for k, n in pairs((S.aspectSaved and S.aspectSaved.ar) or {}) do
    counts[k] = n
    if n > bn then best, bn = tonumber(k), n end
  end
  if not best then pcall(function() local v = S.pc1.PlayerCameraManager.DefaultAspectRatio; if type(v) == "number" and v > 0.5 and v < 4 then best = v end end) end
  local R = best or 16 / 9
  if not S.twc.R or math.abs(S.twc.R - R) > 0.001 then
    local list = {}
    for k, n in pairs(counts) do list[#list + 1] = k .. "×" .. n end
    trail(string.format("два мира: пропорции кадра игры %.3f (камеры: %s)", R, #list > 0 and table.concat(list, ", ") or "нет"))
  end
  S.twc.R, S.twc.RAt = R, S.frames
  return R
end
S.twcApply = function()
  local c = S.twc.cap
  if not (S.twc.on and valid(c)) then return end
  local l, r, f = S.twcSource()
  local o = S.twc.off
  c:K2_SetWorldLocationAndRotation({ X = l.X + o.X, Y = l.Y + o.Y, Z = l.Z + o.Z }, r, false, {}, true)
  -- v9.15.7: КАК ДВИЖОК ВКЛЕИВАЕТ КАРТИНКУ. Три опыта (обычная съёмка —
  -- «лупа по ширине»; под всю половину по правилам движка — «экран в экране»
  -- примерно вдвое меньше; под прямоугольник 16:9 — «сплющено и чуть
  -- вытянуто») сходятся в одном: картинка ложится на ВСЮ половину, а сама
  -- половина сверху/снизу держит не 60° по высоте, а высоту кадра 16:9 при
  -- этом обзоре (тангенс × 9/16) и дорисовывает по ширине. Слева/справа —
  -- держит ширину. Съёмка должна видеть ровно это.
  local R = S.frameAspect()
  local a, lr = S.halfAspect()
  local t = math.tan(math.rad(f / 2))
  local rV, rH
  if lr then rH = t; rV = t / a else rV = t / R; rH = rV * a end
  pcall(function()
    local m = c.CustomProjectionMatrix
    m.XPlane.X, m.XPlane.Y, m.XPlane.Z, m.XPlane.W = 1 / rH, 0, 0, 0
    m.YPlane.X, m.YPlane.Y, m.YPlane.Z, m.YPlane.W = 0, 1 / rV, 0, 0
    m.ZPlane.X, m.ZPlane.Y, m.ZPlane.Z, m.ZPlane.W = 0, 0, 0, 1
    m.WPlane.X, m.WPlane.Y, m.WPlane.Z, m.WPlane.W = 0, 0, CFG.capture_near or 10, 0
    if not c.bUseCustomProjectionMatrix then c.bUseCustomProjectionMatrix = true end
  end)
  pcall(function() c.FOVAngle = 2 * math.deg(math.atan(rH)) end)
  local key = string.format("%.1f/%.1f", rH, rV)
  if S.twc.projKey ~= key then
    S.twc.projKey = key
    trail(string.format("два мира: кадр игры %.3f, половина %.2f (%s) — съёмка видит %.1f° по ширине и %.1f° по высоте",
      R, a, lr and "слева/справа" or "сверху/снизу", 2 * math.deg(math.atan(rH)), 2 * math.deg(math.atan(rV))))
  end
end
S.twcRelease = function()
  if not S.twc or not S.twc.on then return end
  S.twc.on = false
  pcall(function() if valid(S.twc.cap) then S.twc.cap.bUseCustomProjectionMatrix = false end end)
  pcall(function() if valid(S.twc.cap) then S.twc.cap:SetComponentTickEnabled(true) end end)
end
-- после тика моста светильника (блюпринт возвращает съёмку к камере игры)
-- ставим съёмку ещё раз — наша установка последняя
S.twcHookBridge = function(c)
  if S.twc.hooked then return end
  local br = nil
  pcall(function() br = c:GetOwner() end)
  if not valid(br) then return end
  S.twc.hooked = true
  pcall(function()
    br:GetClass():ForEachFunction(function(f)
      pcall(function()
        if f:GetFName():ToString() ~= "ReceiveTick" then return end
        RegisterHook((f:GetFullName():gsub("^Function ", "")), function() pcall(S.twcApply) end)
      end)
    end)
  end)
end
-- v9.15.7: АРЕОЛ ДЕРЖАЩЕГО КУКЛУ. Сферу второго мира мост светильника каждый
-- кадр передаёт съёмке (SetTwoWorldSphereInfo: номер, место, радиус), но
-- гасит её (радиус 0), когда кукла дальше ~19 м от героя игрока 1 — сама
-- кукла при этом включена и раскрыта. В одиночной игре напарник с куклой всегда
-- рядом; у нас второй — живой игрок. Поэтому, пока кукла у второго и его
-- половина экрана первая (в неё движок вклеивает пятно), после того как мост
-- передал сферы, возвращаем погашенной сфере куклы её радиус и место —
-- с тем же сдвигом от куклы, с каким их передавала сама игра.
S.halo = { sent = {}, on = false }
S.halo.dollActor = function()
  local d = S.halo.doll
  if valid(d) and S.frames - (S.halo.dollAt or -1000) < 300 then return d end
  d = nil
  local bl = S.buddy:K2_GetActorLocation()
  local bd = nil
  for _, a in ipairs(FindAllOf("KosmosCarriable") or {}) do
    pcall(function()
      if clsName(a):find(CFG.light_item or "Delusion", 1, true) then
        local al = a:K2_GetActorLocation()
        local dd = math.sqrt((al.X - bl.X) ^ 2 + (al.Y - bl.Y) ^ 2)
        if not bd or dd < bd then d, bd = a, dd end
      end
    end)
  end
  S.halo.doll, S.halo.dollAt = d, S.frames
  return d
end
S.halo.active = function()
  return S.twoWorlds() and S.split and S.p2First and S.playersSwapped and CFG.two_worlds_p2 ~= false
    and valid(S.buddy) and S.lightOwner() == S.buddy
end
S.halo.hook = function()
  if S.halo.hooked then return end
  S.halo.hooked = true
  local ok, e = pcall(function()
    -- внутри перехвата только записываем числа — никаких вызовов игры
    -- (поиск куклы, её место): движок в этот момент посреди передачи сфер.
    -- Разбираем записанное после моста, в S.halo.restore.
    RegisterHook("/Script/KosmosRendering.TwoWorldsCaptureComponent:SetTwoWorldSphereInfo", function() end, function(ctx, idx, loc, rad)
      if S.halo.self or not S.halo.on then return nil end
      pcall(function()
        local r = rad:get()
        if not (r and r > 0) then return end
        local l = loc:get()
        local sent = S.halo.sent
        sent[#sent + 1] = { i = idx:get(), x = l.X, y = l.Y, z = l.Z, r = r }
        if not S.halo.cap then S.halo.cap = ctx:get() end
      end)
      return nil
    end)
  end)
  trail("ареол: слежу за сферами съёмки (" .. (ok and "ок" or tostring(e)) .. ")")
  -- после того как мост передал все сферы — возвращаем погашенную сферу куклы
  pcall(function()
    local br = FindFirstOf("BP_IlluminatorBridge_C")
    if not valid(br) then return end
    br:GetClass():ForEachFunction(function(f)
      pcall(function()
        if f:GetFName():ToString() ~= "SetAllTwoWorldSpheres" then return end
        local full = f:GetFullName():gsub("^Function ", "")
        RegisterHook(full, function() pcall(S.halo.restore) end)
        trail("ареол: подправляю сферы после моста")
      end)
    end)
  end)
end
S.halo.restore = function()
  local sent = S.halo.sent
  S.halo.sent = {}
  local dl = S.halo.dollL
  if not (S.halo.on and dl) then return end
  -- сфера куклы, которую передала сама игра: запоминаем номер, сдвиг от куклы и радиус
  for _, h in ipairs(sent) do
    local off = { x = h.x - dl.X, y = h.y - dl.Y, z = h.z - dl.Z }
    if math.sqrt(off.x * off.x + off.y * off.y) < 300 then
      S.halo.good = { i = h.i, off = off, r = h.r }
      return                                             -- игра сама передала сферу
    end
  end
  local g, cap = S.halo.good, S.halo.cap
  if not (g and valid(cap)) then return end
  S.halo.self = true
  local ok = pcall(function() cap:SetTwoWorldSphereInfo(g.i, { X = dl.X + g.off.x, Y = dl.Y + g.off.y, Z = dl.Z + g.off.z }, g.r) end)
  S.halo.self = false
  if not S.halo.fixLogged then
    S.halo.fixLogged = true
    trail(string.format("ареол: мост погасил сферу куклы (второй далеко от первого) — вернул её (%s)", ok and "ок" or "ошибка"))
  end
end
-- раз в кадр, вне перехватов: включено ли возвращение сферы и где кукла
S.halo.tick = function()
  S.halo.on, S.halo.dollL = false, nil
  if S.halo.cap and not valid(S.halo.cap) then S.halo.cap = nil end
  if not (S.split and S.lightOwner() == S.buddy) then return end
  S.halo.hook()
  if not S.halo.active() then return end
  local d = S.halo.dollActor()
  if not valid(d) then return end
  local l = d:K2_GetActorLocation()
  S.halo.dollL = { X = l.X, Y = l.Y, Z = l.Z }
  S.halo.on = true
end
-- v9.15.7: ОРЕОЛ В РАЗДЕЛЁННОМ ЭКРАНЕ. Свой ореол (второй мир в сфере света
-- куклы) игра верно рисует только в половине, что лежит в начале кадра
-- (слева/сверху), — в другой половине выходил кусок чужой картинки.
-- Библиотека native/ln3couch_tw.dll (исходник и сборка — в native/) делает
-- две вещи по метке основной съёмки второго мира (SphereMarginConstant):
-- вклеивает второй мир только в первую половину и, если нужно, меняет местами
-- места вывода половин на экране. Нет библиотеки или two_worlds_native = false
-- — всё как раньше.
S.tw2 = {}
pcall(function()
  if CFG.two_worlds_native == false or not package or not package.loadlib then return end
  local path = "ue4ss/Mods/LN3Couch/native/ln3couch_tw.dll"
  local f = io.open(path, "rb"); if not f then return end
  f:close()
  local ok, err = package.loadlib(path, "*")
  S.tw2.native = ok and true or false
  log("второй мир: библиотека %s", ok and "загружена" or ("не загружена: " .. tostring(err)))
end)
-- РИСУЕМ СЛЕВА, ПОКАЗЫВАЕМ ПО МЕСТУ:
-- держащий куклу рисуется первым — в начале буфера кадра (слева/сверху), где
-- игра свой ореол рисует верно. Если по положению героев его половине место
-- справа/снизу, библиотека меняет местами только места вывода готовых
-- половин. Метка для библиотеки у основной съёмки: 0.5625 — поменять
-- слева/справа, 0.625 — сверху/снизу, 0.25 — не менять.
S.out = { on = false }
S.out.wanted = function()
  return S.tw2.native and S.twoWorlds() and S.split
end
S.out.tick = function(c)
  local O = S.out
  if not O.on then
    O.on = true
    O.cn = c.SphereMarginConstant
    trail("вывод половин: держащий куклу рисуется первым, на экран — по месту героев")
  end
  local swap = S.p2Geo ~= nil and (S.p2First or false) ~= (S.p2Geo or false)
  local mk = swap and (S.splitLR and 0.5625 or 0.625) or 0.25
  if O.mk ~= mk then
    O.mk = mk
    trail(string.format("вывод половин: %s (первым рисуется %s, по месту первым — %s)", swap and "меняю местами" or "как нарисованы",
      S.p2First and "второй" or "первый", S.p2Geo and "второй" or "первый"))
  end
  pcall(function() c.SphereMarginConstant = mk end)
end
S.out.stop = function()
  local O = S.out
  if not O.on then return end
  O.on, O.mk = false, nil
  pcall(function() if valid(S.twc.cap) then S.twc.cap.SphereMarginConstant = O.cn or 0 end end)
  trail("вывод половин: выключено")
end
S.twcTick = function()
  -- v9.15.7: только в двух мирах (кукла рядом) и на разделённом экране;
  -- в settings.lua two_worlds_p2 = false выключает
  if not (S.twoWorlds() and S.split and CFG.two_worlds_p2 ~= false) then pcall(S.out.stop) end
  if not S.twoWorlds() or CFG.two_worlds_p2 == false then
    S.halo.on, S.halo.dollL = false, nil
    if S.twc.on then
      S.twc.on = false
      pcall(function() if valid(S.twc.cap) then S.twc.cap.bUseCustomProjectionMatrix = false end end)
      pcall(function() if valid(S.twc.cap) then S.twc.cap:SetComponentTickEnabled(true) end end)
      trail("два мира: съёмка снова у камеры игры")
    end
    return
  end
  if S.frames - S.twc.at > 300 then S.twc.list = FindAllOf("TwoWorldsCaptureComponent") or {}; S.twc.at = S.frames end
  pcall(S.halo.tick)
  local cm = S.pc1.PlayerCameraManager
  local cl, fov1 = cm:GetCameraLocation(), cm:GetFOVAngle()
  -- съёмка второго мира должна стоять у камеры той половины, что первая
  -- (в неё движок вклеивает пятно): первая — второго игрока → у камеры 2
  local want = S.split
  if not want then
    if S.twc.on then
      S.twc.on = false
      pcall(function() if valid(S.twc.cap) then S.twc.cap.bUseCustomProjectionMatrix = false end end)
      pcall(function() if valid(S.twc.cap) then S.twc.cap:SetComponentTickEnabled(true) end end)
      trail("два мира: съёмка снова у камеры игры")
    end
    return
  end
  -- активная съёмка: та, что повторяет камеру игры (тот же обзор), и её сдвиг
  if not S.twc.on then
    local best, bd
    for _, c in ipairs(S.twc.list) do
      pcall(function()
        if not valid(c) then return end
        local l = c:K2_GetComponentLocation()
        local d = math.abs((c.FOVAngle or 0) - fov1) * 100 + math.abs(math.sqrt((l.X - cl.X) ^ 2 + (l.Y - cl.Y) ^ 2))
        if not bd or d < bd then best, bd = c, d end
      end)
    end
    if not valid(best) then return end
    local l = best:K2_GetComponentLocation()
    S.twc.offs = S.twc.offs or {}
    local key = best:GetFullName()
    if not S.twc.offs[key] then S.twc.offs[key] = { X = l.X - cl.X, Y = l.Y - cl.Y, Z = l.Z - cl.Z } end
    S.twc.cap, S.twc.off = best, S.twc.offs[key]
    S.twc.on = true
    -- игра каждый кадр возвращает съёмку к своей камере (её тик), поэтому на
    -- время берём съёмку себе: тик выключаем, место и обзор задаём сами
    pcall(function() best:SetComponentTickEnabled(false) end)
    S.twc.manual = false
    pcall(function() S.twc.manual = best.bCaptureEveryFrame == false end)
    S.twcHookBridge(best)
    trail(string.format("два мира: экран разделён — съёмку второго мира веду за камерой первой половины (сдвиг %.0f %.0f %.0f)", S.twc.off.X, S.twc.off.Y, S.twc.off.Z))
  end
  local c = S.twc.cap
  if not valid(c) then S.twc.on = false; return end
  if S.out.wanted() then S.out.tick(c) else S.out.stop() end
  S.twcApply()
  if S.twc.manual then pcall(function() c:CaptureScene() end) end
end
S.midCamTick = function()
  local okt, et = pcall(S.twcTick)
  if not okt and (not S.twcErrAt or S.frames - S.twcErrAt > 600) then S.twcErrAt = S.frames; trail("два мира: ошибка " .. tostring(et)) end
  if S.frames % 6 == 3 then S.dyingNow = S.anyDying() end
  if CFG.shared_center == false then return end
  local c = S.ensurePOI()
  if not c then return end
  -- на общем экране точка «тянет» камеру к середине; на разделённом — выключена
  local w = (not S.split and not S.cam1Frozen) and (CFG.shared_poi_weight or 0.5) or 0
  pcall(function() if math.abs((c.mWeight or 0) - w) > 0.001 then c.mWeight = w end end)
  -- v9.15.5: в наложенных копиях точку интереса ставим на Alone в той копии,
  -- где Low (камера игры считает кадр от героя игрока 1). Раньше в этом месте
  -- точка была выключена (тянула камеру на 100 м) — и общий экран следил
  -- только за первым игроком.
  -- v9.15.7: точка интереса — не на герое, а в мире, на месте Alone в копии
  -- КАМЕРЫ игры. Прикреплённая к Alone, она в момент его перехода между
  -- копиями уровня (вход в круг куклы) на кадр-другой прыгала на 200 м вместе
  -- с ним и утягивала камеру вверх — даже если мод ещё не понял, что копии
  -- наложены. Поэтому считаем по высоте камеры сразу: если Alone дальше 100 м
  -- по высоте от камеры — переносим точку на целое число шагов между копиями.
  pcall(function()
    if not S.poiAbs then
      S.poiAbs = true
      c:SetAbsolute(true, false, false)
    end
    local b = S.buddy:K2_GetActorLocation()
    local cz = S.pc1.PlayerCameraManager:GetCameraLocation().Z
    local gap = (S.copy and S.copy.gap) or CFG.copy_gap or 20000
    local dz = b.Z - cz
    local z = b.Z
    if math.abs(dz) > (CFG.layer_overlay_gap or 10000) then
      local k = math.floor(dz / gap + 0.5)
      z = b.Z - k * gap
    end
    c:K2_SetWorldLocation({ X = b.X, Y = b.Y, Z = z }, false, {}, false)
    local moved = math.abs(z - b.Z) > 1
    if moved ~= (S.poiShifted or false) then
      S.poiShifted = moved
      trail(moved and string.format("общий экран: Alone в другой копии — точка интереса в копии камеры игры (сдвиг %.0f см)", z - b.Z) or "общий экран: точка интереса снова на месте Alone")
    end
  end)
  if not S.split and S.frames % 240 == 120 then
    pcall(function()
      local function sp(h)
        local out = {}; S.pc1:ProjectWorldLocationToScreen(h:K2_GetActorLocation(), out, true); return out.X or -1, out.Y or -1
      end
      local ax, ay = sp(S.p1); local bx, by = sp(S.buddy)
      local vsz = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary"):GetViewportSize(S.pc1)
      trail(string.format("общий экран: Low на экране (%.2f, %.2f), Alone (%.2f, %.2f), вес точки %.2f",
        ax / vsz.X, ay / vsz.Y, bx / vsz.X, by / vsz.Y, c.mWeight))
    end)
  end
end

-- v9.15.3: «ПОСЛЕ КАЖДОЙ СМЕРТИ КАМЕРА ВСЁ БЛИЖЕ». При смерти игра приближает
-- камеру игрока 1 (AddCameraZoom: +0,2 на канале 1), а после возрождения в
-- кооперативе это приближение не снимает — с каждой смертью камера ближе.
-- Отмечаем приближения камеры игрока 1, которые никто не снял; после
-- возрождения мод снимает их сам (S.afterRespawnCam).
S.zoomTrack = function(name, ctx, args)
  if S.zoomSelf then return end
  local cm = nil; pcall(function() cm = ctx:get() end)
  if cm ~= S.pc1.PlayerCameraManager then return end
  S.zoomOpen = S.zoomOpen or {}
  if name == "AddCameraZoom" or name == "AddCameraZoomAfterDelay" then
    local ch = 1; pcall(function() ch = args[4]:get() end)
    S.zoomOpen[#S.zoomOpen + 1] = { ch = ch, at = S.frames }
  elseif name == "ClearCameraZoom" then
    S.zoomOpen = {}
  end
end
for _, fnName in ipairs({ "AddCameraZoom", "AddCameraZoomAfterDelay", "ClearCameraZoom" }) do
  pcall(function()
    RegisterHook("/Script/CameraSystemRuntime.CameraManager:" .. fnName, function(ctx, ...)
      local args = { ... }
      pcall(S.zoomTrack, fnName, ctx, args)
    end)
  end)
end
-- ОСОБЫЕ ПЛАНЫ (колесо, рычаги, стропила и т.п.). Игра включает особый план
-- (StartExternalOverTime) у камеры игрока 1 — другой у неё нет. Когда план
-- включил герой игрока 2, камера первого уезжала к нему, и обе половины
-- показывали одно и то же.
-- v9.15.4: это было исправлено в v9.10.11, но в v9.11 при чистке удалили саму
-- функцию, а вызов (pcall) остался — и молча ничего не делал. Возвращаем.
-- Чей план — смотрим, кто из героев ближе к направлению взгляда камеры
-- плана. Если при разделённом экране это Alone — отменяем план у камеры
-- игрока 1 и показываем его во второй половине. На общем экране план
-- остаётся как есть: его видят оба. split_ext_to_p2 = false выключает.
S.extSubject = function(cam)
  local cl, cr = cam:K2_GetActorLocation(), cam:K2_GetActorRotation()
  pcall(function()
    local cc = cam.CameraComponent
    if not valid(cc) then cc = cam.mCameraComponent end
    if valid(cc) then cl, cr = cc:K2_GetComponentLocation(), cc:K2_GetComponentRotation() end
  end)
  local fy, fp = math.rad(cr.Yaw), math.rad(cr.Pitch)
  local fx, fyv, fz = math.cos(fp) * math.cos(fy), math.cos(fp) * math.sin(fy), math.sin(fp)
  local function ang(h)
    local p = h:K2_GetActorLocation()
    local dx, dy, dz = p.X - cl.X, p.Y - cl.Y, p.Z + 40 - cl.Z
    local l = math.sqrt(dx * dx + dy * dy + dz * dz); if l < 1 then return 0 end
    return math.deg(math.acos(clamp((dx * fx + dy * fyv + dz * fz) / l, -1, 1)))
  end
  local aL, aA = ang(S.p1), ang(S.buddy)
  return aA < aL, aL, aA
end
S.hookExternalCam = function()
  if S.extHookOk then return end
  local base = "/Script/CameraSystemRuntime.CameraManager:"
  local okA = pcall(function()
    RegisterHook(base .. "StartExternalOverTime", function(ctx, camP, timeP, easeP)
      if S.camSelf then return end
      local cm, cam, ease = nil, nil, 0
      pcall(function() cm = ctx:get() end)
      pcall(function() cam = camP:get() end)
      pcall(function() ease = easeP:get() end)
      if not (S.coop and S.split and CFG.split_ext_to_p2 ~= false and valid(cm) and valid(S.pc1) and cm == S.pc1.PlayerCameraManager and valid(cam)) then return end
      local ok, alone, aL, aA = pcall(S.extSubject, cam)
      local nm = ""; pcall(function() nm = cam:GetFName():ToString() end)
      if not (ok and alone) then
        trail(string.format("камера 1: особый план %s — для Low (Low %.0f°, Alone %.0f° от взгляда), оставил", nm, aL or -1, aA or -1))
        return
      end
      S.cam2External = cam; S.camSnap = true; RC.pickAt = 0
      trail(string.format("камера 1: особый план %s — для Alone (Low %.0f°, Alone %.0f° от взгляда): отдал второй половине, у игрока 1 отменил", nm, aL, aA))
      local function undo()
        S.camSelf = true
        pcall(function() cm:StopExternalOverTime(0.3, ease) end)
        S.camSelf = false
      end
      if ExecuteWithDelay then ExecuteWithDelay(30, function() ExecuteInGameThread(undo) end) else undo() end
    end)
  end)
  pcall(function()
    RegisterHook(base .. "StopExternalOverTime", function(ctx)
      if S.camSelf then return end
      local cm = nil; pcall(function() cm = ctx:get() end)
      if valid(S.pc1) and cm == S.pc1.PlayerCameraManager and S.cam2External then
        -- игра сама закончила план — второй возвращается к своей комнате
        S.cam2External = nil; RC.pickAt = 0; S.camSnap = true
        trail("камера 2: особый план закончился — снова своя комната")
      end
    end)
  end)
  S.extHookOk = okA
  log(okA and "камера: особые планы перехвачены" or "камера: не удалось перехватить особые планы")
end
-- КАМЕРА ИГРОКА 1 И СОБЫТИЯ УРОВНЯ ДЛЯ ГЕРОЯ ИГРОКА 2. Скрипты уровня
-- написаны для одного игрока: «герой игрока зашёл в триггер — меняем камеру
-- игрока» (SetViewOverTime/ResetViewOverTime у менеджера камеры номер 0 и
-- «вид» камеры комнаты — её дальний план). Какой герой «игрок», игра решает
-- так: напарник — тот, кем управляет ИИ. В кооперативе ИИ нет ни у кого, и
-- такие события срабатывают и на героя игрока 2 — а меняют камеру игрока 1
-- (так на уступе в переулке камера игрока 1 уходила на дальний план и больше
-- не ехала за Low). Правило: команды камере игрока 1, отданные в событии
-- уровня, которое вызвал герой игрока 2, к камере игрока 1 не применяются —
-- мод возвращает её как было. События мира (двери, обвалы) не трогаем.
-- Как узнаём: перехват команд менеджера камеры (перед выполнением) кладёт их
-- «в ожидание» с номером кадра, а перехват событий скриптов уровня (после
-- выполнения) смотрит, чей герой в параметрах события: игрока 2 — откатываем
-- команды этого кадра, иначе — оставляем.
S.evCam = { pend = {}, views = {}, cams = {}, camsAt = -100000, forced = nil, hooked = {}, cmdOk = false, pinned = {} }
do
local EC = S.evCam
EC.readView = function(c) local v = nil; pcall(function() v = c.mCurrentViewValue end); return v end
-- «вид» камер комнат на прошлом кадре — чтобы было к чему вернуть
EC.tick = function()
  if not (S.coop and valid(S.pc1)) then EC.pend = {}; EC.pinned = {}; return end
  if S.frames - EC.camsAt > 120 then
    EC.camsAt = S.frames
    EC.cams = {}
    for _, c in ipairs(FindAllOf("DollhouseCameraActor") or {}) do if valid(c) then EC.cams[#EC.cams + 1] = c end end
  end
  -- команды, которые не попали ни в одно событие героя игрока 2, — оставляем
  for i = #EC.pend, 1, -1 do
    local e = EC.pend[i]
    if e.frame < S.frames then EC.commit(e); table.remove(EC.pend, i) end
  end
  -- «вид», возвращённый после события игрока 2, держим, пока скрипт его докручивает
  for k, p in pairs(EC.pinned) do
    if S.frames > p.untilF or not valid(p.cam) then EC.pinned[k] = nil
    else pcall(function() if p.cam.mCurrentViewValue ~= p.value then p.cam.mCurrentViewValue = p.value end end) end
  end
  for i, c in ipairs(EC.cams) do
    if valid(c) then EC.views[c:GetFullName()] = EC.readView(c) end
  end
end
EC.commit = function(e)
  if e.kind == "set" then EC.forced = e.cam elseif e.kind == "reset" then EC.forced = nil end
end
-- откат команд этого кадра: вернуть «вид» камер и выбор камеры у менеджера
EC.undo = function(who)
  local cm = S.pc1.PlayerCameraManager
  local names = {}
  for _, e in ipairs(EC.pend) do
    if e.frame == S.frames then
      if valid(e.cam) then names[#names + 1] = e.cam:GetFName():ToString() end
      e.undone = true
    end
  end
  if #names == 0 then return end
  for _, c in ipairs(EC.cams) do
    pcall(function()
      if not valid(c) then return end
      local key = c:GetFullName()
      local old, now = EC.views[key], EC.readView(c)
      if old ~= nil and now ~= nil and now ~= old then
        c.mCurrentViewValue = old
        EC.pinned[key] = { cam = c, value = old, untilF = S.frames + 60 * (CFG.p2_event_cam_pin_s or 12) }
      end
    end)
  end
  S.camSelf = true
  if valid(EC.forced) then
    local f = EC.forced
    pcall(function() cm:SetViewOverTime(f, 0.3, 0) end)
  else
    pcall(function() cm:ResetViewOverTime(0.3, 0) end)
  end
  S.camSelf = false
  local keep = {}
  for _, e in ipairs(EC.pend) do if not e.undone then keep[#keep + 1] = e end end
  EC.pend = keep
  trail(string.format("камера 1: событие уровня от героя игрока 2 (%s) меняло камеру игрока 1 (%s) — вернул как было", who, table.concat(names, ", ")))
end
EC.hookCmds = function()
  if EC.cmdOk then return end
  EC.cmdOk = true
  local base = "/Script/CameraSystemRuntime.CameraManager:"
  for _, fn in ipairs({ "SetViewOverTime", "ResetViewOverTime" }) do
    pcall(function()
      RegisterHook(base .. fn, function(ctx, camP)
        if S.camSelf or not S.coop or CFG.p2_event_cam == false then return end
        pcall(function()
          local cm = ctx:get()
          if not (valid(S.pc1) and cm == S.pc1.PlayerCameraManager) then return end
          local cam = nil
          if fn == "SetViewOverTime" then pcall(function() cam = camP:get() end) end
          EC.pend[#EC.pend + 1] = { frame = S.frames, kind = (fn == "SetViewOverTime") and "set" or "reset", cam = cam }
        end)
      end)
    end)
  end
end
-- события скриптов уровня: кто их вызвал (герой в параметрах события)
EC.hookLevelEvents = function()
  for _, a in ipairs(FindAllOf("LevelScriptActor") or {}) do
    pcall(function()
      -- после перезагрузки уровня класс скрипта новый — ключ с адресом
      local c = a:GetClass()
      local key = c:GetFName():ToString() .. "@" .. tostring(c:GetAddress())
      if EC.hooked[key] then return end
      EC.hooked[key] = true
      c:ForEachFunction(function(f)
        pcall(function()
          local fname = f:GetFName():ToString()
          if not fname:find("^BndEvt") then return end
          local path = f:GetFullName():match("^%S+%s+(.+)$")
          RegisterHook(path, function(ctx, ...)
            if not S.coop or #EC.pend == 0 then return end
            local p2, p1 = false, false
            for _, prm in ipairs({ ... }) do
              pcall(function()
                local v = prm:get()
                if v == S.buddy then p2 = true elseif v == S.p1 then p1 = true end
              end)
            end
            if p2 and not p1 then pcall(EC.undo, heroName(S.buddy)) end
          end)
        end)
      end)
    end)
  end
end
end
-- ВРАГИ И ИГРОК 2. Игра даёт врагам ловить только героя игрока 1: напарника
-- (в одиночной игре это ИИ) они лишь преследуют. Поэтому, если враг вплотную
-- подбежал к герою игрока 2, мод сам говорит врагу «поймал» — дальше игра
-- проигрывает свою сцену поимки, как с игроком 1.
S.enemy = { list = {}, listAt = -10000, killAt = -10000, catchDist = nil, logged = {} }
pcall(function()
  RegisterHook("/Script/Kosmos.KosmosAntagonistCharacter:KillPlayer", function(ctx, player)
    pcall(function()
      local en, pl = ctx:get(), player:get()
      local d = dist(en:K2_GetActorLocation(), pl:K2_GetActorLocation())
      trail(string.format("враги: %s поймал %s на расстоянии %.0f см", cname(en), heroName(pl), d))
      -- запоминаем, с какого расстояния игра сама ловит игрока 1
      if pl == S.p1 and d > 20 and d < 400 then S.enemy.catchDist = math.max(S.enemy.catchDist or 0, d) end
    end)
  end)
end)
-- ТРАССИРОВКА: какие функции врага, его контроллера и героев вызывает игра.
-- Цель — увидеть, что происходит перед поимкой Low и чего не происходит с Alone.
S.trace = { classes = {}, calls = {}, at = 0, hooked = 0, argAt = {} }
S.traceClass = function(cls)
  if not valid(cls) then return end
  local cn = cls:GetFName():ToString()
  if S.trace.classes[cn] then return end
  S.trace.classes[cn] = true
  local c = cls
  local depth = 0
  while valid(c) and depth < 6 do
    local ccn = c:GetFName():ToString()
    if not ccn:find("_C$") then break end   -- только классы из игры (блюпринты)
    pcall(function()
      c:ForEachFunction(function(f)
        pcall(function()
          local fname = f:GetFName():ToString()
          if fname:find("Ubergraph") or fname:find("Tick") or fname:find("Update") then return end
          local full = f:GetFullName():gsub("^Function ", "")
          S.trace.done = S.trace.done or {}
          if S.trace.done[full] then return end
          S.trace.done[full] = true
          local label = ccn .. ":" .. fname
          local pnames = {}
          pcall(function() f:ForEachProperty(function(pr) pnames[#pnames + 1] = pr:GetFName():ToString() end) end)
          local watch = fname:find("Proximity") or fname:find("Grab") or fname:find("Attack") or fname:find("Behind")
            or fname:find("Hidden") or fname:find("Percieved") or fname:find("Kill") or fname:find("Player") or fname:find("Target")
          local fixer = (fname == "FindGrabAngleAndDistance" or fname == "Decide on Attack Anim")
          -- подставлять цель есть куда только если у врага это поле — ссылка на героя
          if fixer and not S.targetFieldOk(nil, cls) then fixer = false end
          local sensorFix = false
          local angleFix = false
          local zoneFix = ccn:find("ProximitySensor") and fname == "Run Attack Range"
          local idxParam = nil
          for i, n in ipairs(pnames) do if n == "PlayerIndex" or n == "Player Index" then idxParam = i end end
          -- v9.15.5: ВЫЛЕТЫ. Раньше перехватывали ВСЕ функции врага и его частей
          -- (у надсмотрщика второй главы — сотни): на каждый вызов загрузчик
          -- модов разбирает все параметры, и на некоторых игра падала (во всех
          -- четырёх отчётах о вылете — внутри такого перехвата). Ставим перехват
          -- только туда, где мод что-то делает; остальное — лишь для разбора.
          local needed = fixer or zoneFix or (idxParam and CFG.enemy_index_swap == true)
            or CFG.enemy_diag == true or CFG.enemy_trace_log == true
          if not needed then return end
          RegisterHook(full, function(ctx, ...)
            local hargs = { ... }
            -- покадровая лента: что у датчика перед каждой функцией (3 кадра раз в 2 с)
            if CFG.enemy_diag == true and S.tl and S.frames <= S.tl.untilF and #S.tl.lines < 400 then
              pcall(function()
                local sen = S.tl.sensor
                local ct = sen["Current Target"]
                local w = (ct == S.p1 and "Low") or (ct == S.buddy and "Alone") or (valid(ct) and cname(ct)) or "пусто"
                S.tl.lines[#S.tl.lines + 1] = string.format("к%d %s | цель=%s зона=%s расст0=%.0f dot0=%.3f dot1=%.3f", S.frames - S.tl.f0, (label:gsub("^BPC_PlayerProximitySensor_C:", "датчик:"):gsub("^BP_Supervisor_Crawl_C:", "враг:")), w, tostring(sen.InGrabRange_Internal),
                  sen["Player - Distnace"] or -1, sen["DOT_Target Position_Player_0"] or -9, sen["DOT_Target Position_Player_1"] or -9)
              end)
            end
            if fixer then pcall(S.fixTarget, ctx:get()) end
            if zoneFix then
              local ok, e = pcall(S.fixZone, ctx:get(), hargs)
              if not ok and not S.zoneErr then S.zoneErr = true; trail("враги: зона — ошибка: " .. tostring(e)) end
            end
            if angleFix then
              local ok, e = pcall(S.fixAngle, ctx:get(), fname)
              if not ok and not S.angleErr then S.angleErr = true; trail("враги: угол — ошибка: " .. tostring(e)) end
            end
            if sensorFix then
              local ok, e = pcall(S.fixSensor, ctx:get())
              if not ok and not S.sensorErr then S.sensorErr = true; trail("враги: датчик — ошибка: " .. tostring(e)) end
            end
            -- проверка «игрок N в зоне атаки / позади»: в одиночной игре враг
            -- смотрит только игрока 0 (Low). Если гонится за Alone — пусть смотрит игрока 1.
            if idxParam and CFG.enemy_index_swap == true then
              local okx, ex = pcall(function()
                local obj = ctx:get()
                local en = obj
                if not obj:IsA(StaticFindObject("/Script/Engine.Actor")) then en = obj:GetOwner() end
                if S.wantAlone(en) and S.real then
                  local a = hargs[idxParam]
                  if a:get() == 0 then
                    a:set(1)
                    S.idxLog = S.idxLog or {}
                    if not S.idxLog[label] or S.frames - S.idxLog[label] > 300 then
                      S.idxLog[label] = S.frames
                      trail("враги: " .. label .. " — проверяю игрока 1 (Alone) вместо 0")
                    end
                  end
                end
              end)
              if not okx and not S.idxErr then S.idxErr = true; trail("враги: замена номера игрока — ошибка: " .. tostring(ex)) end
            end
            if CFG.enemy_trace_log == true then local t = S.trace.calls[label]; S.trace.calls[label] = (t or 0) + 1 end
            if CFG.enemy_diag ~= true then return end
            if (not S.trace.argAt[label] or S.frames - S.trace.argAt[label] >= 60) and S.diagNear and S.frames - S.diagNear < 12 then
              S.trace.argAt[label] = S.frames
              local args, out = { ... }, {}
              for i, a in ipairs(args) do
                local v = "?"
                pcall(function()
                  local x = a:get()
                  if type(x) == "userdata" then
                    if x == S.p1 then v = "Low" elseif x == S.buddy then v = "Alone" elseif valid(x) then v = cname(x) else
                      local ok, n = pcall(function() return x:ToString() end); v = ok and n or "объект"
                    end
                  else v = tostring(x) end
                end)
                out[#out + 1] = (pnames[i] or ("п" .. i)) .. "=" .. v
              end
              trail("вызов " .. label .. "(" .. table.concat(out, ", ") .. ")")
            end
          end)
          S.trace.hooked = S.trace.hooked + 1
        end)
      end)
    end)
    local ok, sup = pcall(function() return c:GetSuperStruct() end)
    c = ok and sup or nil
    depth = depth + 1
  end
  trail(string.format("трассировка: подключил %s (всего функций %d)", cn, S.trace.hooked))
end
-- раз в 0,25 с выписываем, что вызывалось (только пока враг рядом с героями)
-- ПРИЧИНА найдена: враг каждый кадр выбирает «свою цель» (Current Target Local)
-- как героя игрока с номером 0 — так устроено для сетевой игры, где на каждом
-- компьютере игрок 0 — свой герой. На одном компьютере это всегда Low, и,
-- подползая к Alone, враг меряет угол и расстояние захвата до Low (за спиной,
-- за 14 м) — поэтому и не хватает. Перед этими замерами подставляем цель,
-- за которой враг на самом деле гонится (Alone), если она ближе.
-- v9.15.5: ВЫЛЕТ НА НАДСМОТРЩИКЕ ВТОРОЙ ГЛАВЫ. Все пять отчётов о падении —
-- внутри этого перехвата. У «стоячего» надсмотрщика своя функция захвата, и
-- «Current Target Local» у него, видимо, не ссылка на героя — обращение к ней
-- роняло игру (загрузчик модов читает такое поле как ссылку). Поэтому сначала
-- по описанию класса проверяем, что поле — ссылка на объект; иначе не трогаем.
S.ctlOk = {}
S.targetFieldOk = function(en, clsArg)
  local cls = clsArg or en:GetClass()
  local key = cls:GetFName():ToString()
  if S.ctlOk[key] ~= nil then return S.ctlOk[key] end
  local kind = nil
  local c, depth = cls, 0
  while valid(c) and depth < 8 and not kind do
    pcall(function()
      c:ForEachProperty(function(pr)
        if pr:GetFName():ToString() == "Current Target Local" then kind = pr:GetClass():GetFName():ToString() end
      end)
    end)
    local ok, sup = pcall(function() return c:GetSuperStruct() end)
    c = ok and sup or nil; depth = depth + 1
  end
  local okField = kind == "ObjectProperty"
  S.ctlOk[key] = okField
  trail(string.format("враги: у %s поле «Current Target Local» — %s, %s", key, kind or "нет", okField and "подставляю цель" or "не трогаю"))
  return okField
end
S.fixTarget = function(en)
  if not valid(en) or not S.targetFieldOk(en) then return end
  if not S.wantAlone(en) then return end
  local cur = nil; pcall(function() cur = en["Current Target Local"] end)
  if cur ~= S.buddy then
    en["Current Target Local"] = S.buddy
    S.fixLog = S.fixLog or -10000
    if S.frames - S.fixLog > 300 then
      S.fixLog = S.frames
      trail(string.format("враги: %s выбирал целью Low — поставил Alone (за ней и гонится)", cname(en)))
    end
  end
end
-- Датчик близости врага в одиночной игре выбирает целью только игрока 0
-- («Single Player Player in Attack Range», PlayerIndex=0). Для Alone его
-- «Current Target» пустой, «в зоне захвата» не включается, атаки нет. Перед
-- проверкой зоны атаки ставим датчику цель, за которой враг гонится.
-- v9.15.5: ОБЩЕЕ ПРАВИЛО ДЛЯ ВСЕХ ВРАГОВ. В одиночной игре каждый враг
-- проверяет «в зоне захвата ли игрок», беря героя через «игрок номер 0»
-- (GetPlayerPawn/GetPlayerCharacter с номером 0) — а это всегда герой
-- первого игрока. Поэтому любой враг ловил второго, только когда первый
-- подходил близко. Подгонять каждого врага отдельно не нужно: пока враг
-- гонится за вторым игроком, на его вопрос «кто игрок 0» отвечаем «герой
-- второго». Остальным (камера, интерфейс, другие враги) — как было.
S.p0For, S.p0Active, S.p0Logged = {}, -100000, {}
S.p0Enemy = function(o)
  if not valid(o) then return nil end
  if not S.antCls then S.antCls = StaticFindObject("/Script/Kosmos.KosmosAntagonistCharacter") end
  if o:IsA(S.antCls) then return o end
  local ow = nil
  pcall(function() ow = o:GetOwner() end)
  if valid(ow) and ow:IsA(S.antCls) then return ow end
  pcall(function() if o:IsA(StaticFindObject("/Script/Engine.Controller")) then ow = o.Pawn end end)
  if valid(ow) and ow:IsA(S.antCls) then return ow end
  return nil
end
S.installP0Hook = function()
  if S.p0Hooked or CFG.enemy_p0_swap == false then return end
  S.p0Hooked = true
  -- параметры загрузчик отдаёт как (ответ, кто спрашивает, номер);
  -- разбираем по типам: герой — ответ игры, иной объект — кто спрашивает
  local function post(ctx, ...)
    if S.frames - S.p0Active > 30 then return nil end
    local ret, caller = nil, nil
    for _, a in ipairs({ ... }) do
      pcall(function()
        local v = a:get()
        if type(v) ~= "userdata" or not valid(v) then return end
        if v == S.p1 or v == S.buddy then ret = v elseif not caller then caller = v end
      end)
    end
    if ret ~= S.p1 or not caller then return nil end
    local en = S.p0Enemy(caller)
    if not en then return nil end
    local t = nil
    pcall(function() t = S.p0For[en:GetAddress()] end)
    if not (t and S.frames - t < 30 and valid(S.buddy)) then return nil end
    if not S.p0Logged["ok" .. cname(en)] then
      S.p0Logged["ok" .. cname(en)] = true
      trail("враги: " .. cname(en) .. " спросил «игрока 0» — ответил «герой второго»")
    end
    return S.buddy
  end
  for _, fn in ipairs({ "GetPlayerPawn", "GetPlayerCharacter" }) do
    local ok, e = pcall(function() RegisterHook("/Script/Engine.GameplayStatics:" .. fn, function() end, post) end)
    trail(string.format("враги: «игрок 0» для врагов, гонящихся за вторым, — перехват %s (%s)", fn, ok and "ок" or tostring(e)))
  end
end
S.wantAlone = function(en)
  if CFG.enemies_catch_p2 == false or not S.coop or not valid(en) or not valid(S.buddy) or not valid(S.p1) then return false end
  local target = nil
  pcall(function() target = en.Controller.Blackboard:GetValueAsObject(FName("CharacterPercieved")) end)
  -- в погоне по сценарию враг «никого не видит» (цель пустая) и просто ползёт
  -- за игроком 0; тогда считаем целью того из героев, кто ближе
  if target ~= S.buddy and valid(target) then return false end
  local el = en:K2_GetActorLocation()
  return dist(el, S.buddy:K2_GetActorLocation()) < dist(el, S.p1:K2_GetActorLocation())
end
S.fixSensor = function(comp)
  -- Хуки срабатывают ПОСЛЕ функции. «DISTANCE CHECK MASTER» — последний замер
  -- перед «Run Attack Range», которая решает «в зоне захвата». В одиночной
  -- игре она смотрит только расстояние до игрока 0 («Player - Distnace») —
  -- поэтому враг хватал второго игрока, только когда первый подходил близко.
  -- Если враг гонится за Alone, отдаём проверке её расстояние и направление.
  local en = comp:GetOwner()
  if not S.wantAlone(en) then return end
  local d0, d1 = comp["Player - Distnace"], comp["Player 2 Distance"]
  if type(d0) ~= "number" or type(d1) ~= "number" or d1 >= d0 then return end
  comp["Player - Distnace"] = d1
  pcall(function() comp["DOT_Target Position_Player_0"] = comp["DOT_Target Position_Player_1"] end)
  pcall(function() comp["Current Target"] = S.buddy end)
  S.sensorLog = S.sensorLog or -10000
  if S.frames - S.sensorLog > 300 then
    S.sensorLog = S.frames
    trail(string.format("враги: проверка зоны захвата смотрела на первого игрока (%.0f см) — дал ей второго (%.0f см)", d0, d1))
  end
end
-- Фильтр угла датчика в одиночной игре считает направление на игрока 0
-- (первого). Если враг гонится за вторым — подставляем направление на него.
S.fixAngle = function(comp, fname)
  local en = comp:GetOwner()
  if not S.wantAlone(en) then return end
  local el, bl = en:K2_GetActorLocation(), S.buddy:K2_GetActorLocation()
  local fw = en:GetActorForwardVector()
  local dx, dy = bl.X - el.X, bl.Y - el.Y
  local len = math.max(math.sqrt(dx * dx + dy * dy), 1)
  local dot = (fw.X * dx + fw.Y * dy) / (len * math.max(math.sqrt(fw.X * fw.X + fw.Y * fw.Y), 0.001))
  local old = comp["DOT_Target Position_Player_0"]
  comp["DOT_Target Position_Player_0"] = dot
  pcall(function() comp["Player - Distnace"] = math.min(comp["Player - Distnace"], comp["Player 2 Distance"]) end)
  S.angleLog = S.angleLog or -10000
  if S.frames - S.angleLog > 300 then
    S.angleLog = S.frames
    trail(string.format("враги: после «%s» направление на первого игрока %.2f — дал на второго %.2f", fname, old or -9, dot))
  end
end
-- ГЛАВНОЕ. «Run Attack Range» решает, в зоне ли захвата цель. В одиночной
-- игре она проверяет только игрока 0 (первого): так задумано, чтобы враг не
-- ловил отставшего ИИ-напарника, пока игрок далеко. Но второй герой у нас —
-- живой игрок. Поэтому для него делаем ту же проверку, что игра делает для
-- первого: дистанция атаки и угол обзора врага (параметры берём у самой игры).
S.fixZone = function(comp, hargs)
  if comp.InGrabRange_Internal then return end
  local en = comp:GetOwner()
  if not S.wantAlone(en) then return end
  local range, angle = 420, 60
  pcall(function() range = hargs[1]:get() end)
  pcall(function() angle = hargs[2]:get() end)
  local el, bl = en:K2_GetActorLocation(), S.buddy:K2_GetActorLocation()
  local dx, dy, dz = bl.X - el.X, bl.Y - el.Y, bl.Z - el.Z
  local d = math.sqrt(dx * dx + dy * dy)
  if d > range or math.abs(dz) > 250 then return end
  local fw = en:GetActorForwardVector()
  local fl = math.max(math.sqrt(fw.X * fw.X + fw.Y * fw.Y), 0.001)
  local dot = (fw.X * dx + fw.Y * dy) / (math.max(d, 1) * fl)
  if dot < math.cos(math.rad(angle / 2)) then return end
  comp.InGrabRange_Internal = true
  S.zoneLog = S.zoneLog or -10000
  if S.frames - S.zoneLog > 300 then
    S.zoneLog = S.frames
    trail(string.format("враги: второй игрок в зоне захвата (%.0f см, угол %.0f°) — как для первого", d, math.deg(math.acos(math.min(1, dot)))))
  end
end
S.traceFlush = function(active)
  if S.frames - S.trace.at < 15 then return end
  S.trace.at = S.frames
  local list = {}
  for k, n in pairs(S.trace.calls) do list[#list + 1] = k .. (n > 1 and ("×" .. n) or "") end
  S.trace.calls = {}
  if active and #list > 0 then table.sort(list); trail("вызовы: " .. table.concat(list, ", ")) end
end
-- переменные врага (из блюпринта): цель, ближайший игрок, флаги
S.propSnap = function(obj)
  local res = {}
  local c = obj:GetClass()
  local depth = 0
  while valid(c) and depth < 6 do
    local ccn = c:GetFName():ToString()
    if not ccn:find("_C$") then break end
    pcall(function()
      c:ForEachProperty(function(pr)
        pcall(function()
          local n = pr:GetFName():ToString()
          local pc = pr:GetClass():GetFName():ToString()
          local v
          if pc == "BoolProperty" or pc == "FloatProperty" or pc == "IntProperty" or pc == "ByteProperty" or pc == "EnumProperty" or pc == "DoubleProperty" then
            local x = obj[n]; v = type(x) == "number" and string.format("%.4g", x) or tostring(x)
          elseif pc == "ObjectProperty" or pc == "WeakObjectProperty" then
            local x = obj[n]
            if pc == "WeakObjectProperty" then pcall(function() x = x:Get() end) end
            v = (x == S.p1 and "Low") or (x == S.buddy and "Alone") or (valid(x) and cname(x)) or "пусто"
          elseif pc == "ArrayProperty" then
            local x = obj[n]; local cnt = 0; local parts = {}
            pcall(function() x:ForEach(function(_, el) cnt = cnt + 1; local e = el:get(); if cnt <= 4 then parts[#parts + 1] = (e == S.p1 and "Low") or (e == S.buddy and "Alone") or (valid(e) and cname(e)) or "?" end end) end)
            v = "[" .. cnt .. ": " .. table.concat(parts, " ") .. "]"
          elseif pc == "NameProperty" then v = obj[n]:ToString()
          end
          if v then res[n] = v end
        end)
      end)
    end)
    local ok, sup = pcall(function() return c:GetSuperStruct() end)
    c = ok and sup or nil
    depth = depth + 1
  end
  return res
end
S.propDiff = function(obj, key, tag)
  S.propPrev = S.propPrev or {}
  local cur = S.propSnap(obj)
  local prev = S.propPrev[key]
  S.propPrev[key] = cur
  if not prev then
    local all = {}
    for k, v in pairs(cur) do all[#all + 1] = k .. "=" .. v end
    table.sort(all)
    trail(tag .. " все переменные: " .. table.concat(all, ", "))
    return
  end
  local ch = {}
  for k, v in pairs(cur) do
    local noisy = { ["GrabAngle"] = 1, ["GrabDistance"] = 1, ["Walk Angle"] = 1, ["GrabPrepare_Float"] = 1, ["Dot Value"] = 1, ["Alpha"] = 1,
      ["BlendWeight"] = 1, ["IKAlpha"] = 1, ["LookAtAlpha"] = 1, ["IK GrabGoal"] = 1, ["Montage attack blend"] = 1 }
    if prev[k] ~= v and not noisy[k] and not k:find("Time") and not k:find("Delta") and not k:find("Timeline") and not k:find("Alpha") then ch[#ch + 1] = k .. ": " .. tostring(prev[k]) .. "→" .. v end
  end
  if #ch > 0 then table.sort(ch); trail(tag .. ": " .. table.concat(ch, "; ")) end
end
S.buddyHidden = function()
  local hid = false
  pcall(function()
    for _, c in ipairs(S.buddy:K2_GetComponentsByClass(StaticFindObject("/Script/Kosmos.KosmosCharacterToAntagonist")) or {}) do
      if c:IsHiddenToAntagonist() then hid = true end
    end
  end)
  return hid
end
S.chaseTick = function(en, key, cn, dA, zA, dL, zL)
  local E = S.enemy
  E.ch = E.ch or {}
  local st = E.ch[key] or {}; E.ch[key] = st
  local bb = en.Controller.Blackboard
  if not valid(bb) then return end
  if not S.turnHooked then pcall(function() local rc = en.BPC_RotateToTargetPlayer; if valid(rc) then S.watchTurnNode(rc) end end) end
  local who = function(o) return (o == S.p1 and "Low") or (o == S.buddy and "Alone") or (valid(o) and cname(o)) or "пусто" end
  local tgt = nil; pcall(function() tgt = bb:GetValueAsObject(FName("CharacterPercieved")) end)
  if tgt == S.buddy and S.real and CFG.enemy_p0_swap ~= false then
    S.installP0Hook()
    S.p0For[en:GetAddress()] = S.frames
    S.p0Active = S.frames
    if not S.p0Logged[cn] then
      S.p0Logged[cn] = true
      trail(string.format("враги: %s гонится за вторым игроком — для его проверок «игрок 0» теперь герой второго", cn))
    end
  end
  -- разбор: раз в 0,5 с, если у врага что-то поменялось (цель, режимы, взгляд)
  if S.frames - (st.logAt or -999) >= 30 then
    st.logAt = S.frames
    S.bbDump(en)
    local parts = {}
    for k, v in pairs(S.bbPairs or {}) do
      if not v:find("^%-?%d+%.%d$") and not v:find("^%(") then parts[#parts + 1] = k .. "=" .. v end   -- без чисел и координат
    end
    table.sort(parts)
    local focus = nil; pcall(function() focus = en.Controller:GetFocusActor() end)
    local sig = table.concat(parts, ", ") .. " | взгляд " .. who(focus)
    if sig ~= st.sig then
      st.sig = sig
      trail(string.format("погоня: %s (до Low %.0f, до Alone %.0f%s): %s", cn, dL, dA, S.buddyHidden() and ", Alone прячется" or "", sig))
    end
  end
  -- разовый разбор «органов чувств»: что враг вообще замечает
  if not st.percLogged and (dA < 800 or dL < 800) then
    st.percLogged = true
    pcall(function()
      local pc = en.Controller.PerceptionComponent
      local list = {}
      pcall(function()
        local out = {}
        pc:GetKnownPerceivedActors(nil, out)
        for _, a in ipairs(out) do
          local o = a; pcall(function() if type(a.get) == "function" then o = a:get() end end)
          list[#list + 1] = who(o)
        end
      end)
      trail(string.format("погоня: %s — чувства %s, замечает: %s", cn, valid(pc) and cname(pc) or "нет", #list > 0 and table.concat(list, ", ") or "никого"))
    end)
    if not S.heroCompsLogged then
      S.heroCompsLogged = true
      for _, h in ipairs({ S.p1, S.buddy }) do
        pcall(function()
          local names = {}
          local arr = h:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ActorComponent"))
          local function add(c) pcall(function() local n = cname(c); if n:find("Percep") or n:find("Stimul") or n:find("Antagon") or n:find("Sense") or n:find("Noise") then names[#names + 1] = n end end) end
          if type(arr) == "table" then for _, c in ipairs(arr) do add(c) end elseif arr then arr:ForEach(function(_, e) add(e:get()) end) end
          trail(string.format("погоня: у %s для врагов: %s", heroName(h), #names > 0 and table.concat(names, ", ") or "ничего"))
        end)
      end
    end
  end
  if CFG.enemy_retarget == false or not S.real then return end
  local function B(n) local ok, v = pcall(function() return bb:GetValueAsBool(FName(n)) end); return ok and v == true end
  if B("IsDead") or B("Sleeping") or B("PlayerGrabbed") or S.buddyHidden() or zA > 250 then return end
  -- v9.15.5: ВЫЛЕТ. Враг уже схватил героя (идёт захват/сцена смерти), а мы в
  -- тот же миг давали ему «можно атаковать» и поворачивали — вторая атака
  -- поверх захвата роняла игру. Проверяем прямо сейчас, а не раз в 6 кадров.
  local busy = false
  pcall(function() busy = S.anyDying() end)
  if not busy then
    for _, h in ipairs({ S.p1, S.buddy }) do
      pcall(function()
        local m = h:GetCurrentMontage()
        local mn = valid(m) and m:GetFName():ToString() or ""
        if mn:find("Death") or mn:find("Grabbed") or mn:find("Grab_Success") or mn:find("Kill") then busy = true end
      end)
    end
  end
  if busy then
    st.turnAt, st.zoneSince = nil, nil
    if not st.busyLogged then st.busyLogged = true; trail(string.format("погоня: %s — герой уже схвачен, не вмешиваюсь", cn)) end
    return
  end
  st.busyLogged = nil
  -- Враг «видит» только героя игрока 1 (так сделано для одиночной игры —
  -- в логе мини-кин в 2 м от Alone её не замечал, а Low — с 3 м). Если Alone
  -- в пределах, с которых враг замечает Low (по умолчанию 3,5 м), ближе
  -- Low и её не загораживает стена — враг «замечает» её и гонится за ней.
  -- Если враг уже гонится за Low, а Alone рядом и ближе на 1,5 м — тоже.
  -- v9.15.2: ХВАТАТЬ ALONE. Враг гонится за Alone и подбежал вплотную, но
  -- «можно атаковать» (CanAttack) игра включает только по расстоянию до Low
  -- (в логе мини-кин стоял в 0,9–1,5 м от Alone с CanAttack=false). Пока
  -- Alone прямо перед ним — включаем; если за секунду он так и не схватил,
  -- просим игру «поймать» Alone так же, как она ловит Low.
  -- v9.15.4: ВРАГ «ГОНИТСЯ» ЗА ALONE, НО НЕ ПОВОРАЧИВАЕТСЯ К НЕЙ. По журналу
  -- великан в погоне за Alone смотрел на Low (2–12° от взгляда), а схватить
  -- может только прямо перед собой (±5°). Поворачивает врага узел игры
  -- «повернуться к цели» (BPC_RotateToTargetPlayer), и в одиночной игре
  -- целью ему игра даёт только Low — как и с паучихой: ловит второго, только
  -- когда первый рядом. Поэтому, пока враг гонится за Alone и она в пределах
  -- его захвата, вызываем тот же узел игры с теми же параметрами, что игра
  -- использует для Low, но с целью Alone. Дальше игра сама решает и ловит.
  if tgt == S.buddy and B("Chase") and not B("PlayerGrabbed") and not S.dyingNow and CFG.enemy_turn_to_p2 ~= false then
    pcall(function()
      local el, bl = en:K2_GetActorLocation(), S.buddy:K2_GetActorLocation()
      local dx, dy = bl.X - el.X, bl.Y - el.Y
      local d = math.sqrt(dx * dx + dy * dy)
      if d > (CFG.enemy_turn_dist or 600) then st.turnAt = nil; return end
      local rc = en.BPC_RotateToTargetPlayer
      if not valid(rc) then return end
      S.watchTurnNode(rc)
      -- v9.15.5: узел вызываем, только если игра сама поворачивает им ЭТОГО
      -- врага (видели её вызов), и с её же параметрами. Надсмотрщик второй
      -- главы этим узлом не пользуется — наш вызов с чужими параметрами ронял игру.
      local gp = S.turnSeen[cn]
      if not gp then
        if not st.turnSkipLogged then
          st.turnSkipLogged = true
          trail(string.format("погоня: %s гонится за Alone (%.0f см) — игра не поворачивает его узлом «к цели», не трогаю", cn, d))
        end
        return
      end
      local dt = st.turnAt and math.min((S.frames - st.turnAt) / 60, 0.1) or (1 / 60)
      st.turnAt = S.frames
      S.turnSelf = true
      local ok, e = pcall(function() rc:RUN_RotateToTargetActor(en.CapsuleComponent, S.buddy.CapsuleComponent, gp.blend, gp.speed, dt, gp.fn) end)
      S.turnSelf = false
      if not st.turnLogged or not ok then
        st.turnLogged = true
        trail(string.format("погоня: %s гонится за Alone (%.0f см) — поворачиваю его к ней узлом игры с её параметрами %.2f/%.2f/%d (%s)", cn, d, gp.blend, gp.speed, gp.fn, ok and "ок" or tostring(e)))
      end
    end)
  else
    st.turnAt = nil
  end
  if tgt == S.buddy and B("Chase") then
    local el, bl = en:K2_GetActorLocation(), S.buddy:K2_GetActorLocation()
    local dx, dy = bl.X - el.X, bl.Y - el.Y
    local d = math.sqrt(dx * dx + dy * dy)
    local front = false
    pcall(function()
      local fw = en:GetActorForwardVector()
      local fl = math.max(math.sqrt(fw.X * fw.X + fw.Y * fw.Y), 0.001)
      front = (fw.X * dx + fw.Y * dy) / (math.max(d, 1) * fl) > math.cos(math.rad(40))
    end)
    if d < (CFG.enemy_catch_dist or 180) and front then
      if not B("CanAttack") then pcall(function() bb:SetValueAsBool(FName("CanAttack"), true) end) end
      st.zoneSince = st.zoneSince or S.frames
      if not st.attackLogged then st.attackLogged = true; trail(string.format("погоня: %s вплотную к Alone (%.0f см) — разрешил атаку", cn, d)) end
      if S.frames - st.zoneSince > 60 and S.frames - (st.killAt or -9999) > 300 and not S.dyingNow then
        st.killAt = S.frames
        local ok, e = pcall(function() en:KillPlayer(S.buddy) end)
        trail(string.format("погоня: %s за 1 с не схватил Alone — прошу игру поймать её (%s)", cn, ok and "ок" or tostring(e)))
      end
    else
      st.zoneSince = nil; st.attackLogged = nil
    end
  end
  local seeR = CFG.enemy_see_p2 or 350
  local why = nil
  if tgt ~= S.buddy and dA < seeR and dA < dL then why = "заметил Alone"
  elseif tgt == S.p1 and dA < 1200 and dA + 150 < dL then why = "Alone ближе" end
  if not why then return end
  local los = true
  pcall(function() local r = en.Controller:LineOfSightTo(S.buddy, { X = 0, Y = 0, Z = 0 }, false); if r == false then los = false end end)
  if not los then return end
  local ok = pcall(function()
    bb:SetValueAsObject(FName("CharacterPercieved"), S.buddy)
    bb:SetValueAsBool(FName("IsCharacterPercieved"), true)
    bb:SetValueAsBool(FName("IsAlerted"), true)
  end)
  local now = nil; pcall(function() now = bb:GetValueAsObject(FName("CharacterPercieved")) end)
  if not st.rtAt or S.frames - st.rtAt > 300 then
    trail(string.format("погоня: %s — %s (до Alone %.0f, до Low %.0f, цель была %s) — гонится за Alone (%s)", cn, why, dA, dL, who(tgt), (ok and now == S.buddy) and "ок" or "не вышло"))
  end
  st.rtAt = S.frames
end
S.enemyTick = function()
  if CFG.enemies_catch_p2 == false then return end
  local E = S.enemy
  if S.frames - E.listAt > 120 then E.list = FindAllOf("KosmosAntagonistCharacter") or {}; E.listAt = S.frames end
  E.bbAt = E.bbAt or {}; E.st = E.st or {}
  local bl = S.buddy:K2_GetActorLocation()
  local pl = S.p1:K2_GetActorLocation()
  local function d2(a, b) local x, y = a.X - b.X, a.Y - b.Y; return math.sqrt(x * x + y * y), math.abs(a.Z - b.Z) end
  for _, en in ipairs(E.list) do
    if valid(en) then pcall(function()
      local el = en:K2_GetActorLocation()
      local dA, zA = d2(el, bl)
      local dL, zL = d2(el, pl)
      local key, cn = en:GetFullName(), cname(en)
      if (dA < 1500 and zA < 400) or (dL < 1500 and zL < 400) then
        S.traceNear = S.frames
        pcall(S.traceClass, en:GetClass())   -- нужно для выбора цели врагом
        pcall(function() local c = en.BPC_PlayerProximitySensor; if valid(c) then S.traceClass(c:GetClass()) end end)
        if CFG.enemy_trace_log == true then
          pcall(function() S.traceClass(en.Controller:GetClass()) end)
          pcall(function() S.traceClass(S.p1:GetClass()) end)
          pcall(function() S.traceClass(S.buddy:GetClass()) end)
        end
      end
      if CFG.enemy_diag == true and ((dA < 700 and zA < 300) or (dL < 700 and zL < 300)) and S.frames % 6 == 0 then
        S.diagNear = S.frames
        local tag = string.format("(до Low %.0f, до Alone %.0f)", dL, dA)
        pcall(function() S.propDiff(en, key, "враг " .. tag) end)
        pcall(function() S.propDiff(en.Controller, key .. "#c", "мозг врага " .. tag) end)
        for _, cn2 in ipairs({ "BPC_PlayerProximitySensor", "BPC_RotateToTargetPlayer", "BPC_Antagonist_Animation_Controller_SuperVisor_Crawl" }) do
          pcall(function()
            local comp = en[cn2]
            if valid(comp) then
              S.propDiff(comp, key .. "#" .. cn2, cn2 .. " " .. tag)
              pcall(S.traceClass, comp:GetClass())
            end
          end)
        end
        if S.frames % 30 == 0 then
          pcall(function()
            local function w(o) return (o == S.p1 and "Low") or (o == S.buddy and "Alone") or (valid(o) and cname(o)) or "пусто" end
            trail(string.format("замер врага %s: цель=%s, угол=%.0f, дистанция=%.0f, в зоне захвата=%s, схватил=%s",
              tag, w(en["Current Target Local"]), en.GrabAngle, en.GrabDistance, tostring(en.InGrabRange), tostring(en.Grabbed)))
          end)
        end
      end
      -- «память» врага рядом с героями (раз в 0,5 с) — для разбора
      if CFG.enemy_diag == true and (not E.bbAt[key] or S.frames - E.bbAt[key] >= 120) then
        if dA < 450 and zA < 200 then
          E.bbAt[key] = S.frames
          pcall(function() trail(string.format("враг %s в %.0f см от Alone (подсадка=%s): %s", cn, dA, S.boost and "да" or "нет", S.bbDump(en))) end)
        elseif dL < 450 and zL < 200 then
          E.bbAt[key] = S.frames
          pcall(function() trail(string.format("враг %s в %.0f см от Low (подсадка=%s): %s", cn, dL, S.boost and "да" or "нет", S.bbDump(en))) end)
        end
      end
      -- изменения «памяти» врага рядом с героями — каждое, сразу
      if CFG.enemy_diag == true and ((dA < 700 and zA < 200) or (dL < 700 and zL < 200)) then
        pcall(function()
          S.bbDump(en)
          local cur = S.bbPairs
          local prev = E.bbPrev and E.bbPrev[key]
          E.bbPrev = E.bbPrev or {}; E.bbPrev[key] = cur
          if prev then
            local ch = {}
            for k, v in pairs(cur) do
              if k ~= "Distance" and prev[k] ~= v then ch[#ch + 1] = k .. ": " .. tostring(prev[k]) .. "→" .. v end
            end
            if #ch > 0 then trail(string.format("враг %s (до Low %.0f, до Alone %.0f, Distance=%s): %s", cn, dL, dA, tostring(cur.Distance), table.concat(ch, "; "))) end
          end
        end)
      end
      if ((dA < 300 and zA < 200) or (dL < 300 and zL < 200)) and CFG.enemy_diag == true and (not S.tlNext or S.frames >= S.tlNext) then
        S.tlNext = S.frames + 120
        if S.tl and #S.tl.lines > 0 then trail("лента кадров врага:\n    " .. table.concat(S.tl.lines, "\n    ")) end
        S.tl = { f0 = S.frames, untilF = S.frames + 3, lines = {}, sensor = en.BPC_PlayerProximitySensor }
      end
      -- v9.15.2: ПОГОНЯ ЗА ВТОРЫМ ИГРОКОМ. Враг выбирает, за кем бежать, по
      -- своей «памяти» (CharacterPercieved). В одиночной игре видит он только
      -- игрока 1 — и бежит к Low, даже если Alone у него под носом (жалоба на
      -- мини-кинов в вентиляции). Если враг гонится за Low, а Alone заметно
      -- ближе и не прячется — пусть гонится за Alone.
      if (dA < 2500 and zA < 500) or (dL < 2500 and zL < 500) then pcall(S.chaseTick, en, key, cn, dA, zA, dL, zL) end
      if dA > 600 or zA > 200 then return end
      local bb = en.Controller.Blackboard
      if not valid(bb) then return end
      local function B(n) local ok, v = pcall(function() return bb:GetValueAsBool(FName(n)) end); return ok and v == true end
      local target = nil; pcall(function() target = bb:GetValueAsObject(FName("CharacterPercieved")) end)
      local st = E.st[key] or {}; E.st[key] = st
      -- Враг гонится за Alone и подполз вплотную, но его «можно атаковать»
      -- остаётся выключенным: игра включает его только для героя игрока 1.
      -- Включаем так же, как она делает это для Low, — дальше атака идёт сама.
      if target == S.buddy and B("CHASE") and not B("CanAttack") and not B("IsDead") and not B("InHidingSpot")
         and dA < (CFG.enemy_catch_dist or 200) then
        local hid = false
        pcall(function()
          for _, c in ipairs(S.buddy:K2_GetComponentsByClass(StaticFindObject("/Script/Kosmos.KosmosCharacterToAntagonist")) or {}) do
            if c:IsHiddenToAntagonist() then hid = true end
          end
        end)
        if not hid then
          if not st.watch or S.frames - st.watch > 300 then
            trail(string.format("враги: %s догнал Alone (%.0f см, подсадка=%s)", cn, dA, S.boost and "да" or "нет"))
          end
          st.watch = S.frames
        end
      end
      -- ГЛАВНОЕ. Враг хватает только «своего героя этого компьютера» — так
      -- сделано для сетевой игры, где каждый компьютер сам проверяет своего
      -- героя. На одном компьютере «свой» у игры только герой игрока 1, и
      -- героя игрока 2 враг догоняет, но схватить не может. Пока враг гонится
      -- за Alone вплотную (а Low дальше), «свой герой» для игры — Alone.
      if target == S.buddy and B("CHASE") and dA < (CFG.enemy_catch_dist or 300) and dL > dA + 80 and CFG.enemy_local_swap == true then
        S.localSwap = S.localSwap or {}
        if not S.localSwap.on then
          local okc, was = pcall(function() return S.pc1.Character end)
          local ok = pcall(function() S.pc1.Character = S.buddy end)
          local now = nil; pcall(function() now = S.pc1.Character end)
          S.localSwap = { on = (now == S.buddy), was = okc and was or nil }
          trail(string.format("враги: %s догоняет Alone (%.0f см) — «свой герой» для игры теперь Alone (%s)", cn, dA, tostring(S.localSwap.on)))
          pcall(function() trail("роли после замены: " .. S.roleDiag()) end)
        end
        S.localSwap.until_ = S.frames + 45
        st.watch = S.frames
      end
      if st.watch and S.frames - st.watch < 120 and S.frames % 60 == 0 then
        local stv = "?"; pcall(function() stv = tostring(bb:GetValueAsEnum(FName("CurrentAnimState"))) end)
        local mon = "нет"; pcall(function() local m = S.buddy:GetCurrentMontage(); if valid(m) then mon = m:GetFName():ToString() end end)
        trail(string.format("враги: %s после разрешения: состояние=%s CHASE=%s CanAttack=%s AttackMode=%s PlayerGrabbed=%s PlayerKilled_new=%s | Alone: %s",
          cn, stv, tostring(B("CHASE")), tostring(B("CanAttack")), tostring(B("AttackMode")), tostring(B("PlayerGrabbed")), tostring(B("PlayerKilled_new")), mon))
      end
    end) end
  end
end

-- угол точки t от центра кадра камеры (доли половины угла обзора)
S.camFrac = function(cl, cr, fov, t)
  local yaw, pitch = math.rad(cr.Yaw), math.rad(cr.Pitch)
  local fx, fy, fz = math.cos(pitch) * math.cos(yaw), math.cos(pitch) * math.sin(yaw), math.sin(pitch)
  local rx, ry = -math.sin(yaw), math.cos(yaw)
  local ux, uy, uz = -math.sin(pitch) * math.cos(yaw), -math.sin(pitch) * math.sin(yaw), math.cos(pitch)
  local dx, dy, dz = t.X - cl.X, t.Y - cl.Y, t.Z - cl.Z
  local f = dx * fx + dy * fy + dz * fz
  if f <= 1 then return nil end
  local th = math.tan(math.rad((fov or 60) / 2))
  return (dx * rx + dy * ry) / f / th, (dx * ux + dy * uy + dz * uz) / f / (th / S.sharedAspect)
end
-- v9.15.5: ЛУК У ИГРОКА 2. Цель лука выбирает игра, и мишень годится, только
-- если видна «на экране» — а экран для игры это камера игрока 1. На
-- разделённом экране мишень на половине второго (веревка наверху) для игры
-- «за кадром», и лук её не берёт. Поэтому, пока лук у героя второго игрока,
-- мишеням лука, которые видны в его камере, снимаем эту проверку экрана —
-- дальше цель выбирает сама игра, как обычно. Когда лук убран или экран
-- общий — возвращаем как было.
S.bowFix = { set = {}, list = {}, at = -10000 }
S.bowRestore = function()
  for tc, was in pairs(S.bowFix.set) do
    pcall(function() if valid(tc) then tc.bShouldCheckForOnScreen = was end end)
  end
  S.bowFix.set = {}
end
S.bowAimTick = function()
  if S.frames % 3 ~= 0 then return end
  local bf = S.bowFix
  local active = false
  if S.split and CFG.bow_p2_screen ~= false and valid(S.cam2) and valid(S.buddy) then
    if S.frames - bf.at > 120 or not valid(bf.bow) then
      bf.at = S.frames
      bf.bow = nil
      for _, b in ipairs(FindAllOf("BP_Bow_C") or {}) do
        pcall(function()
          local h = nil
          pcall(function() h = b.Character end)
          if not valid(h) then h = b:GetOwner() end
          if h == S.buddy then bf.bow = b end
        end)
      end
      bf.list = {}
      if bf.bow then
        for _, tc in ipairs(FindAllOf("KosmosTargetComponent") or {}) do
          pcall(function() if valid(tc) and (tc.CurrentCategories or 0) % 2 == 1 then bf.list[#bf.list + 1] = tc end end)
        end
      end
    end
    pcall(function() active = valid(bf.bow) and (bf.bow.bHidden == false or bf.bow:IsInUse() == true) end)
  end
  if not active then
    if next(bf.set) then S.bowRestore(); trail("лук игрока 2: проверку экрана у мишеней вернул") end
    return
  end
  local c2l, c2r, c2f = S.cam2:K2_GetActorLocation(), S.cam2:K2_GetActorRotation(), 60
  pcall(function() c2f = S.cam2.CameraComponent.FieldOfView end)
  local added = 0
  for _, tc in ipairs(bf.list) do
    pcall(function()
      if not valid(tc) then return end
      local x, y = S.camFrac(c2l, c2r, c2f, tc:K2_GetComponentLocation())
      local seen = x and math.abs(x) <= 1 and math.abs(y) <= 1
      if seen and bf.set[tc] == nil then
        local was = tc.bShouldCheckForOnScreen
        if was then bf.set[tc] = was; tc.bShouldCheckForOnScreen = false; added = added + 1 end
      elseif not seen and bf.set[tc] ~= nil then
        tc.bShouldCheckForOnScreen = bf.set[tc]; bf.set[tc] = nil
      end
    end)
  end
  if added > 0 then trail(string.format("лук игрока 2: мишеней в его кадре без проверки экрана игры: +%d", added)) end
end
local function applyInputReal()
  local _, _, lx, ly, p2jump, grab = readP2()
  pcall(S.midCamTick)
  pcall(S.bowAimTick)
  pcall(S.holdCam1)
  -- для сравнения: как камера игрока 1 выглядит в обычной игре (раз в 10 с)
  pcall(S.traceFlush, S.traceNear and S.frames - S.traceNear < 30)
  if S.localSwap and S.localSwap.on then
    local grabbed = false
    pcall(function() local m = S.buddy:GetCurrentMontage(); grabbed = valid(m) and m:GetFName():ToString():find("Grabbed") ~= nil end)
    if grabbed and not S.localSwap.grabLogged then S.localSwap.grabLogged = true; trail("враги: Alone схвачена") end
    if not grabbed and S.frames > (S.localSwap.until_ or 0) then
      local back = S.p1
      pcall(function() if S.pc1.Pawn ~= S.p1 and not S.cam1PawnHack then back = S.localSwap.was end end)
      pcall(function() S.pc1.Character = back end)
      S.localSwap = nil
      trail("враги: «свой герой» для игры снова Low")
    end
  end
  if S.pendingKill and S.frames >= S.pendingKill.at then
    local pk = S.pendingKill; S.pendingKill = nil
    local ok, e = pcall(function() pk.en:KillPlayer(S.buddy) end)
    trail(string.format("враги: поимка игрока 2 после подсадки — %s%s", ok and "отправлена" or "ошибка", ok and "" or (" " .. tostring(e))))
  end
  if not S.boost and S.frames % 600 == 0 then pcall(function() trail("камера 1 обычно: " .. S.cam1Info()) end) end
  if S.animCheckAt and S.frames >= S.animCheckAt then
    S.animCheckAt = nil
    pcall(function() S.animDiff(S.p1, S.animPre and S.animPre[1], "после подсадки") end)
    pcall(function() S.animDiff(S.buddy, S.animPre and S.animPre[2], "после подсадки") end)
  end
  -- «нормальный» снимок анимации для сравнения по F8: через 5 с после того,
  -- как второй игрок получил героя (и обновляем раз в минуту, если без подсадок)
  if not S.boost and not S.hadBoost and S.frames % 3600 == 300 then pcall(function() S.animBase = { [1] = S.animSnapOf(S.p1), [2] = S.animSnapOf(S.buddy) } end) end
  if S.respawnAt then local okR, eR = pcall(S.afterRespawnCam); if not okR then S.respawnAt = nil; trail("камера 1 после возрождения: ошибка " .. tostring(eR)) end end
  if not S.boost and S.frames % 600 == 300 then pcall(function() trail("герои обычно: " .. S.killDiag()); trail("роли обычно: " .. S.roleDiag()); pcall(function() local gm = UEHelpers.GetGameModeBase(); trail(string.format("режим игры: одиночная=%s, игроков=%s", tostring(gm:IsSinglePlayerGame()), tostring(gm.NumPlayers))) end) end) end
  -- v9.15.5: метку (как F8) может поставить и игрок 2 — кнопкой «Выбор»
  -- (View / Share) своего геймпада. Квадрат / X занят бегом.
  if CFG.device == "gamepad" then
    local mb = isDown(p2Source(), CFG.mark_button or "Gamepad_Special_Left")
    if mb and not S.prevMarkBtn then S.markReq = true; pcall(toast, "Метка записана") end
    S.prevMarkBtn = mb
  end
  if S.markReq then
    S.markReq = false
    pcall(function()
      trail("===== МЕТКА (F8) =====")
      trail("подсадка: " .. (S.boost and string.format("идёт, подсаживает %s, %.1f с", heroName(S.boost.hero), (S.frames - S.boost.startFrame) / 60) or "нет"))
      trail("камера 1: " .. S.cam1Info())
      pcall(function()
        local cl = S.cam2:K2_GetActorLocation()
        local fov = -1; pcall(function() fov = S.cam2.CameraComponent.FieldOfView end)
        local vt = nil; pcall(function() vt = S.pc2:GetViewTarget() end)
        trail(string.format("камера 2: до Alone %.0f см, обзор %.0f, режим %s, комната %s, экран %s, вид игрока 2 = %s",
          dist(cl, S.buddy:K2_GetActorLocation()), fov, S.roomSm and "комнатная" or "за героем", valid(RC.cur) and RC.cur:GetFName():ToString() or "нет",
          S.split and "разделён" or "общий", vt == S.cam2 and "наша камера" or clsName(vt)))
      end)
      pcall(function() S.animDiff(S.p1, S.animBase and S.animBase[1] or {}, "(F8)") end)
      pcall(function() S.animDiff(S.buddy, S.animBase and S.animBase[2] or {}, "(F8)") end)
      trail("враги: " .. S.enemyInfo())
      trail("герои: " .. S.killDiag()); trail("роли: " .. S.roleDiag())
    end)
  end
  if S.frames % 3 == 0 then pcall(S.enemyTick) end
  pcall(S.boostInput)
  -- (подсадка у белых мест через ИИ на RT убрана: теперь подсадка — LB/RB где угодно)
  -- для разбора совместных действий (подсадить, тянуть вдвоём): что рядом,
  -- когда игрок 2 жмёт «схватить»
  if grab and not S.prevRealGrab and (not S.nearLogAt or now() - S.nearLogAt > 3) then
    S.nearLogAt = now()
    pcall(function()
      local bl = S.buddy:K2_GetActorLocation()
      local out = {}
      for _, o in ipairs(FindAllOf("KosmosEnvironmentInteractable") or {}) do
        if valid(o) then
          local ol = o:K2_GetActorLocation()
          local d = dist(ol, bl)
          if d < 400 then
            local two = pcall(function() return o.Is2PControlled end) and o.Is2PControlled
            local ctl = nil; pcall(function() ctl = o.CurrentControllingActor end)
            out[#out + 1] = string.format("%s %.0f см, на двоих=%s, держит=%s", cname(o), d, tostring(two), valid(ctl) and cname(ctl) or "никто")
          end
        end
      end
      trail("игрок 2 жмёт «схватить», рядом: " .. (#out > 0 and table.concat(out, "; ") or "ничего"))
    end)
  end
  S.prevRealGrab = grab
  local dz2 = 0.2
  if math.abs(lx) < dz2 then lx = 0 end
  if math.abs(ly) < dz2 then ly = 0 end
  S.p2LookX, S.p2LookY = lx, ly
  if not S.split and (lx ~= 0 or ly ~= 0) then
    try("shared look", function() S.pc1.PlayerCameraManager:AddOverriddenCameraRotation({ Pitch = ly * 8, Yaw = lx * 14, Roll = 0 }) end)
  end
  -- движение героя игрока 2 считается от поворота его контроллера — держим
  -- его равным повороту камеры, которую видит игрок 2
  if valid(S.pc2) then
    pcall(function()
      local r
      if S.split and S.nativeCam then r = S.pc2.PlayerCameraManager:GetCameraRotation()
      elseif S.split and valid(S.cam2) then r = S.cam2:K2_GetActorRotation()
      else r = S.pc1.PlayerCameraManager:GetCameraRotation() end
      S.pc2:SetControlRotation({ Pitch = 0, Yaw = r.Yaw, Roll = 0 })
    end)
  end
end

local GAME_CMD_KEEP = { KosmosAIActionInteractionPoint = true, KosmosAIActionPlayMontage = true }

local function applyInput()
  local f, r, lx, ly, jump, grab, crouch, sprint, throw, weapon = readP2()
  if weapon and not S.prev.weapon and not heldItem() then
    local want = not S.weaponOut
    if runCmd(want and "достать оружие" or "убрать оружие", function() return S.cmdCall("WeaponTools", "PlaypalWeaponShowHide", S.buddy, want) end) then
      S.weaponOut = want
    end
  end
  S.prev.weapon = weapon
  -- сверяемся с игрой: действительно ли оружие/инструмент в руке
  if S.frames % 30 == 0 and not S.cmd then
    local ok1, w1 = pcall(function() return S.buddy:IsWeaponEquipped() end)
    local ok2, w2 = pcall(function() return S.buddy:IsToolEquipped() end)
    if ok1 or ok2 then S.weaponOut = (ok1 and w1 == true) or (ok2 and w2 == true) end
  end
  if CFG.swap_axes then f, r = r, f end
  if CFG.invert_forward then f = -f end
  if CFG.invert_right then r = -r end
  local b, ai = S.buddy, S.ai
  -- Предметы — как у игрока 1: держишь «схватить» — несёшь, отпустил — положил,
  -- прыжок с предметом в руках — бросок.
  local held = heldItem()
  if held and not S.wasHeld then S.pickedAt = S.frames end
  if not held then S.wantPutdown = false end
  S.wasHeld = held ~= nil
  if S.cbox then
    cboxTick(f, r, grab)
    S.prev.grab, S.prev.throw, S.prev.jump = grab, throw, jump
    return
  end
  if S.drag then
    dragTick(f, r, grab)
    S.prev.grab, S.prev.throw, S.prev.jump = grab, throw, jump
    return
  end
  if cmdRunning() then
    if not grab and S.cmd.label:find("^поднять") then S.putdownAfter = true end
    if (f ~= 0 or r ~= 0) and S.frames - S.cmd.startFrame > 15 and not S.cmd.label:find("^поднять") then
      try("cancel cmd", function() ai:StopAllAICommands() end); S.cmd = nil
    else
      S.prev.grab, S.prev.throw, S.prev.jump = grab, throw, jump
      return
    end
  end
  if held then
    -- кнопку отпустили (или отпустили ещё во время подъёма) — кладём.
    -- Игра игнорирует «положи», пока не доиграна анимация подъёма, поэтому
    -- ждём немного после подъёма и, если предмет всё ещё в руках, повторяем.
    if (S.putdownAfter or (not grab and S.prev.grab) or (S.wantPutdown and not grab)) then
      S.putdownAfter = false
      S.wantPutdown = true
      if not S.pickedAt or S.frames - S.pickedAt > 20 then
        if not S.lastPutdownAt or S.frames - S.lastPutdownAt > 50 then
          S.lastPutdownAt = S.frames
          runCmd("положить", function() return S.cmdCall("Carriable", "PlaypalCarriable_Putdown", S.buddy, false, { X = 0, Y = 0, Z = 0 }) end)
        end
      end
      S.prev.grab, S.prev.jump, S.prev.throw = grab, jump, throw
      return
    end
    if grab then S.wantPutdown = false end
    if (jump and not S.prev.jump) or (throw and not S.prev.throw) then
      tryThrow()
      S.prev.grab, S.prev.jump, S.prev.throw = grab, jump, throw
      return
    end
    S.noJump = true                    -- с предметом в руках прыжка нет
  else
    S.noJump = false
    S.putdownAfter = false
    -- оружие в руке (достали кнопкой B): «схватить» = удар/выстрел
    if S.weaponOut then
      if grab and not S.prev.grab then tryWeapon() end
      S.prev.grab = grab
      grab = false
    end
    if grab and not S.prev.grab then
      local cb = nearestCBox()
      if cb and startCBox(cb) then S.prev.grab = grab; return end
      local box, bd = nearestDraggable()
      local c0, cd0 = nearestCarriable()
      if box and (not c0 or bd < cd0) and startDrag(box) then S.prev.grab = grab; return end
      if not box and not c0 then
        -- для разбора: что из «взаимодействуемого» есть рядом
        local near = {}
        for _, cls in ipairs({ "KosmosEnvironmentInteractable", "KosmosDraggable" }) do
          for _, o in ipairs(FindAllOf(cls) or {}) do
            local ok, dd = pcall(function() return o:GetDistanceTo(S.buddy) end)
            if ok and dd < 400 then near[#near + 1] = string.format("%s %.0f см", cname(o), dd) end
          end
        end
        log("рядом с напарником: %s", #near > 0 and table.concat(near, "; ") or "ничего")
      end
      local c, d = c0, cd0
      if c and runCmd(string.format("поднять (%.0f см)", d), function() return S.cmdCall("Carriable", "PlaypalCarriable_Pickup", S.buddy, c) end) then
        S.prev.grab = grab; return
      end
    end
  end
  S.prev.throw = throw
  S.p2Moving = (f ~= 0 or r ~= 0)
  try("AI_SetRawInput", function() b:AI_SetRawInput({ X = f, Y = r, Z = 0 }) end)
  try("MovementInput", function() ai:MovementInput({ X = f, Y = r }) end)
  local dz2 = 0.2
  if math.abs(lx) < dz2 then lx = 0 end
  if math.abs(ly) < dz2 then ly = 0 end
  S.p2LookX, S.p2LookY = lx, ly
  -- общий экран: игрок 2 тоже может «осмотреться» общей камерой
  if not S.split and (lx ~= 0 or ly ~= 0) then
    try("shared look", function() S.pc1.PlayerCameraManager:AddOverriddenCameraRotation({ Pitch = ly * 8, Yaw = lx * 14, Roll = 0 }) end)
    if not S.sharedLookLogged then S.sharedLookLogged = true; log("игрок 2 двигает общую камеру") end
  end
  if grab ~= S.prev.grab then
    try("AI_SetRawPressedInteract", function() b:AI_SetRawPressedInteract(grab) end)
    try("GrabInput", function() ai:GrabInput(grab) end)
    S.prev.grab = grab
  end
  if crouch ~= S.prev.crouch then try("SetSneaking", function() b:SetSneaking(crouch, false) end); S.prev.crouch = crouch end
  if sprint ~= S.prev.sprint then try("PlaypalSetSprint", function() b:PlaypalSetSprint(sprint) end); S.prev.sprint = sprint end
  if jump and not S.prev.jump and not S.noJump then
    try("MakeSimpleControlledJump", function() b:MakeSimpleControlledJump() end)
    try("Jump", function() b:Jump() end)
    log("прыжок игрока 2")
  end
  S.prev.jump = jump
end

------------------------------------------------------------------ меню
local KEY_NAMES = {
  Up = "Стрелка вверх", Down = "Стрелка вниз", Left = "Стрелка влево", Right = "Стрелка вправо",
  Enter = "Enter", SpaceBar = "Пробел", RightShift = "Правый Shift", LeftShift = "Левый Shift",
  RightControl = "Правый Ctrl", LeftControl = "Левый Ctrl", RightAlt = "Правый Alt", LeftAlt = "Левый Alt",
  Slash = "/", Period = ".", Comma = ",", Semicolon = ";", Apostrophe = "'", Backslash = "\\",
  LeftBracket = "[", RightBracket = "]", Hyphen = "-", Equals = "=", BackSpace = "Backspace",
  Gamepad_FaceButton_Bottom = "A / Крест", Gamepad_FaceButton_Right = "B / Круг",
  Gamepad_FaceButton_Left = "X / Квадрат", Gamepad_FaceButton_Top = "Y / Треугольник",
  Gamepad_RightTrigger = "RT / R2", Gamepad_LeftTrigger = "LT / L2",
  Gamepad_RightShoulder = "RB / R1", Gamepad_LeftShoulder = "LB / L1",
}
local function keyTitle(k) if not k then return "по умолчанию" end if KEY_NAMES[k] then return KEY_NAMES[k] end
  k = k:gsub("^NumPad", "Цифр. "):gsub("Zero", "0"):gsub("One", "1"):gsub("Two", "2"):gsub("Three", "3"):gsub("Four", "4")
       :gsub("Five", "5"):gsub("Six", "6"):gsub("Seven", "7"):gsub("Eight", "8"):gsub("Nine", "9"); return k end

local CAPTURE_KEYS = {}
do
  for c in ("ABCDEFGHIJKLMNOPQRSTUVWXYZ"):gmatch(".") do CAPTURE_KEYS[#CAPTURE_KEYS + 1] = c end
  for _, n in ipairs({ "Zero","One","Two","Three","Four","Five","Six","Seven","Eight","Nine" }) do
    CAPTURE_KEYS[#CAPTURE_KEYS + 1] = n; CAPTURE_KEYS[#CAPTURE_KEYS + 1] = "NumPad" .. n end
  for _, n in ipairs({ "Up","Down","Left","Right","Enter","SpaceBar","RightShift","LeftShift","RightControl","LeftControl",
    "RightAlt","LeftAlt","Tab","Insert","Delete","Home","End","PageUp","PageDown","Slash","Period","Comma","Semicolon",
    "Apostrophe","LeftBracket","RightBracket","Backslash","Hyphen","Equals","Multiply","Add","Subtract","Decimal","Divide",
    "Gamepad_FaceButton_Bottom","Gamepad_FaceButton_Right","Gamepad_FaceButton_Left","Gamepad_FaceButton_Top",
    "Gamepad_RightTrigger","Gamepad_LeftTrigger","Gamepad_RightShoulder","Gamepad_LeftShoulder",
    "Gamepad_RightThumbstick","Gamepad_LeftThumbstick" }) do CAPTURE_KEYS[#CAPTURE_KEYS + 1] = n end
end

S.SPLIT_SIDES = { { "auto", "Авто (как стоят герои)" }, { "top_bottom", "Горизонтально" }, { "left_right", "Вертикально" },
  { "always_top_bottom", "Всегда горизонтально" }, { "always_left_right", "Всегда вертикально" } }
local SPLIT_MODES = { { "auto", "Авто (когда не видно)" }, { "distance", "По расстоянию" }, { "always", "Всегда разделён" }, { "never", "Всегда общий" } }
local LAYOUTS = { { "top_bottom", "Сверху и снизу" }, { "left_right", "Слева и справа" } }
local DEVICES = { { "keyboard", "Клавиатура (правая часть)" }, { "gamepad", "Геймпад" } }
local function optTitle(list, v) for _, o in ipairs(list) do if o[1] == v then return o[2] end end return tostring(v) end
local function optCycle(list, v, dir)
  local i = 1; for j, o in ipairs(list) do if o[1] == v then i = j end end
  i = ((i - 1 + dir) % #list) + 1; return list[i][1]
end

local ACTIONS_KB = { { "up", "Вперёд" }, { "down", "Назад" }, { "left", "Влево" }, { "right", "Вправо" },
  { "jump", "Прыжок" }, { "grab", "Схватить / нести (держать)" }, { "throw", "Бросить (или прыжок с предметом)" }, { "weapon", "Достать/убрать ключ или лук" }, { "crouch", "Присесть (держать)" }, { "sprint", "Бег (держать)" } }
local ACTIONS_PAD = { { "jump", "Прыжок" }, { "grab", "Схватить / нести (держать)" }, { "throw", "Бросить (или прыжок с предметом)" }, { "weapon", "Достать/убрать ключ или лук" }, { "crouch", "Присесть (держать)" }, { "sprint", "Бег (держать)" } }

local buildMenu
local function changed() saveSettings() end

local function mainMenu()
  return {
    title = "КООПЕРАТИВ — LN3Couch",
    items = {
      { label = function() return "Второй игрок" end, value = function() return S.coopWanted() and "ВКЛЮЧЁН" or "выключен" end,
        act = function() S.userSetCoop(not S.coopWanted()) end, left = function() S.userSetCoop(not S.coopWanted()) end, right = function() S.userSetCoop(not S.coopWanted()) end },
      { label = function() return "Управление игрока 2" end, value = function() return optTitle(DEVICES, CFG.device) end,
        left = function() CFG.device = optCycle(DEVICES, CFG.device, -1); changed(); applyGamepadRouting() end,
        right = function() CFG.device = optCycle(DEVICES, CFG.device, 1); changed(); applyGamepadRouting() end },
      { label = function() return "Геймпад №1 у" end, value = function() return CFG.gamepad_goes_to_player2 and "игрока 2" or "игрока 1" end,
        act = function() CFG.gamepad_goes_to_player2 = not CFG.gamepad_goes_to_player2; changed(); applyGamepadRouting() end,
        left = function() CFG.gamepad_goes_to_player2 = not CFG.gamepad_goes_to_player2; changed(); applyGamepadRouting() end,
        right = function() CFG.gamepad_goes_to_player2 = not CFG.gamepad_goes_to_player2; changed(); applyGamepadRouting() end },
      { label = function() return "Разделение" end, value = function() return optTitle(S.SPLIT_SIDES, CFG.split_sides or "auto") end,
        left = function() CFG.split_sides = optCycle(S.SPLIT_SIDES, CFG.split_sides or "auto", -1); changed() end,
        right = function() CFG.split_sides = optCycle(S.SPLIT_SIDES, CFG.split_sides or "auto", 1); changed() end },
      { label = function() return "Кнопки игрока 2  >" end, value = function() return "" end,
        act = function() S.menu, S.sel = buildMenu("keys"), 1 end },
      { label = function() return "Сбросить настройки" end, value = function() return "" end,
        act = function() CFG = deepcopy(DEFAULTS); CFG.split = "auto"; applyLayout(); changed(); toast("Настройки сброшены") end },
      { label = function() return "Закрыть  (F9)" end, value = function() return "" end, act = function() S.menuOpen = false end },
    },
  }
end

local function keysMenu()
  local pad = CFG.device == "gamepad"
  local acts, tbl = pad and ACTIONS_PAD or ACTIONS_KB, pad and CFG.gamepad or CFG.keyboard
  local items = {}
  for _, a in ipairs(acts) do
    local id, title = a[1], a[2]
    items[#items + 1] = { label = function() return title end,
      value = function() if S.capture and S.capture.id == id then return "…нажмите кнопку" end return keyTitle(tbl[id]) end,
      act = function() S.capture = { id = id, tbl = tbl, armed = false } end }
  end
  if pad then items[#items + 1] = { label = function() return "Ходьба" end, value = function() return "левый стик" end } end
  items[#items + 1] = { label = function() return "<  Назад" end, value = function() return "" end,
    act = function() S.menu, S.sel = buildMenu("main"), 7 end }
  return { title = pad and "КНОПКИ ИГРОКА 2 — геймпад" or "КЛАВИШИ ИГРОКА 2 — клавиатура", items = items, back = "main" }
end
buildMenu = function(which) if which == "keys" then return keysMenu() end return mainMenu() end

local function anyCaptureDown()
  local src = CFG.device == "gamepad" and p2Source() or S.pc1
  for _, k in ipairs(CAPTURE_KEYS) do if isDown(src, k) then return k end end
end

local function menuInput()
  if S.capture then
    local k = anyCaptureDown()
    if not S.capture.armed then if not k then S.capture.armed = true end; return end -- ждём отпускания Enter
    if k == "BackSpace" then S.capture = nil; return end
    if k then
      S.capture.tbl[S.capture.id] = k; S.capture = nil; saveSettings()
      toast("Назначено: " .. keyTitle(k))
      for _, n in ipairs({ "Up", "Down", "Left", "Right", "Enter" }) do S.keyPrev[n] = true end
    end
    return
  end
  local items = S.menu.items
  if pressed("Up") then S.sel = (S.sel - 2) % #items + 1 end
  if pressed("Down") then S.sel = S.sel % #items + 1 end
  local it = items[S.sel]
  if pressed("Left") and it.left then try("menu left", it.left) end
  if pressed("Right") and it.right then try("menu right", it.right) end
  if pressed("Enter") and (it.act or it.right) then try("menu act", it.act or it.right) end
  if pressed("BackSpace") then if S.menu.back then S.menu, S.sel = buildMenu(S.menu.back), 1 else S.menuOpen = false end end
end

local function toggleMenu()
  S.menuOpen = not S.menuOpen
  if S.menuOpen then
    S.pc1 = findPC1()
    S.menu, S.sel, S.capture = buildMenu("main"), 1, nil
    for _, n in ipairs({ "Up", "Down", "Left", "Right", "Enter", "BackSpace" }) do S.keyPrev[n] = true end
    if S.coop then resetBuddyInput() end
  end
end

------------------------------------------------------------------ интерфейс (UMG, создаётся на лету)
local WHITE, GOLD, GREY = { R = 1, G = 1, B = 1, A = 1 }, { R = 1, G = 0.82, B = 0.35, A = 1 }, { R = 0.65, G = 0.65, B = 0.65, A = 1 }
local UI = { root = nil, outer = nil, panel = nil, box = nil, lines = {}, failed = false, sig = nil }
local MAXLINES = 16
local VIS_VISIBLE_NOHIT, VIS_COLLAPSED = 3, 1

local function cls(path) local c = StaticFindObject(path); if valid(c) then return c end end

local function createRootWidget()
  local lib = cls("/Script/UMG.Default__WidgetBlueprintLibrary") or StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
  for _, path in ipairs({ "/Script/Kosmos.KosmosUserWidget", "/Script/SMGUIBase.SMGUIUserWidgetBase", "/Script/UMG.UserWidget" }) do
    local c = cls(path)
    if c then
      local ok, w = pcall(function() return lib:Create(S.pc1, c, S.pc1) end)
      if ok and valid(w) then log("интерфейс: базовый виджет %s", path); return w end
      log("интерфейс: %s не подошёл", path)
    end
  end
end

local function newWidget(path, outer)
  local c = cls(path); if not c then error("нет класса " .. path) end
  local w = StaticConstructObject(c, outer)
  if not valid(w) then error("не создан " .. path) end
  return w
end

local function buildUI()
  if UI.failed then return false end
  if valid(UI.root) then
    local ok, inVp = pcall(function() return UI.root:IsInViewport() end)
    if ok and inVp then return true end
    if ok and not inVp then pcall(function() UI.root:AddToViewport(1000) end); return true end
  end
  if not valid(S.pc1) then S.pc1 = findPC1() end
  if not valid(S.pc1) then return false end
  local ok, err = pcall(function()
    local root = createRootWidget(); if not root then error("не удалось создать базовый виджет") end
    local tree = root.WidgetTree
    if not valid(tree) then tree = newWidget("/Script/UMG.WidgetTree", root); root.WidgetTree = tree end
    local outer = newWidget("/Script/UMG.Border", tree)
    outer:SetBrushColor({ R = 0, G = 0, B = 0, A = 0 })
    outer:SetHorizontalAlignment(2); outer:SetVerticalAlignment(2)
    local panel = newWidget("/Script/UMG.Border", tree)
    panel:SetBrushColor({ R = 0.02, G = 0.02, B = 0.03, A = 0.88 })
    panel:SetPadding({ Left = 40, Top = 26, Right = 40, Bottom = 26 })
    outer:SetContent(panel)
    local box = newWidget("/Script/UMG.VerticalBox", tree)
    panel:SetContent(box)
    UI.lines = {}
    for i = 1, MAXLINES do
      local tb = newWidget("/Script/UMG.TextBlock", tree)
      box:AddChildToVerticalBox(tb)
      UI.lines[i] = tb
    end
    tree.RootWidget = outer
    root:SetVisibility(VIS_COLLAPSED)
    root:AddToViewport(1000)
    UI.root, UI.outer, UI.panel, UI.box, UI.sig = root, outer, panel, box, nil
  end)
  if not ok then UI.failed = true; log("интерфейс создать не удалось: %s", tostring(err)); return false end
  log("интерфейс создан")
  return true
end

local function renderLines(lines, mode)
  local sig = mode .. "|" .. table.concat((function() local t = {}; for i, l in ipairs(lines) do t[i] = l[1] .. (l[2] == GOLD and "*" or "") end; return t end)(), "\n")
  if sig == UI.sig then return end
  UI.sig = sig
  try("render", function()
    if mode == "menu" then
      UI.outer:SetVerticalAlignment(2)
      UI.panel:SetBrushColor({ R = 0.02, G = 0.02, B = 0.03, A = 0.88 })
    else -- уведомление сверху
      UI.outer:SetVerticalAlignment(1)
      UI.panel:SetBrushColor({ R = 0, G = 0, B = 0, A = 0.65 })
    end
    for i = 1, MAXLINES do
      local tb, l = UI.lines[i], lines[i]
      if l then
        tb:SetText(FText(l[1]))
        tb:SetColorAndOpacity({ SpecifiedColor = l[2] or WHITE, ColorUseRule = 0 })
        tb:SetVisibility(VIS_VISIBLE_NOHIT)
      else
        tb:SetVisibility(VIS_COLLAPSED)
      end
    end
    UI.root:SetVisibility(VIS_VISIBLE_NOHIT)
  end)
end

local function hideUI()
  if valid(UI.root) and UI.sig ~= "hidden" then UI.sig = "hidden"; try("hide", function() UI.root:SetVisibility(VIS_COLLAPSED) end) end
end

local function updateUI()
  local showToast = S.toast and now() < S.toastUntil
  if not (S.menuOpen or showToast) then hideUI(); return end
  if not buildUI() then return end
  if S.menuOpen then
    local lines = { { S.T(S.menu.title), GOLD }, { " ", WHITE } }
    for i, it in ipairs(S.menu.items) do
      local sel = (i == S.sel)
      local v = S.T(it.value())
      local txt = (sel and "»  " or "     ") .. S.T(it.label())
      if v ~= "" then txt = txt .. ":   " .. ((sel and it.left) and ("< " .. v .. " >") or v) end
      lines[#lines + 1] = { txt, sel and GOLD or WHITE }
    end
    lines[#lines + 1] = { " ", WHITE }
    lines[#lines + 1] = { S.T(S.capture and "Нажмите кнопку для назначения.  Backspace — отмена"
      or "Стрелки — выбор,  ← → изменить,  Enter — выбрать,  Backspace — назад,  F9 — закрыть"), GREY }
    if showToast then lines[#lines + 1] = { S.toast, GOLD } end
    renderLines(lines, "menu")
  else
    renderLines({ { S.toast, WHITE } }, "toast")
  end
end

------------------------------------------------------------------ пункт «Кооператив» в меню паузы игры
-- Меню паузы игры (PauseMenuWidget) — это список кнопок ButtonBase в ScrollBox.
-- Мы создаём такие же кнопки игры и вставляем их в этот список: выглядят и
-- работают они как родные (наведение, звук, навигация стрелками и геймпадом).
local PM = { widget = nil, sb = nil, orig = {}, coopBtn = nil, pages = {}, page = nil, hookOk = false, clicks = {}, osKey = nil }
local BTN_CLICK_FN = "/Game/UI/Menus/MenuItems/ButtonBase.ButtonBase_C:BndEvt__ButtonBase_MainButton_K2Node_ComponentBoundEvent_2_OnButtonClickedEvent__DelegateSignature"

local function wid(w) local ok, n = pcall(function() return w:GetFullName() end); return ok and n or tostring(w) end
local function wfname(w) local ok, n = pcall(function() return w:GetFName():ToString() end); return ok and n or "" end
local function children(panel)
  local r = {}
  local ok, n = pcall(function() return panel:GetChildrenCount() end)
  if ok and type(n) == "number" then for i = 0, n - 1 do local ok2, c = pcall(function() return panel:GetChildAt(i) end); if ok2 and valid(c) then r[#r + 1] = c end end end
  return r
end
local function findPanelWithChild(w, childName, depth)
  depth = depth or 0; if depth > 10 then return nil end
  for _, c in ipairs(children(w)) do
    if wfname(c) == childName then return w, c end
    local p, found = findPanelWithChild(c, childName, depth + 1)
    if p then return p, found end
  end
end

local function setBtnText(btn, text)
  text = S.T(text)
  try("btn text", function()
    pcall(function() btn.ButtonText = FText(text) end)
    pcall(function() btn.LocalisedString = FText(text) end)
    pcall(function() btn:UpdateText() end)
    pcall(function() btn.NormalText:SetText(FText(text)) end)
    pcall(function() btn.ForceSizer:SetText(FText(text)) end)
  end)
end

local function copySlot(slot, ref)
  pcall(function()
    local rs = ref.Slot
    if valid(slot) and valid(rs) then
      pcall(function() slot:SetPadding(rs.Padding) end)
      pcall(function() slot:SetHorizontalAlignment(rs.HorizontalAlignment) end)
    end
  end)
end

local function focusBtn(btn) pcall(function() btn.MainButton:SetKeyboardFocus() end); pcall(function() btn.MainButton:SetUserFocus(S.pc1) end) end

local function makeBtn(template, owner, text, onClick)
  local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
  local pc = findPC1()
  if not valid(pc) then pcall(function() pc = owner:GetOwningPlayer() end) end
  local btn
  for _, ctx in ipairs({ pc, owner }) do
    if valid(ctx) then
      local ok, r = pcall(function() return lib:Create(ctx, template:GetClass(), valid(pc) and pc or nil) end)
      if ok and valid(r) then btn = r; break end
    end
  end
  if not valid(btn) then error("кнопка не создалась") end
  pcall(function() btn.ParentScreen = owner end)
  setBtnText(btn, text)
  PM.clicks[#PM.clicks + 1] = { btn = btn, id = wid(btn), fn = onClick }
  return btn
end

local function yesno(b) return b and "включён" or "выключен" end

local showPage -- вперёд

local function coopItems()
  return {
    { function() return "Второй игрок: " .. yesno(S.coopWanted()) end, function() S.userSetCoop(not S.coopWanted()) end },
    { function() return "Управление игрока 2: " .. optTitle(DEVICES, CFG.device) end,
      function() CFG.device = optCycle(DEVICES, CFG.device, 1); saveSettings(); PM.rebuildKeys = true; applyGamepadRouting() end },
    { function() return "Геймпад №1 у: " .. (CFG.gamepad_goes_to_player2 and "игрока 2" or "игрока 1") end,
      function() CFG.gamepad_goes_to_player2 = not CFG.gamepad_goes_to_player2; saveSettings(); applyGamepadRouting() end },
    { function() return "Найти геймпад игрока 2" end, function() S.detectPending = true; toast("Закройте паузу и нажимайте A на геймпаде игрока 2") end },
    { function() return "Разделение: " .. optTitle(S.SPLIT_SIDES, CFG.split_sides or "auto") end,
      function() CFG.split_sides = optCycle(S.SPLIT_SIDES, CFG.split_sides or "auto", 1); saveSettings() end },
    { function() return "Кнопки игрока 2" end, function() showPage("keys") end },
    { function() return "Сбросить настройки" end, function() CFG = deepcopy(DEFAULTS); CFG.split = "auto"; applyLayout(); saveSettings(); PM.rebuildKeys = true end },
    { function() return "Назад" end, function() showPage(nil) end },
  }
end

local function keyItems()
  local pad = CFG.device == "gamepad"
  local acts, tbl = pad and ACTIONS_PAD or ACTIONS_KB, pad and CFG.gamepad or CFG.keyboard
  local items = {}
  for _, a in ipairs(acts) do
    local id, title = a[1], a[2]
    items[#items + 1] = {
      function() if S.capture and S.capture.id == id then return title .. ": …нажмите кнопку" end return title .. ": " .. keyTitle(tbl[id]) end,
      function() S.capture = { id = id, tbl = tbl, armed = false, frames = 0, fromPause = true }; PM.osKey = nil end }
  end
  items[#items + 1] = { function() return "Назад" end, function() S.capture = nil; showPage("coop") end }
  return items
end

local function refreshLabels()
  for _, pg in pairs(PM.pages) do for _, e in ipairs(pg) do if valid(e.btn) then setBtnText(e.btn, e.label()) end end end
end

local function buildPage(name)
  local items = name == "coop" and coopItems() or keyItems()
  local list = {}
  for _, it in ipairs(items) do
    local e = { label = it[1] }
    e.btn = makeBtn(PM.template, PM.widget, it[1](), function()
      local before = ""; pcall(function() before = it[1]() end)
      it[2](); refreshLabels()
      local after = ""; pcall(function() after = it[1]() end)
      trail(string.format("меню (%s): нажато «%s» → «%s»", PM.kind or "?", before, after))
    end)
    local slot = PM.sb:AddChild(e.btn); copySlot(slot, PM.template)
    e.btn:SetVisibility(1)
    list[#list + 1] = e
  end
  PM.pages[name] = list
end

showPage = function(name)
  if name == "keys" and PM.rebuildKeys and PM.pages.keys then
    for _, e in ipairs(PM.pages.keys) do pcall(function() PM.sb:RemoveChild(e.btn) end) end
    PM.pages.keys = nil; PM.rebuildKeys = false
  end
  if name and not PM.pages[name] then try("build page " .. name, buildPage, name) end
  if name and not PM.saved then
    PM.saved = {}
    for i, c in ipairs(PM.orig) do local ok, v = pcall(function() return c:GetVisibility() end); PM.saved[i] = ok and v or 0 end
  end
  for i, c in ipairs(PM.orig) do
    pcall(function() c:SetVisibility(name and 1 or (PM.saved and PM.saved[i]) or 0) end)
  end
  if not name then PM.saved = nil end
  for pn, pg in pairs(PM.pages) do for _, e in ipairs(pg) do pcall(function() e.btn:SetVisibility(pn == name and 0 or 1) end) end end
  PM.page = name
  PM.lastMirrorVis, PM.lastMirrorEn = nil, nil
  refreshLabels()
  local first = name and PM.pages[name] and PM.pages[name][1] and PM.pages[name][1].btn or PM.coopBtn
  if first then focusBtn(first) end
end

local function onAnyButtonClicked(ctx)
  local id = wid(ctx:get())
  -- выход в меню / на рабочий стол / перезапуск точки: заранее убираем второй вид
  if (id:find("AreYouSure_LeaveGame") or id:find("AreYouSure_QuitGame") or id:find("AreYouSure_RestartCheckpoint"))
     and (id:find("btnYes") or id:find("btnOK")) then
    try("suspendCoop", suspendCoop, "выход из уровня")
  end
  for _, c in ipairs(PM.clicks) do
    if c.id == id then try("click", c.fn); return end
  end
end

-- Меню паузы: «Кооператив» перед «Выход в главное меню», образец — «Продолжить».
-- Главное меню: «Кооператив» после «Один игрок», образец — скрытая кнопка
-- «Купить полную версию» (того же вида, что кнопки паузы).
local function injectPause(w, kind)
  local root = w.WidgetTree.RootWidget
  local sb, resume
  local afterName
  if kind == "main" then
    sb = findPanelWithChild(root, "btn_Singleplayer")
    if sb then for _, c in ipairs(children(sb)) do if wfname(c) == "btn_TrialBuyGame" then resume = c end end end
    if not resume then
      -- запасной образец: внутренняя кнопка «Один игрок»
      pcall(function() local _, sp = findPanelWithChild(root, "btn_Singleplayer"); resume = sp.Button end)
    end
    afterName = "btn_Singleplayer"
  else
    sb, resume = findPanelWithChild(root, "btn_Resume")
  end
  if not (sb and valid(resume)) then log("меню (%s): список кнопок не найден", kind or "pause"); return end
  PM.widget, PM.sb, PM.template, PM.pages, PM.page, PM.clicks = w, sb, resume, {}, nil, {}
  PM.orig = children(sb)
  if not PM.hookOk then
    local ok = pcall(function() RegisterHook(BTN_CLICK_FN, onAnyButtonClicked) end)
    PM.hookOk = ok
    log(ok and "меню паузы: нажатия кнопок подключены" or "меню паузы: не удалось подключить нажатия")
  end
  -- «Кооператив» вставляем перед «Выход в главное меню» (в паузе) или
  -- после «Один игрок» (в главном меню)
  local tail = {}
  local seenMain = false
  for _, c in ipairs(PM.orig) do
    local n = wfname(c)
    if afterName then
      if seenMain then tail[#tail + 1] = c end
      if n == afterName then seenMain = true end
    else
      if n == "btn_MainMenu" then seenMain = true end
      if seenMain then tail[#tail + 1] = c end
    end
  end
  PM.mirror, PM.lastMirrorVis, PM.lastMirrorEn = tail[1] or (kind ~= "main" and resume or nil), nil, nil
  -- сначала создаём кнопку; трогаем список игры, только если она точно есть
  PM.coopBtn = makeBtn(resume, w, "Кооператив", function() showPage("coop") end)
  local okIns, errIns = pcall(function()
    for _, c in ipairs(tail) do sb:RemoveChild(c) end
    copySlot(sb:AddChild(PM.coopBtn), resume)
  end)
  -- кнопки игры возвращаем в любом случае
  for _, c in ipairs(tail) do
    local present = false
    for _, k in ipairs(children(sb)) do if wid(k) == wid(c) then present = true end end
    if not present then local s2 = sb:AddChild(c); copySlot(s2, resume) end
  end
  if not okIns then error(errIns) end
  PM.orig[#PM.orig + 1] = PM.coopBtn
  -- образец в главном меню скрыт игрой — наша кнопка должна быть видна
  if kind == "main" then pcall(function() PM.coopBtn:SetVisibility(0) end) end
  PM.kind = kind or "pause"
  log(kind == "main" and "главное меню: пункт «Кооператив» добавлен" or "меню паузы: пункт «Кооператив» добавлен")
end

-- Разовый разбор экранов игры (главное меню, настройки, пауза): какие там
-- окна, кнопки и надписи на текущем языке. Нужен, чтобы встроить пункт
-- «Кооператив» в главное меню и брать слова для меню мода у самой игры.
-- Пишется в ue4ss/Mods/LN3Couch/ui_dump.txt; включается ui_dump = true.
S.uiSeen = {}
S.uiText = function(w)
  local t = nil
  for _, f in ipairs({ "GetText" }) do
    pcall(function() local r = w[f](w); if r then t = type(r) == "string" and r or r:ToString() end end)
  end
  if not t then
    for _, prop in ipairs({ "ButtonText", "LocalisedString", "Text" }) do
      pcall(function() local r = w[prop]; if r and not t then t = type(r) == "string" and r or r:ToString() end end)
      if t then break end
    end
  end
  if t and t ~= "" then return (t:gsub("\n", "\\n")) end
end
S.uiTree = function(f, w, depth)
  if depth > 24 or not valid(w) then return end
  local cls = ""; pcall(function() cls = w:GetClass():GetFName():ToString() end)
  local line = string.rep("  ", depth) .. wfname(w) .. " [" .. cls .. "]"
  local t = S.uiText(w); if t then line = line .. " = «" .. t .. "»" end
  local vis = nil; pcall(function() vis = w:GetVisibility() end)
  if vis and vis ~= 0 and vis ~= 3 and vis ~= 4 then line = line .. " (скрыт)" end
  f:write(line, "\n")
  -- вложенное окно со своим деревом
  local okt, root = pcall(function() return w.WidgetTree.RootWidget end)
  if okt and valid(root) and depth > 0 then S.uiTree(f, root, depth + 1) end
  for _, c in ipairs(children(w)) do S.uiTree(f, c, depth + 1) end
  local okc, content = pcall(function() return w:GetContent() end)
  if okc and valid(content) and #children(w) == 0 then S.uiTree(f, content, depth + 1) end
end
S.uiDumpTick = function()
  if CFG.ui_dump ~= true or S.frames % 60 ~= 30 then return end
  -- 1) все надписи игры, какие сейчас существуют, с путём до них
  local nNew = 0
  local f = nil
  for _, cls in ipairs({ "TextBlock", "RichTextBlock" }) do
    for _, tb in ipairs(FindAllOf(cls) or {}) do
      if valid(tb) then
        local full = wid(tb)
        local path = full:gsub("^%S+%s+", ""):gsub("_%d%d%d%d+", "")
        local t = S.uiText(tb)
        if t and not path:find("^/Engine/Transient%.GameEngine:BP_KosmosGameInstance_C%.ResolutionScalarWidget_C%.WidgetTree%.SplashBNEE") then
          local key = path .. "=" .. t
          if not S.uiSeen[key] then
            S.uiSeen[key] = true
            f = f or io.open("ue4ss/Mods/LN3Couch/ui_texts.txt", "a")
            if f then f:write(path, " = «", t, "»\n"); nNew = nNew + 1 end
          end
        end
      end
    end
  end
  if f then f:close() end
  -- 2) устройство окон: каждое видимое окно игры (и вложенные)
  for _, w in ipairs(FindAllOf("UserWidget") or {}) do
    local okv, vis = pcall(function() return w:IsVisible() end)
    if valid(w) and okv and vis then
      local cls = ""; pcall(function() cls = w:GetClass():GetFName():ToString() end)
      local n = S.uiSeen["#" .. cls] or 0
      if n < 2 then
        local sig = {}
        local function collect(x, d)
          if d > 20 or not valid(x) then return end
          sig[#sig + 1] = wfname(x)
          local t = S.uiText(x); if t then sig[#sig + 1] = t end
          local okt, root = pcall(function() return x.WidgetTree.RootWidget end)
          if okt and valid(root) and d > 0 then collect(root, d + 1) end
          for _, c in ipairs(children(x)) do collect(c, d + 1) end
        end
        pcall(function() collect(w.WidgetTree.RootWidget, 0) end)
        local key = cls .. "|" .. table.concat(sig, "|")
        if not S.uiSeen[key] then
          S.uiSeen[key] = true; S.uiSeen["#" .. cls] = n + 1
          local g = io.open("ue4ss/Mods/LN3Couch/ui_dump.txt", "a")
          if g then
            g:write("\n=== ", cls, "   ", wid(w), "   язык: ", tostring(S.lang or "?"), "\n")
            pcall(function() S.uiTree(g, w.WidgetTree.RootWidget, 0) end)
            g:close()
          end
        end
      end
    end
  end
end
local pauseOpenCache, pauseOpenAt = false, -100
function lastPauseOpen()
  if S.frames - pauseOpenAt >= 15 then
    pauseOpenAt = S.frames; pauseOpenCache = false
    for _, w in ipairs(FindAllOf("PauseMenuWidget_C") or {}) do
      local ok, v = pcall(function() return w:IsVisible() end)
      if valid(w) and ok and v then pauseOpenCache = true end
    end
  end
  return pauseOpenCache
end
local injected = {}      -- меню паузы, в которые уже вставили пункт (по имени объекта)
local injectFailures = 0
local function coopLabelRefresh()
  if valid(PM.coopBtn) then setBtnText(PM.coopBtn, "Кооператив") end
  refreshLabels()
end
-- Наш пункт повторяет видимость соседней кнопки игры: когда игра прячет кнопки
-- паузы (например, показывает вопрос «Да/Нет»), прячется и «Кооператив».
local function mirrorVisibility()
  if PM.page or not (valid(PM.coopBtn) and valid(PM.mirror)) then return end
  local ok, v = pcall(function() return PM.mirror:GetVisibility() end)
  if ok and v ~= PM.lastMirrorVis then
    PM.lastMirrorVis = v
    pcall(function() PM.coopBtn:SetVisibility(v) end)
  end
  local oke, en = pcall(function() return PM.mirror:GetIsEnabled() end)
  if oke and en ~= PM.lastMirrorEn then
    PM.lastMirrorEn = en
    pcall(function() PM.coopBtn:SetIsEnabled(en) end)
  end
end

local function pauseTick()
  try("mirror", mirrorVisibility)
  if S.frames % 15 ~= 0 or injectFailures >= 3 then return end
  local target, kind = nil, nil
  for _, m in ipairs({ { "PauseMenuWidget_C", "pause" }, { "MainMenuWidget_C", "main" } }) do
    for _, w in ipairs(FindAllOf(m[1]) or {}) do
      local okv, vis = pcall(function() return w:IsVisible() end)
      if valid(w) and okv and vis then
        local id = wid(w)
        if injected[id] then
          if PM.widget and wid(PM.widget) == id then try("labels", coopLabelRefresh) end
        else
          target, kind = w, m[2]
        end
      end
    end
  end
  if target then
    injected[wid(target)] = true   -- помечаем сразу: вставляем не больше одного раза
    if not valid(S.pc1) then S.pc1 = findPC1() end
    local ok = try("injectPause", injectPause, target, kind)
    if not ok then injectFailures = injectFailures + 1 end
  end
end

-- Назначение клавиш во время паузы: игра в паузе может не передавать клавиши
-- игроку, поэтому дополнительно слушаем клавиатуру напрямую.
local OS_KEYS = {
  UP_ARROW = "Up", DOWN_ARROW = "Down", LEFT_ARROW = "Left", RIGHT_ARROW = "Right",
  RETURN = "Enter", SPACE = "SpaceBar", TAB = "Tab", HOME = "Home", END = "End", PAGE_UP = "PageUp", PAGE_DOWN = "PageDown",
  INS = "Insert", DEL = "Delete", BACKSPACE = "BackSpace",
  OEM_TWO = "Slash", OEM_PERIOD = "Period", OEM_COMMA = "Comma", OEM_ONE = "Semicolon", OEM_SEVEN = "Apostrophe",
  OEM_FOUR = "LeftBracket", OEM_SIX = "RightBracket", OEM_FIVE = "Backslash", OEM_MINUS = "Hyphen", OEM_PLUS = "Equals",
  MULTIPLY = "Multiply", ADD = "Add", SUBTRACT = "Subtract", DECIMAL = "Decimal", DIVIDE = "Divide",
}
for c in ("ABCDEFGHIJKLMNOPQRSTUVWXYZ"):gmatch(".") do OS_KEYS[c] = c end
for i, n in ipairs({ "ZERO","ONE","TWO","THREE","FOUR","FIVE","SIX","SEVEN","EIGHT","NINE" }) do
  local ue = ({ "Zero","One","Two","Three","Four","Five","Six","Seven","Eight","Nine" })[i]
  OS_KEYS[n] = ue; OS_KEYS["NUM_" .. n] = "NumPad" .. ue
end
for vk, ue in pairs(OS_KEYS) do
  if Key[vk] then pcall(function() RegisterKeyBind(Key[vk], function() if S.capture then PM.osKey = ue end end) end) end
end

local function captureTick()
  if not S.capture then return end
  S.capture.frames = (S.capture.frames or 0) + 1
  if S.capture.frames < 12 then PM.osKey = nil; return end -- не ловим Enter, которым выбрали пункт
  local k = PM.osKey
  if not k then
    local polled = anyCaptureDown()
    if not S.capture.armed then if not polled then S.capture.armed = true end
    else k = polled end
  end
  PM.osKey = nil
  if not k then return end
  if k == "BackSpace" then S.capture = nil; refreshLabels(); return end
  S.capture.tbl[S.capture.id] = k; S.capture = nil; saveSettings()
  refreshLabels()
  if not PM.page then toast("Назначено: " .. keyTitle(k)) end
end

------------------------------------------------------------------ главный цикл
local function Tick()
  TICKS = TICKS + 1
  S.frames = S.frames + 1
  if S.handsFree then pcall(S.handsFreeTick) end
  -- первые 10 с после загрузки уровня — отметки шагов (если игра упадёт,
  -- последняя отметка в trail.txt покажет, на каком шаге)
  local crumb = S.crumbUntil and S.frames < S.crumbUntil and S.frames % 30 == 0
  if crumb then trail("шаг: интерфейс") end
  try("updateUI", updateUI)
  if crumb then trail("шаг: возобновление") end
  try("resumeTick", resumeTick)
  if crumb then trail("шаг: меню паузы") end
  if S.detectPending and not lastPauseOpen() then S.detectPending = false; try("startDetect", startDetect) end
  if S.detect then try("detectTick", detectTick) end
  try("pauseTick", pauseTick)
  try("uiDump", S.uiDumpTick)
  if S.coop then
    if not S.evCam.cmdOk then pcall(S.evCam.hookCmds) end
    if S.frames % 300 == 120 then pcall(S.evCam.hookLevelEvents) end
    pcall(S.evCam.tick)
  end
  if S.frames % 60 == 45 then try("words", S.harvestWords) end
  if not S.menuOpen then try("captureTick", captureTick) end
  if S.menuOpen then
    if not valid(S.pc1) then S.pc1 = findPC1() end
    if valid(S.pc1) then try("menuInput", menuInput) end
    if S.coop then return end
  end
  if S.frames % 30 == 0 then
    local okw, wn = pcall(function() return UEHelpers.GetWorld():GetFullName() end)
    if okw then
      if S.worldName and wn ~= S.worldName and S.coop then try("suspendCoop", suspendCoop, "смена уровня") end
      if wn ~= S.worldName then S.crumbUntil = S.frames + 600 end
      S.worldName = wn
    end
  end
  -- запись анимаций героев (для разбора совместных действий) — только в
  -- кооперативе: на заставках некоторых глав игра даёт «анимацию», обращение
  -- к которой роняет загрузчик модов
  if S.coop and S.frames % 5 == 0 then
    pcall(function()
      S.animSeen = S.animSeen or {}
      S.animCur = S.animCur or {}
      for _, h in ipairs(S.heroList()) do
        local cls = cname(h)
        local okc, c = pcall(function() return h.Controller end)
        if valid(h) and okc and valid(c) then
          local okm, m = pcall(function() return h:GetCurrentMontage() end)
          local name = (okm and valid(m)) and m:GetFName():ToString() or nil
          local key = cls
          if name ~= S.animCur[key] then
            S.animCur[key] = name
            -- v9.15.5: у кого кукла — по подъёму и опусканию (в руках игра её
            -- не прикрепляет к герою, а «своей» числит и после того, как положили)
            if name and (h == S.p1 or h == S.buddy) then pcall(S.dollEvent, h, name) end
            if name and not S.animSeen[cls .. name] then
              S.animSeen[cls .. name] = true
              local full = ""; pcall(function() full = m:GetFullName() end)
              trail(string.format("анимация: %s (%s) → %s", heroName(h), clsName(c), full))
            end
          end
        end
      end
    end)
  end
  if not S.coop then return end
  if not (valid(S.pc1) and valid(S.p1) and valid(S.buddy) and buddyOwned()) then
    S.lostFrames = (S.lostFrames or 0) + 1
    if S.frames % 30 == 15 then pcall(S.rescueP1Hero) end
    if S.frames % 60 == 0 and acquire() then
      -- подсадка, прерванная смертью: ИИ-контроллер и камера игрока 1 остались
      -- в «режиме подсадки» — возвращаем всё как было
      pcall(S.roleRestore)
      if S.boost or S.cam1Frozen or S.cam1PawnHack then
        S.boost = nil
        try("ai tick off", function() S.ai:SetActorTickEnabled(false) end)
        S.cam1PawnHack, S.cam1PawnLost = false, nil
        pcall(S.freezeCam1, false)
        pcall(S.boostPassThrough, false)
        trail("подсадка: прервана смертью/возрождением — сбросил")
      end
      S.boost = nil
      S.camSnap = true; S.roomSm = nil; S.lastBuddyLoc = nil; RC.cur = nil; RC.pickAt = 0; S.camFrozenAt = nil
      pcall(function() setFastExposure(true) end); S.exposureResetAt = S.frames + 90
      log("персонажи найдены заново (смена уровня/возрождение)"); S.lastDump = nil; dumpHeroes("после возрождения"); S.lostFrames = 0
      -- v9.15.1: после смерти следим за камерой игрока 1 (жалоба: «после смерти камера слишком близко»)
      if S.deathSeenAt and S.frames - S.deathSeenAt < 1200 then S.respawnAt = S.frames end
      S.deathSeenAt = nil
      local okc, c = pcall(function() return S.buddy.Controller end)
      if okc and c == S.pc2 then S.real = true
      else
        S.real = false
        if wantReal() and usablePC2(S.pc2) and registryWorks() then takeBuddy() end
      end
    end
    -- героев долго нет (главное меню, загрузка) — убираем второй вид, чтобы не было половины экрана
    if S.lostFrames > 180 then
      local pc = findPC1()
      local p1ok = valid(pc) and isHero(pc.Pawn)
      if not p1ok then try("suspendCoop", suspendCoop, "герои пропали") end
    end
    return
  end
  S.lostFrames = 0
  -- игра иногда сама даёт напарнику команды (сценки, «подсади», «держи»).
  -- Прерываем их, только если игрок 2 сам хочет двигаться и напарник стоит
  -- на ногах — прерывание в середине сценки и роняло игру.
  -- Игра сама даёт напарнику команды (например, «помоги тащить», когда игрок 1
  -- хватает ящик). Напарником управляет игрок 2, поэтому такие команды сразу
  -- снимаем — кроме сценок, которые нельзя прерывать.
  if S.frames % 15 == 0 then keepListener() end
  if S.frames % 120 == 60 then pcall(S.ambienceTick) end
  if S.audioProbe and S.coop then pcall(S.audioProbeTick) end
  if S.coop and not S.boost and S.frames % 30 == 20 then pcall(S.fixItemOwners, "проверка"); if S.frames % 600 == 20 then pcall(S.snapshotItemOwners, "обновление") end end
  if S.frames % 60 == 30 then pcall(S.keepAnimating) end

  if S.frames % 120 == 0 then pcall(dedupeRegistry, "проверка") end
  if S.boost and S.boost.hero == S.buddy then
    try("boostInput", S.boostInput)
    updateSplit()
    if valid(S.pc2) then updateCam2() end
    return
  end
  if S.real then
    if not usablePC2(S.pc2) and S.frames % 120 == 0 then ensurePC2() end
    applyInputReal()
    updateSplit()
    if valid(S.pc2) then updateCam2() end
    return
  end
  if S.frames % 6 == 0 and not S.cmd and not S.drag and not S.cbox and valid(S.ai) and buddySteady() then
    local ok, gc = pcall(function() return S.ai:GetAiCommand() end)
    if ok and valid(gc) then
      local cn = cname(gc):gsub("^U", "")
      if not GAME_CMD_KEEP[cn] then
        S.seenCmd = S.seenCmd or {}
        if not S.seenCmd[cn] then S.seenCmd[cn] = true; log("снимаю команду игры напарнику: %s", cn) end
        try("StopAllAICommands", function() S.ai:StopAllAICommands() end)
        try("reset grab", function() S.buddy:AI_SetRawPressedInteract(S.prev.grab == true) end)
      elseif not (S.seenKeep or {})[cn] then
        S.seenKeep = S.seenKeep or {}; S.seenKeep[cn] = true; log("сценка напарника, не прерываю: %s", cn)
      end
    end
  end
  if not usablePC2(S.pc2) and S.frames % 120 == 0 then ensurePC2() end
  if S.frames % 120 == 0 and valid(S.pc2) then
    local okp, pawn = pcall(function() return S.pc2.Pawn end)
    if okp and valid(pawn) then
      log("ВНИМАНИЕ: вид игрока 2 снова получил героя %s", cname(pawn))
    end
  end
  try("throwCheck", throwCheckTick)
  applyInput()
  updateSplit()
  if valid(S.pc2) then updateCam2() end
end

if LoopInGameThreadWithDelay then
  LoopInGameThreadWithDelay(16, function() try("Tick", Tick) end)
else
  LoopAsync(16, function() ExecuteInGameThread(function() try("Tick", Tick) end); return false end)
end


-- F8: «метка» — записать в trail.txt, что сейчас с камерой и врагами
pcall(function() RegisterKeyBind(Key.F8, function() S.markReq = true end) end)
local last = -1000
RegisterKeyBind(Key.F9, function()
  local t = TICKS; if t - last < 20 then return end; last = t
  ExecuteInGameThread(function() try("toggleMenu", toggleMenu) end)
end)
-- F7: разведка для пункта в меню паузы — какие окна игры сейчас видны и из чего состоят
local function wname(w)
  local ok, c = pcall(function() return w:GetClass():GetFName():ToString() end)
  local ok2, n = pcall(function() return w:GetFName():ToString() end)
  return (ok and c or "?") .. " '" .. (ok2 and n or "?") .. "'"
end
local function wtext(w)
  local ok, t = pcall(function() return w:GetText():ToString() end)
  if ok and t and t ~= "" then return "  «" .. t .. "»" end
  return ""
end
local function dumpTree(w, depth, out)
  if depth > 9 or #out > 400 then return end
  out[#out + 1] = string.rep("  ", depth) .. wname(w) .. wtext(w)
  local okc, n = pcall(function() return w:GetChildrenCount() end)
  if okc and type(n) == "number" then
    for i = 0, n - 1 do
      local okg, ch = pcall(function() return w:GetChildAt(i) end)
      if okg and valid(ch) then dumpTree(ch, depth + 1, out) end
    end
  end
  -- содержимое вложенного пользовательского виджета
  local okt, tree = pcall(function() return w.WidgetTree end)
  if okt and valid(tree) then
    local okr, root = pcall(function() return tree.RootWidget end)
    if okr and valid(root) then dumpTree(root, depth + 1, out) end
  end
end
log("v9.15.9 загружен. F9 — меню кооператива")
