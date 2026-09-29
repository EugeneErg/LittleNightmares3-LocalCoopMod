-- LN3Couch v1.4 — игра вдвоём на одном ПК для Little Nightmares III
-- F9 — меню кооператива (всё включается и настраивается там)
local UEHelpers = require("UEHelpers")

------------------------------------------------------------------ утилиты
local function log(fmt, ...) print(string.format("[LN3Couch] " .. fmt .. "\n", ...)) end
local function valid(o)
  if o == nil or type(o) ~= "userdata" then return false end
  local ok, r = pcall(function() return o:IsValid() end); return ok and r == true
end
local function nm(o) if valid(o) then return o:GetFullName() end return "nil" end
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
local function now() return TICKS / 60 end -- «секунды» по нашему циклу (~60 раз в секунду)

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
    return ly, lx, analog(src, "Gamepad_RightX"), analog(src, "Gamepad_RightY"),
           isDown(src, g.jump), isDown(src, g.grab), isDown(src, g.crouch), isDown(src, g.sprint)
  end
  local k, pc = CFG.keyboard, S.pc1
  local f = (isDown(pc, k.up) and 1 or 0) - (isDown(pc, k.down) and 1 or 0)
  local r = (isDown(pc, k.right) and 1 or 0) - (isDown(pc, k.left) and 1 or 0)
  return f, r, 0, 0, isDown(pc, k.jump), isDown(pc, k.grab), isDown(pc, k.crouch), isDown(pc, k.sprint)
end

------------------------------------------------------------------ персонажи
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

