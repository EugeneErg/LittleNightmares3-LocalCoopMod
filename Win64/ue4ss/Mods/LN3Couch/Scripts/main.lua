-- LN3Couch v9.8.2 — игра вдвоём на одном ПК для Little Nightmares III
-- F9 — меню кооператива (всё включается и настраивается там)
local UEHelpers = require("UEHelpers")

------------------------------------------------------------------ утилиты
-- «след» действий: короткий файл, который пишется сразу на диск, чтобы
-- после вылета было видно, что мод делал последним
local TRAIL = { f = nil, n = 0 }
local function trail(line)
  if not TRAIL.f then TRAIL.f = io.open("ue4ss/Mods/LN3Couch/trail.txt", "w") end
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
    local keys = {}; for k in pairs(v) do keys[#keys + 1] = k end; table.sort(keys)
    local out = { "{\n" }
    for _, k in ipairs(keys) do out[#out + 1] = string.format("%s  %s = %s,\n", ind, k, serialize(v[k], ind .. "  ")) end
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
    local fn = load(src, "settings", "t", {})
    local ok2, saved = pcall(fn or function() end)
    if ok2 and type(saved) == "table" then merge(CFG, saved); log("сохранённые настройки загружены") end
  end
end

local function saveSettings()
  local f, err = io.open(SAVE_PATH, "w")
  if not f then log("не удалось сохранить настройки: %s", tostring(err)); return end
  f:write("-- настройки LN3Couch, сохранены из меню игры\nreturn " .. serialize(CFG) .. "\n"); f:close()
end
loadSettings()
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
local function now() return TICKS / 60 end
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
local function isHero(p) if not valid(p) then return false end local c = p:GetClass():GetFName():ToString(); return c == "BP_Low_C" or c == "BP_Alone_C" end
local function heroName(p) if not valid(p) then return "?" end local c = p:GetClass():GetFName():ToString(); return c == "BP_Low_C" and "Low" or "Alone" end
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
S.layoutLR = function()
  if CFG.split_layout_force == "left_right" then return true end
  if CFG.split_layout_force == "top_bottom" or CFG.split_sides == "top_bottom" then return false end
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

local function ensurePC2()
  if usablePC2(S.pc2) then return true end
  S.pc2 = nil
  local existing
  for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
    if valid(pc) and pc ~= S.pc1 and isLocalPC(pc) then existing = pc end
  end
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
    -- в какую сторону от камеры смещается зона героя — в ту же едет камера
    local wx, wy = tx * pe.X, ty * pe.Y
    local gx = wx * math.cos(pyaw) - wy * math.sin(pyaw)
    local gy = wx * math.sin(pyaw) + wy * math.cos(pyaw)
    local clx, cly = gx * math.cos(cvyaw) + gy * math.sin(cvyaw), -gx * math.sin(cvyaw) + gy * math.cos(cvyaw)
    local nx, ny = clamp(clx / math.max(pe.X, pe.Y, 1), -1, 1), clamp(cly / math.max(pe.X, pe.Y, 1), -1, 1)
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
  if S.frames >= RC.pickAt then
    RC.pickAt = S.frames + 10
    local a = pickRoomCam(p)
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
  local ok, loc, rot, fov = pcall(roomCamPose, RC.cur, p)
  if not ok then
    if not RC.errLogged then RC.errLogged = true; log("комнатная камера: ошибка %s", tostring(loc)) end
    return nil
  end
  if dist(loc, p) > 5000 then return nil end
  return loc, rot, fov
end
updateCam2Pose = function()
  if not (valid(S.cam2) and valid(S.pc1) and valid(S.p1) and valid(S.buddy)) then return end
  -- герой «перенёсся» (смерть, чекпоинт) — камеру ставим сразу, без проезда
  local frozen = false
  pcall(function()
    local bl = S.buddy:K2_GetActorLocation()
    local hidden = false; pcall(function() hidden = S.buddy:IsHidden() end)
    if S.camFrozenAt and S.frames - S.camFrozenAt < 180 and (hidden or (S.lastBuddyLoc and dist(bl, S.lastBuddyLoc) > 300)) then
      frozen = true
    elseif hidden or (S.lastBuddyLoc and dist(bl, S.lastBuddyLoc) > 1500) then
      -- герой исчез или «улетел» (смерть) — камера остаётся на его последнем месте
      S.camFrozenAt = S.frames; frozen = true
      trail("вторая камера: герой исчез — держу последнее место")
    else
      if S.lastBuddyLoc and dist(bl, S.lastBuddyLoc) > 500 then S.camSnap = true; RC.pickAt = 0 end
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
      S.cam2:K2_SetActorLocationAndRotation({ X = rs.x, Y = rs.y, Z = rs.z }, { Pitch = rs.pitch + S.p2ly * 10, Yaw = rs.yaw + S.p2lx * 15, Roll = 0 }, false, {}, false)
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
    local loc = { X = sm.bx + sm.dx, Y = sm.by + sm.dy, Z = sm.bz + sm.dz }
    S.cam2:K2_SetActorLocationAndRotation(loc, { Pitch = sm.pitch + S.p2ly * 12, Yaw = sm.yaw + S.p2lx * 22, Roll = b.roll }, false, {}, false)
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
      local d = dist(S.cam2:K2_GetActorLocation(), S.buddy:K2_GetActorLocation())
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
local function buddyScreenPos()
  local ok, res = pcall(function()
    if not valid(VIS_LIB) then VIS_LIB = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary") end
    local lib = VIS_LIB
    local vs = lib:GetViewportSize(S.pc1)
    local W, H = vs.X, vs.Y
    if not (W and H and W > 0 and H > 0) then return nil end
    if S.split then
      if S.layoutLR() then W = W / 2 else H = H / 2 end
    end
    local loc = S.buddy:K2_GetActorLocation()
    local out = {}
    local onScr = S.pc1:ProjectWorldLocationToScreen({ X = loc.X, Y = loc.Y, Z = loc.Z }, out, true)
    local x = out.X or (out[1] and out[1].X)
    local y = out.Y or (out[1] and out[1].Y)
    if not projLogged then projLogged = true; log("проверка видимости: экран %dx%d, напарник %s (%s, %s)", W, H, tostring(onScr), tostring(x), tostring(y)) end
    if not onScr or not x or not y then return { inFront = false } end
    return { inFront = true, x = x / W, y = y / H }
  end)
  if ok then return res end
  if not projLogged then projLogged = true; log("проверка видимости не удалась: %s", tostring(res)) end
  return nil
end

local VIS = { hiddenFor = 0, shownFor = 0, fallback = false }
local function insideBox(p, m) return p and p.inFront and p.x > m and p.x < 1 - m and p.y > m and p.y < 1 - m end

local function wantSplit()
  local mode = CFG.split
  if mode == "always" then return true end
  if mode == "never" then return false end
  if mode == "auto" and not VIS.fallback then
    -- в какой «комнате» (зоне камеры игры) каждый герой
    if S.frames % 10 == 0 then
      pcall(function()
        S.roomP1 = pickRoomCam(S.p1:K2_GetActorLocation())
        S.roomP2 = pickRoomCam(S.buddy:K2_GetActorLocation())
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
      local q = p
      if p and p.inFront then
        if S.layoutLR() then q = { inFront = true, x = p.x, y = 0.5 + (p.y - 0.5) * 2 }
        else q = { inFront = true, x = 0.5 + (p.x - 0.5) * 2, y = p.y } end
      end
      -- объединяем, когда герои в одной комнате и напарник уверенно в кадре,
      -- или когда они просто стоят рядом (тогда комнаты не важны)
      local close, dh, dz = false, 99999, 0
      pcall(function()
        local a, b = S.p1:K2_GetActorLocation(), S.buddy:K2_GetActorLocation()
        dh = math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2); dz = math.abs(a.Z - b.Z)
        close = dh < (CFG.merge_distance or 450) and dz < 200
      end)
      -- в разных комнатах экран всегда разделён, как бы близко герои ни стояли
      if diffRooms or (VIS.sameFor or 0) < 20 then VIS.shownFor = 0
      elseif close then VIS.shownFor = VIS.shownFor + 2
      elseif insideBox(q, 0.05) then VIS.shownFor = VIS.shownFor + 1
      else VIS.shownFor = math.max(0, VIS.shownFor - 2) end     -- короткие «выпадения» не сбрасывают счёт
      if dh < 900 and (not VIS.mlogAt or S.frames - VIS.mlogAt > 120) then
        VIS.mlogAt = S.frames
        trail(string.format("экран: рядом (%.0f см), напарник в кадре=%s (%.2f, %.2f), разные комнаты=%s, счёт=%d",
          dh, tostring(insideBox(q, 0.05)), q and q.x or -1, q and q.y or -1, tostring(diffRooms), VIS.shownFor))
      end
      if now() - S.splitChangedAt < 1.0 then return true end   -- разделённым держим минимум 1 с
      return VIS.shownFor < 15           -- ~0,25 с
    else
      if insideBox(p, 0.04) then VIS.hiddenFor = 0 else VIS.hiddenFor = VIS.hiddenFor + 1 end
      -- делим, если напарник ушёл из кадра или в другую комнату
      return VIS.hiddenFor >= 20 or VIS.diffFor >= 20
    end
  end
  local ok, d = pcall(function() return S.p1:GetDistanceTo(S.buddy) end)
  if not ok then return S.split end
  local on, off = CFG.split_on_distance, CFG.split_on_distance * 0.66
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
    local function sp(h) local out = {}; local on = S.pc1:ProjectWorldLocationToScreen(h:K2_GetActorLocation(), out, true); return out.X, out.Y end
    local ax, ay = sp(S.p1); local bx, by = sp(S.buddy)
    if not (ax and ay and bx and by) then return end
    local dx, dy = bx - ax, by - ay          -- в пикселях: сравнимо по обеим осям
    S.splitLR = math.abs(dx) >= math.abs(dy)
    if CFG.split_sides == "top_bottom" then S.splitLR = false end
    S.p2First = S.splitLR and (dx < 0) or (not S.splitLR and dy < 0)
    trail(string.format("экран: второй %s первого (dx=%.0f, dy=%.0f) — делю %s, второй %s",
      S.splitLR and (dx < 0 and "левее" or "правее") or (dy < 0 and "выше" or "ниже"), dx, dy,
      S.splitLR and "слева/справа" or "сверху/снизу", S.p2First and (S.splitLR and "слева" or "сверху") or (S.splitLR and "справа" or "снизу")))
  end)
end
-- Без чёрных полос: камерам разрешаем подстраиваться под форму половины
-- экрана. Слева/справа сохраняется вертикальный обзор, сверху/снизу —
-- горизонтальный.
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
        lp.AspectRatioAxisConstraint = S.layoutLR() and 0 or 1   -- 0: держать вертикальный обзор, 1: горизонтальный
      elseif A.lp[key] ~= nil then
        lp.AspectRatioAxisConstraint = A.lp[key]; A.lp[key] = nil
      end
    end)
  end
  if on then
    for _, c in ipairs(FindAllOf("CameraComponent") or {}) do
      pcall(function()
        if valid(c) and c.bConstrainAspectRatio then
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
  if not usablePC2(S.pc2) then return end
  if S.exposureResetAt and S.frames >= S.exposureResetAt then S.exposureResetAt = nil; if not S.nativeCam then setFastExposure(false) end end
  -- камеры новых комнат, подгрузившихся при разделённом экране, — тоже без полос
  if S.split and S.frames % 120 == 0 then pcall(S.applySplitAspect, true) end
  local want = wantSplit()
  if want == S.split or now() - S.splitChangedAt < 1.0 then return end
  S.splitChangedAt = now()
  if want then
    if not S.nativeCam then
      S.camSnap = true; updateCam2Pose(); setFastExposure(true); S.exposureResetAt = S.frames + 120
      try("pc2 ViewTarget", function() S.pc2:SetViewTargetWithBlend(S.cam2, 0, 0, 0, false) end)
    end
  end
  VIS.hiddenFor, VIS.shownFor = 0, 0
  if want then pcall(S.decideSplitSides); pcall(S.setPlayerOrder, S.p2First) end
  setSplitVisible(want)
  pcall(S.applySplitAspect, want)
  if not want then S.splitLR, S.p2First = nil, false end
  log(want and "экран разделён" or "экран общий")
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
  for _, cls in ipairs({ "BP_Low_C", "BP_Alone_C" }) do
    for _, h in ipairs(FindAllOf(cls) or {}) do
      if valid(h) then
        local okc, c = pcall(function() return h.Controller end)
        out[#out + 1] = string.format("  герой %s %s управляет=%s", cls, h:GetFName():ToString(), okc and cname(c) or "?")
      end
    end
  end
  log("%s", table.concat(out, "\n"))
end
local function acquire()
  S.pc1 = findPC1(); if not valid(S.pc1) then dumpHeroes("не нашёл — нет игрока 1"); return false end
  S.p1 = S.pc1.Pawn; if not isHero(S.p1) then dumpHeroes("не нашёл — игрок 1 не герой: " .. cname(S.p1)); return false end
  local ai, buddy = findBuddy(S.p1)
  if not buddy then
    -- запасной путь: второй герой, которым управляет любой ИИ-контроллер
    for _, cls in ipairs({ "BP_Low_C", "BP_Alone_C" }) do
      for _, h in ipairs(FindAllOf(cls) or {}) do
        if valid(h) and h ~= S.p1 then
          local okc, c = pcall(function() return h.Controller end)
          if okc and valid(c) and c:IsA(StaticFindObject("/Script/AIModule.AIController")) then ai, buddy = c, h end
        end
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
  ["Игра будет вдвоём"] = "The game will be two-player", ["Игра будет на одного"] = "The game will be single-player",
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
  ["Разделение"] = "Split", ["Авто (как стоят герои)"] = "Auto (by where heroes are)", ["Всегда сверху/снизу"] = "Always top/bottom",
  ["Делить экран с расстояния"] = "Split at distance", ["Делить экран с"] = "Split at",
  ["Кнопки игрока 2  >"] = "Player 2 buttons  >", ["Кнопки игрока 2"] = "Player 2 buttons",
  ["Сбросить настройки"] = "Reset settings", ["Закрыть  (F9)"] = "Close  (F9)",
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
local function keepListener()
  if not valid(AUDIO.owner) then return end
  local o = listenerOwner()
  if o ~= AUDIO.owner then
    local lib = StaticFindObject("/Script/Kosmos.Default__KosmosAudioBlueprintLibrary")
    if valid(lib) then
      try("RegisterDefaultListener", function() lib:RegisterDefaultListener(S.pc1, AUDIO.owner) end)
      S.lastListenerFix = now()
      if not AUDIO.logged then AUDIO.logged = true; log("звук: игра переключила слушателя на %s — вернул на %s", cname(o), cname(AUDIO.owner)) end
      if ExecuteWithDelay then
        ExecuteWithDelay(300, function() ExecuteInGameThread(function() pcall(refreshAmbience) end) end)
      else pcall(refreshAmbience) end
    end
  end
end
-- Герои всегда считают свою анимацию, даже если их «не видно» в кадре
-- (иначе в разделённом экране герой мог скользить без анимации).
S.keepAnimating = function()
  for _, h in ipairs({ S.p1, S.buddy }) do
    if valid(h) then pcall(function() h.Mesh.VisibilityBasedAnimTickOption = 0 end) end
  end
end
local function takeBuddy()
  if not (valid(S.pc2) and valid(S.buddy)) then return false end
  -- ИИ-контроллер напарника после передачи героя остаётся «без тела». Если он
  -- продолжит работать, на ближайшем кадре он обратится к своему герою, а героя
  -- уже нет — игра падала. Поэтому сначала полностью его останавливаем.
  if valid(S.ai) then
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
  if on then
    applyGamepadRouting()
    S.frames = 0
    -- всё, что отсчитывается в кадрах, начинаем заново (иначе после
    -- возобновления подсадка «ждёт» паузу, оставшуюся с прошлого раза)
    S.boost, S.boostCooldown, S.pendingKill, S.localSwap = nil, nil, nil, nil
    S.enemy.listAt, S.enemy.killAt, S.enemy.bbAt, S.enemy.st, S.enemy.pos = -10000, -10000, {}, {}, {}
    if not acquire() then toast("Не нашёл двух героев — загрузите игру"); return end
    S.coop, S.split = true, false
    -- запоминаем мир, в котором включились: иначе проверка смены уровня,
    -- не успевшая заметить загрузку, сразу же приостановит кооператив
    pcall(function() S.worldName = UEHelpers.GetWorld():GetFullName() end)
    rememberListener()
    S.ambBase = S.ambienceState()
    if S.ambBase then trail(string.format("звук до кооператива: фон зоны=%s, общий фон=%s", tostring(S.ambBase.v), tostring(S.ambBase.g))) end
    ensurePC2()
    S.real = false
    if wantReal() then
      if registryWorks() then takeBuddy() else log("режим второго игрока недоступен — управляю через ИИ") end
    end
    toast("Игрок 2 подключён: " .. heroName(S.buddy))
    if CFG.device == "gamepad" and not CFG.p2_controller_confirmed then S.detectPending = true end
  else
    S.coop, S.resumeCoop, S.drag, S.cbox = false, false, nil, nil
    releaseBuddy()
    resetBuddyInput()
    if valid(S.ai) then setBrain(S.ai, true) end
    pcall(function() if valid(S.poi) then S.poi.mWeight = 0 end end)
    removePC2(); S.split = false
    toast("Напарником снова управляет ИИ")
  end
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
    if valid(pc) and id and pc ~= keep and isLocalPC(pc) then
      pcall(function() pc:UnPossess() end)
      pcall(function() UEHelpers.GetGameplayStatics():RemovePlayer(pc, false) end)
      log("убран лишний игрок (контроллер %d)", id)
    end
  end
  S.coop, S.split, S.resumeCoop, S.cmd, S.throwCheck, S.detect, S.drag, S.cbox = false, false, true, nil, nil, nil, nil, nil
  pcall(function() gms().bUseSplitscreen = false end)
end
if CFG.coop_enabled then S.resumeCoop = true end
local function resumeTick()
  if not S.resumeCoop or S.coop or S.frames % 60 ~= 0 then return end
  local pc = findPC1()
  if not (valid(pc) and isHero(pc.Pawn)) then return end
  if not findBuddy(pc.Pawn) then return end
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
    return runCmd("положить", function() return carryCmds():PlaypalCarriable_Putdown(S.buddy, false, { X = 0, Y = 0, Z = 0 }) end)
  end
  local c, d = nearestCarriable()
  if c then
    return runCmd(string.format("поднять (%.0f см)", d), function() return carryCmds():PlaypalCarriable_Pickup(S.buddy, c) end)
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
  runCmd("бросить", function() return carryCmds():PlaypalCarriable_Throw(S.buddy, sm, tm) end)
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
local function tryWeapon()
  local okp, l = pcall(function() return S.buddy:K2_GetActorLocation() end)
  local okf, fw = pcall(function() return S.buddy:GetActorForwardVector() end)
  if not (okp and okf) then return false end
  local isLow = heroName(S.buddy) == "Low"
  local dist = isLow and 1000 or 140
  local stand = { X = l.X, Y = l.Y, Z = l.Z }
  local target = { X = l.X + fw.X * dist, Y = l.Y + fw.Y * dist, Z = l.Z + (isLow and 40 or 0) }
  local sm, tm = placeMarker("weapStand", stand), placeMarker("weapTarget", target)
  if not (valid(sm) and valid(tm)) then return false end
  return runCmd(isLow and "выстрелить из лука" or "ударить ключом", function()
    return weaponCmds():PlaypalWeaponAttack(S.buddy, sm, stand, tm, target, false, 1, 60)
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
    return interactCmds():PlaypalFreeDraggable(S.buddy, S.drag.box, m, loc, 40)
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
    return interactCmds():PlaypalPushPull(S.buddy, c.box, target, 3)
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
S.boostEnd = function(reason)
  local b = S.boost; if not b then return end
  S.boost = nil
  S.boostCooldown = S.frames + 45   -- не переключать героя туда-обратно слишком часто
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
    pcall(function() cm:StopExternalOverTime(0.2, 0) end)
    pcall(function() cm:ResetViewOverTime(0.3, 0) end)
    pcall(function() cm:SetOverrideExternalCamera(false) end)
  end
end
S.applyCam1Freeze = function()
  if not (S.cam1Frozen and valid(S.cam1fix)) then return end
  local cm = S.pc1.PlayerCameraManager
  local ok1, e1 = pcall(function() cm:StopExternalOverTime(0, 0) end)
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
    -- первую секунду — каждый кадр (видно дрожание), потом раз в секунду
    if age < 60 or S.frames % 60 == 0 then
      pcall(function() trail(string.format("камера 1 при подсадке (%.2f с): %s", age / 60, S.cam1Info())) end)
    end
    return
  end
  -- место подсадки переключает камеру игрока на свою «камеру подсадки» —
  -- пока подсаживает игрок 1, не даём ей это сделать
  if S.frames % 5 == 0 then
    pcall(function() S.pc1.PlayerCameraManager:StopExternalOverTime(0, 0) end)
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
  if not (valid(S.ai) and valid(hero) and valid(owner)) then log("подсадка: нет ИИ-контроллера"); return false end
  pcall(function() trail("камера 1 перед подсадкой: " .. S.cam1Info()) end)
  pcall(function() trail("герои перед подсадкой: " .. S.killDiag()) end)
  if hero == S.p1 then pcall(S.freezeCam1, true) end
  pcall(dedupeRegistry, "перед подсадкой")
  try("ai tick on", function() S.ai:SetActorTickEnabled(true) end)
  if not safePossess(S.ai, hero, "подсадка: герой → ИИ") then
    try("ai tick off", function() S.ai:SetActorTickEnabled(false) end)
    return false
  end
  -- ИИ-контроллер запоминает «своего» героя; после смены героя обновляем
  pcall(function() S.ai.mCurrentCharacter = hero end)
  if hero == S.buddy then S.real = false
  else
    -- камера игрока 1 замирает на месте на время подсадки
    pcall(S.applyCam1Freeze)
  end
  S.boost = { hero = hero, owner = owner, spot = spot, startFrame = S.frames }
  pcall(S.boostPassThrough, true)
  local ok, action = try("PlaypalBoost", function() return interactCmds():PlaypalBoost(hero, spot) end)
  if ok and valid(action) then
    try("PlaypalBoost Activate", function() action:Activate() end)
    log("подсадка: %s подсаживает (%s)", heroName(hero), spot:GetFName():ToString())
    return true
  end
  S.boostEnd("команда не создалась")
  return false
end
S.RB = "Gamepad_RightTrigger"   -- та же кнопка, что «схватить / поднять предмет»
-- нажатия RB обоих игроков (фронт нажатия)
S.rbEdges = function()
  -- Курок читаем как «ось»: когда герой переходит к ИИ и обратно, игра
  -- сбрасывает «нажатые кнопки», и удержание курка как кнопки теряется.
  local function held(pc)
    return analog(pc, "Gamepad_RightTriggerAxis") > 0.35 or isDown(pc, S.RB)
  end
  local r1, r2 = held(S.pc1), held(p2Source())
  local e1, e2 = r1 and not S.prevRB1, r2 and not S.prevRB2
  S.prevRB1, S.prevRB2 = r1, r2
  return e1, e2
end
S.boostTick = function(e1, e2)
  local b = S.boost
  if not b.poseAt then
    pcall(function()
      local m = b.hero:GetCurrentMontage()
      if valid(m) and m:GetFName():ToString():find("GiveBoost") then
        b.poseAt = S.frames
        local hl, sl = b.hero:K2_GetActorLocation(), b.spot:K2_GetActorLocation()
        trail(string.format("подсадка: %s встал в позу через %.1f с (до места %.0f см)", heroName(b.hero), (S.frames - b.startFrame) / 60, dist(hl, sl)))
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
  local pc = (b.owner == S.pc1) and S.pc1 or p2Source()
  local v = analog(pc, "Gamepad_RightTriggerAxis")
  local bd = isDown(pc, S.RB)
  local held = true
  -- сразу после передачи героя ИИ игра «забывает» зажатый курок и шлёт 0;
  -- это не отпускание. Удержание засчитываем только после этого момента.
  if bd or v > 0.35 then if age > 5 then b.sawHeld = true end; b.lowFrames = 0
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
  -- во время сцены смерти подсадку не начинаем, а идущую — заканчиваем:
  -- иначе герой остаётся у ИИ, когда игра возрождает героев, и игра падает
  if S.frames % 6 == 0 then S.dyingNow = S.anyDying() end
  if S.dyingNow then
    if S.boost then S.boostEnd("сцена смерти") end
    S.boostCooldown = S.frames + 60
    return
  end
  if S.boost then S.boostTick(e1, e2) return end
  if S.boostCooldown and S.frames < S.boostCooldown then return end
  if e1 then
    local spot = S.nearestBoostTo(S.p1)
    if spot then S.boostStart(S.p1, S.pc1, spot) end
  elseif e2 then
    local spot = S.nearestBoostTo(S.buddy)
    if spot then S.boostStart(S.buddy, S.pc2, spot) end
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
  S.poi, S.poiOwner = c, S.buddy
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
S.midCamTick = function()
  if S.frames % 6 == 3 then S.dyingNow = S.anyDying() end
  if CFG.shared_center == false then return end
  local c = S.ensurePOI()
  if not c then return end
  -- на общем экране точка «тянет» камеру к середине; на разделённом — выключена
  local w = (not S.split and not S.cam1Frozen) and (CFG.shared_poi_weight or 0.5) or 0
  pcall(function() if math.abs((c.mWeight or 0) - w) > 0.001 then c.mWeight = w end end)
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
          local sensorFix = false
          local angleFix = false
          local zoneFix = ccn:find("ProximitySensor") and fname == "Run Attack Range"
          local idxParam = nil
          for i, n in ipairs(pnames) do if n == "PlayerIndex" or n == "Player Index" then idxParam = i end end
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
S.fixTarget = function(en)
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

local function applyInputReal()
  local _, _, lx, ly, p2jump, grab = readP2()
  pcall(S.midCamTick)
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
  if not S.boost and S.frames % 600 == 300 then pcall(function() trail("герои обычно: " .. S.killDiag()); trail("роли обычно: " .. S.roleDiag()); pcall(function() local gm = UEHelpers.GetGameModeBase(); trail(string.format("режим игры: одиночная=%s, игроков=%s", tostring(gm:IsSinglePlayerGame()), tostring(gm.NumPlayers))) end) end) end
  if S.markReq then
    S.markReq = false
    pcall(function()
      trail("===== МЕТКА (F8) =====")
      trail("подсадка: " .. (S.boost and string.format("идёт, подсаживает %s, %.1f с", heroName(S.boost.hero), (S.frames - S.boost.startFrame) / 60) or "нет"))
      trail("камера 1: " .. S.cam1Info())
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
    if runCmd(want and "достать оружие" or "убрать оружие", function() return weaponCmds():PlaypalWeaponShowHide(S.buddy, want) end) then
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
          runCmd("положить", function() return carryCmds():PlaypalCarriable_Putdown(S.buddy, false, { X = 0, Y = 0, Z = 0 }) end)
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
      if c and runCmd(string.format("поднять (%.0f см)", d), function() return carryCmds():PlaypalCarriable_Pickup(S.buddy, c) end) then
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

S.SPLIT_SIDES = { { "auto", "Авто (как стоят герои)" }, { "top_bottom", "Всегда сверху/снизу" } }
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
      { label = function() return "Экран" end, value = function() return optTitle(SPLIT_MODES, CFG.split) end,
        left = function() CFG.split = optCycle(SPLIT_MODES, CFG.split, -1); changed() end,
        right = function() CFG.split = optCycle(SPLIT_MODES, CFG.split, 1); changed() end },
      { label = function() return "Разделение" end, value = function() return optTitle(S.SPLIT_SIDES, CFG.split_sides or "auto") end,
        left = function() CFG.split_sides = optCycle(S.SPLIT_SIDES, CFG.split_sides or "auto", -1); changed() end,
        right = function() CFG.split_sides = optCycle(S.SPLIT_SIDES, CFG.split_sides or "auto", 1); changed() end },
      { label = function() return "Делить экран с расстояния" end, value = function() return string.format("%d м", math.floor(CFG.split_on_distance / 100 + 0.5)) end,
        left = function() CFG.split_on_distance = math.max(300, CFG.split_on_distance - 100); changed() end,
        right = function() CFG.split_on_distance = math.min(3000, CFG.split_on_distance + 100); changed() end },
      { label = function() return "Кнопки игрока 2  >" end, value = function() return "" end,
        act = function() S.menu, S.sel = buildMenu("keys"), 1 end },
      { label = function() return "Сбросить настройки" end, value = function() return "" end,
        act = function() CFG = deepcopy(DEFAULTS); applyLayout(); changed(); toast("Настройки сброшены") end },
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
    { function() return "Экран: " .. optTitle(SPLIT_MODES, CFG.split) end,
      function() CFG.split = optCycle(SPLIT_MODES, CFG.split, 1); saveSettings() end },
    { function() return "Разделение: " .. optTitle(S.SPLIT_SIDES, CFG.split_sides or "auto") end,
      function() CFG.split_sides = optCycle(S.SPLIT_SIDES, CFG.split_sides or "auto", 1); saveSettings() end },
    { function() return string.format("Делить экран с: %d м", math.floor(CFG.split_on_distance / 100 + 0.5)) end,
      function() CFG.split_on_distance = CFG.split_on_distance + 300; if CFG.split_on_distance > 3000 then CFG.split_on_distance = 300 end; saveSettings() end },
    { function() return "Кнопки игрока 2" end, function() showPage("keys") end },
    { function() return "Сбросить настройки" end, function() CFG = deepcopy(DEFAULTS); applyLayout(); saveSettings(); PM.rebuildKeys = true end },
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
  pcall(S.dumpStrings)
end

-- Разовый разбор экранов игры (главное меню, настройки, пауза): какие там
-- окна, кнопки и надписи на текущем языке. Нужен, чтобы встроить пункт
-- «Кооператив» в главное меню и брать слова для меню мода у самой игры.
-- Пишется в ue4ss/Mods/LN3Couch/ui_dump.txt; выключается ui_dump = false.
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
  if CFG.ui_dump == false or S.frames % 60 ~= 30 then return end
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
      for _, cls in ipairs({ "BP_Low_C", "BP_Alone_C" }) do
        for _, h in ipairs(FindAllOf(cls) or {}) do
          local okc, c = pcall(function() return h.Controller end)
          if valid(h) and okc and valid(c) then
            local okm, m = pcall(function() return h:GetCurrentMontage() end)
            local name = (okm and valid(m)) and m:GetFName():ToString() or nil
            local key = cls
            if name ~= S.animCur[key] then
              S.animCur[key] = name
              if name and not S.animSeen[cls .. name] then
                S.animSeen[cls .. name] = true
                local full = ""; pcall(function() full = m:GetFullName() end)
                trail(string.format("анимация: %s (%s) → %s", cls == "BP_Low_C" and "Low" or "Alone", clsName(c), full))
              end
            end
          end
        end
      end
    end)
  end
  if not S.coop then return end
  if not (valid(S.pc1) and valid(S.p1) and valid(S.buddy) and buddyOwned()) then
    S.lostFrames = (S.lostFrames or 0) + 1
    if S.frames % 60 == 0 and acquire() then
      -- подсадка, прерванная смертью: ИИ-контроллер и камера игрока 1 остались
      -- в «режиме подсадки» — возвращаем всё как было
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
  if S.frames % 120 == 30 then pcall(S.keepAnimating) end

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
log("v9.8.2 загружен. F9 — меню кооператива")