------------------------------------------------------------------ второй вид и камера
local function gms() return UEHelpers.GetGameMapsSettings() end
local function applyLayout()
  try("layout", function()
    local g = gms()
    g.bUseSplitscreen = true
    g.TwoPlayerSplitscreenLayout = (CFG.split_layout == "left_right") and 1 or 0
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
  try("cdo swap", function()
    cdo = S.pc1:GetClass():GetCDO()
    oldCam = cdo.PlayerCameraManagerClass
    local vanilla = StaticFindObject("/Script/Engine.PlayerCameraManager")
    if valid(vanilla) then cdo.PlayerCameraManagerClass = vanilla end
  end)
  gm = UEHelpers.GetGameModeBase()
  if valid(gm) then try("spec flag", function() oldSpec = gm.bStartPlayersAsSpectators; gm.bStartPlayersAsSpectators = true end) end
  local ok, pc = try("CreatePlayer", function() return UEHelpers.GetGameplayStatics():CreatePlayer(S.pc1, 1, true) end)
  if cdo and oldCam then try("cdo restore", function() cdo.PlayerCameraManagerClass = oldCam end) end
  if valid(gm) and oldSpec ~= nil then try("spec restore", function() gm.bStartPlayersAsSpectators = oldSpec end) end
  if ok then return pc end
end

local function ensurePC2()
  if usablePC2(S.pc2) then return true end
  S.pc2 = nil
  local existing = findPC(1)
  S.pc2 = usablePC2(existing) and existing or createPC2()
  if not usablePC2(S.pc2) then log("не удалось создать вид для игрока 2"); S.pc2 = nil; return false end
  local stolen = S.pc2.Pawn
  if valid(stolen) then
    log("вид игрока 2 захватил %s — возвращаю", heroName(stolen))
    try("pc2 UnPossess", function() S.pc2:UnPossess() end)
    if stolen == S.p1 then try("pc1 Possess", function() S.pc1:Possess(S.p1) end) end
    if stolen == S.buddy and valid(S.ai) then try("ai Possess", function() S.ai:Possess(S.buddy) end); setBrain(S.ai, false) end
  end
  if not valid(S.cam2) then S.cam2 = spawnCam() end
  if valid(S.cam2) then updateCam2Pose(); applyCam() else log("камеру для игрока 2 создать не удалось") end
  S.camCheckAt = S.frames + 30
  S.camOkLogged = false
  S.lp2 = S.pc2.Player
  S.split = true
  setSplitVisible(false)
  return true
end

local function removePC2()
  if valid(S.lp2) and valid(S.pc2) then try("reattach", function() S.lp2.PlayerController = S.pc2 end) end
  try("split off", function() gms().bUseSplitscreen = false end)
  S.split, S.lp2 = false, nil
  if valid(S.pc2) then
    try("pc2 UnPossess", function() S.pc2:UnPossess() end)
    try("RemovePlayer", function() UEHelpers.GetGameplayStatics():RemovePlayer(S.pc2, true) end)
  end
  S.pc2 = nil
  if valid(S.cam2) then try("cam destroy", function() S.cam2:K2_DestroyActor() end) end
  S.cam2 = nil
end

updateCam2Pose = function()
  if not (valid(S.cam2) and valid(S.pc1) and valid(S.p1) and valid(S.buddy)) then return end
  try("cam2 update", function()
    local cm1 = S.pc1.PlayerCameraManager
    local l1, r1 = cm1:GetCameraLocation(), cm1:GetCameraRotation()
    local p1l, bl = S.p1:K2_GetActorLocation(), S.buddy:K2_GetActorLocation()
    local loc = { X = bl.X + (l1.X - p1l.X), Y = bl.Y + (l1.Y - p1l.Y), Z = bl.Z + (l1.Z - p1l.Z) }
    S.cam2:K2_SetActorLocationAndRotation(loc, { Pitch = r1.Pitch, Yaw = r1.Yaw, Roll = r1.Roll }, false, {}, false)
    local cc = S.cam2.CameraComponent
    if valid(cc) then cc:SetFieldOfView(cm1:GetFOVAngle()) end
  end)
end

local function updateCam2()
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
      if CFG.split_layout == "left_right" then W = W / 2 else H = H / 2 end
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
    local p = buddyScreenPos()
    if p == nil then VIS.fallback = true; log("перехожу на разделение по расстоянию") return S.split end
    if S.split then
      -- снова общий экран, когда напарник уверенно в кадре
      if insideBox(p, 0.15) then VIS.shownFor = VIS.shownFor + 1 else VIS.shownFor = 0 end
      return VIS.shownFor < 45           -- ~0.75 с в кадре
    else
      if insideBox(p, 0.04) then VIS.hiddenFor = 0 else VIS.hiddenFor = VIS.hiddenFor + 1 end
      return VIS.hiddenFor >= 20         -- ~0.3 с вне кадра
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
setSplitVisible = function(on)
  try("split visible", function()
    local g = gms()
    g.TwoPlayerSplitscreenLayout = (CFG.split_layout == "left_right") and 1 or 0
    g.bUseSplitscreen = on
    local lp2 = S.lp2
    if valid(lp2) then
      if on then lp2.PlayerController = S.pc2
      else
        local ok = pcall(function() lp2.PlayerController = nil end)
        if not ok then lp2.PlayerController = CreateInvalidObject() end
      end
    end
  end)
  S.split = on
end

local function updateSplit()
  if not usablePC2(S.pc2) then return end
  if S.exposureResetAt and S.frames >= S.exposureResetAt then S.exposureResetAt = nil; setFastExposure(false) end
  local want = wantSplit()
  if want == S.split or now() - S.splitChangedAt < 1.0 then return end
  S.splitChangedAt = now()
  if want then
    updateCam2Pose(); setFastExposure(true); S.exposureResetAt = S.frames + 120
    try("pc2 ViewTarget", function() S.pc2:SetViewTargetWithBlend(S.cam2, 0, 0, 0, false) end)
  end
  VIS.hiddenFor, VIS.shownFor = 0, 0
  setSplitVisible(want)
  log(want and "экран разделён" or "экран общий")
end

------------------------------------------------------------------ кооператив вкл/выкл
local function acquire()
  S.pc1 = findPC(0); if not valid(S.pc1) then return false end
  S.p1 = S.pc1.Pawn; if not isHero(S.p1) then return false end
  local ai, buddy = findBuddy(S.p1); if not buddy then return false end
  S.ai, S.buddy, S.prev = ai, buddy, {}
  setBrain(ai, false)
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

local function toast(msg) S.toast, S.toastUntil = msg, now() + 2.5 end

local function setCoop(on)
  if on == S.coop then return end
  if on then
    try("gamepad offset", function() gms().bOffsetPlayerGamepadIds = CFG.gamepad_goes_to_player2 end)
    S.frames = 0
    if not acquire() then toast("Не нашёл двух героев — загрузите игру"); return end
    S.coop, S.split = true, false
    ensurePC2()
    toast("Игрок 2 подключён: " .. heroName(S.buddy))
  else
    S.coop = false
    resetBuddyInput()
    if valid(S.ai) then setBrain(S.ai, true) end
    removePC2(); S.split = false
    toast("Напарником снова управляет ИИ")
  end
end

local function applyInput()
  local f, r, lx, ly, jump, grab, crouch, sprint = readP2()
  if CFG.swap_axes then f, r = r, f end
  if CFG.invert_forward then f = -f end
  if CFG.invert_right then r = -r end
  local b, ai = S.buddy, S.ai
  try("AI_SetRawInput", function() b:AI_SetRawInput({ X = f, Y = r, Z = 0 }) end)
  try("MovementInput", function() ai:MovementInput({ X = f, Y = r }) end)
  if lx ~= 0 or ly ~= 0 or S.prev.look then
    try("AI_SetRawLookInput", function() b:AI_SetRawLookInput({ X = ly, Y = lx, Z = 0 }) end)
    S.prev.look = (lx ~= 0 or ly ~= 0)
  end
  if grab ~= S.prev.grab then
    try("AI_SetRawPressedInteract", function() b:AI_SetRawPressedInteract(grab) end)
    try("GrabInput", function() ai:GrabInput(grab) end)
    S.prev.grab = grab
  end
  if crouch ~= S.prev.crouch then try("SetSneaking", function() b:SetSneaking(crouch, false) end); S.prev.crouch = crouch end
  if sprint ~= S.prev.sprint then try("PlaypalSetSprint", function() b:PlaypalSetSprint(sprint) end); S.prev.sprint = sprint end
  if jump and not S.prev.jump then
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
local function keyTitle(k) if not k then return "—" end if KEY_NAMES[k] then return KEY_NAMES[k] end
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

local SPLIT_MODES = { { "auto", "Авто (когда не видно)" }, { "distance", "По расстоянию" }, { "always", "Всегда разделён" }, { "never", "Всегда общий" } }
local LAYOUTS = { { "top_bottom", "Сверху и снизу" }, { "left_right", "Слева и справа" } }
local DEVICES = { { "keyboard", "Клавиатура (правая часть)" }, { "gamepad", "Геймпад" } }
local function optTitle(list, v) for _, o in ipairs(list) do if o[1] == v then return o[2] end end return tostring(v) end
local function optCycle(list, v, dir)
  local i = 1; for j, o in ipairs(list) do if o[1] == v then i = j end end
  i = ((i - 1 + dir) % #list) + 1; return list[i][1]
end

local ACTIONS_KB = { { "up", "Вперёд" }, { "down", "Назад" }, { "left", "Влево" }, { "right", "Вправо" },
  { "jump", "Прыжок" }, { "grab", "Схватить (держать)" }, { "crouch", "Присесть (держать)" }, { "sprint", "Бег (держать)" } }
local ACTIONS_PAD = { { "jump", "Прыжок" }, { "grab", "Схватить (держать)" }, { "crouch", "Присесть (держать)" }, { "sprint", "Бег (держать)" } }

local buildMenu
local function changed() saveSettings() end

local function mainMenu()
  return {
    title = "КООПЕРАТИВ — LN3Couch",
    items = {
      { label = function() return "Второй игрок" end, value = function() return S.coop and "ВКЛЮЧЁН" or "выключен" end,
        act = function() setCoop(not S.coop) end, left = function() setCoop(not S.coop) end, right = function() setCoop(not S.coop) end },
      { label = function() return "Управление игрока 2" end, value = function() return optTitle(DEVICES, CFG.device) end,
        left = function() CFG.device = optCycle(DEVICES, CFG.device, -1); changed() end,
        right = function() CFG.device = optCycle(DEVICES, CFG.device, 1); changed() end },
      { label = function() return "Экран" end, value = function() return optTitle(SPLIT_MODES, CFG.split) end,
        left = function() CFG.split = optCycle(SPLIT_MODES, CFG.split, -1); changed() end,
        right = function() CFG.split = optCycle(SPLIT_MODES, CFG.split, 1); changed() end },
      { label = function() return "Разделение" end, value = function() return optTitle(LAYOUTS, CFG.split_layout) end,
        left = function() CFG.split_layout = optCycle(LAYOUTS, CFG.split_layout, -1); applyLayout(); changed() end,
        right = function() CFG.split_layout = optCycle(LAYOUTS, CFG.split_layout, 1); applyLayout(); changed() end },
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
    act = function() S.menu, S.sel = buildMenu("main"), 6 end }
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
    S.pc1 = findPC(0)
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
  if not valid(S.pc1) then S.pc1 = findPC(0) end
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
    local lines = { { S.menu.title, GOLD }, { " ", WHITE } }
    for i, it in ipairs(S.menu.items) do
      local sel = (i == S.sel)
      local v = it.value()
      local txt = (sel and "»  " or "     ") .. it.label()
      if v ~= "" then txt = txt .. ":   " .. ((sel and it.left) and ("< " .. v .. " >") or v) end
      lines[#lines + 1] = { txt, sel and GOLD or WHITE }
    end
    lines[#lines + 1] = { " ", WHITE }
    lines[#lines + 1] = { S.capture and "Нажмите кнопку для назначения.  Backspace — отмена"
      or "Стрелки — выбор,  ← → изменить,  Enter — выбрать,  Backspace — назад,  F9 — закрыть", GREY }
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
  local pc = S.pc1 or findPC(0)
  local btn = lib:Create(pc, template:GetClass(), pc)
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
    { function() return "Второй игрок: " .. yesno(S.coop) end, function() setCoop(not S.coop) end },
    { function() return "Управление игрока 2: " .. optTitle(DEVICES, CFG.device) end,
      function() CFG.device = optCycle(DEVICES, CFG.device, 1); saveSettings(); PM.rebuildKeys = true end },
    { function() return "Экран: " .. optTitle(SPLIT_MODES, CFG.split) end,
      function() CFG.split = optCycle(SPLIT_MODES, CFG.split, 1); saveSettings() end },
    { function() return "Разделение: " .. optTitle(LAYOUTS, CFG.split_layout) end,
      function() CFG.split_layout = optCycle(LAYOUTS, CFG.split_layout, 1); applyLayout(); saveSettings() end },
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
    e.btn = makeBtn(PM.template, PM.widget, it[1](), function() it[2](); refreshLabels() end)
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
  for _, c in ipairs(PM.clicks) do
    if c.id == id then try("click", c.fn); return end
  end
end

local function injectPause(w)
  local sb, resume = findPanelWithChild(w.WidgetTree.RootWidget, "btn_Resume")
  if not sb then log("меню паузы: список кнопок не найден"); return end
  PM.widget, PM.sb, PM.template, PM.pages, PM.page, PM.clicks = w, sb, resume, {}, nil, {}
  PM.orig = children(sb)
  if not PM.hookOk then
    local ok = pcall(function() RegisterHook(BTN_CLICK_FN, onAnyButtonClicked) end)
    PM.hookOk = ok
    log(ok and "меню паузы: нажатия кнопок подключены" or "меню паузы: не удалось подключить нажатия")
  end
  -- «Кооператив» вставляем перед «Выход в главное меню»
  local tail = {}
  local seenMain = false
  for _, c in ipairs(PM.orig) do
    local n = wfname(c)
    if n == "btn_MainMenu" then seenMain = true end
    if seenMain then tail[#tail + 1] = c end
  end
  PM.mirror, PM.lastMirrorVis, PM.lastMirrorEn = tail[1] or resume, nil, nil
  for _, c in ipairs(tail) do pcall(function() sb:RemoveChild(c) end) end
  PM.coopBtn = makeBtn(resume, w, "Кооператив", function() showPage("coop") end)
  copySlot(sb:AddChild(PM.coopBtn), resume)
  for _, c in ipairs(tail) do local s = sb:AddChild(c); copySlot(s, resume) end
  PM.orig[#PM.orig + 1] = PM.coopBtn
  log("меню паузы: пункт «Кооператив» добавлен")
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
  local target = nil
  for _, w in ipairs(FindAllOf("PauseMenuWidget_C") or {}) do
    local okv, vis = pcall(function() return w:IsVisible() end)
    if valid(w) and okv and vis then
      local id = wid(w)
      if injected[id] then
        if PM.widget and wid(PM.widget) == id then try("labels", coopLabelRefresh) end
      else
        target = w
      end
    end
  end
  if target then
    injected[wid(target)] = true   -- помечаем сразу: вставляем не больше одного раза
    if not valid(S.pc1) then S.pc1 = findPC(0) end
    local ok = try("injectPause", injectPause, target)
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
  try("updateUI", updateUI)
  try("pauseTick", pauseTick)
  if not S.menuOpen then try("captureTick", captureTick) end
  if S.menuOpen then
    if not valid(S.pc1) then S.pc1 = findPC(0) end
    if valid(S.pc1) then try("menuInput", menuInput) end
    if S.coop then return end
  end
  if not S.coop then return end
  if not (valid(S.pc1) and valid(S.p1) and valid(S.ai) and valid(S.buddy) and S.ai.Pawn == S.buddy) then
    if S.frames % 60 == 0 and acquire() then log("персонажи найдены заново (смена уровня/возрождение)") end
    return
  end
  if S.frames % 10 == 0 then try("StopAllAICommands", function() S.ai:StopAllAICommands() end) end
  if not usablePC2(S.pc2) and S.frames % 120 == 0 then ensurePC2() end
  applyInput()
  updateSplit()
  if valid(S.pc2) then updateCam2() end
end

if LoopInGameThreadWithDelay then
  LoopInGameThreadWithDelay(16, function() try("Tick", Tick) end)
else
  LoopAsync(16, function() ExecuteInGameThread(function() try("Tick", Tick) end); return false end)
end


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
log("v1.4 загружен. F9 — меню кооператива")
