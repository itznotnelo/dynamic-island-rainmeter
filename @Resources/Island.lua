-- Island.lua: motion and state for the Dynamic Island skin.
-- Sizes, colours and spring constants follow Bloom's island
-- (github.com/SehajveerSingh2005/bloom); this is our own Rainmeter version of it.
-- Runs every skin update (16 ms): reads what the poller and plugins report, moves the
-- springs and fades, and hands the results to the meters as variables.

local DT = 0.016
local CX = 200            -- pill centre inside the skin window
local CLOCK_W = 124       -- idle width (Bloom: 140, minus 16 for the 24 h clock)
local SLOT = 30           -- visualizer / album art slot
local R = 18              -- bottom corner radius
local FLARE = 13          -- concave shoulders where the notch meets the screen edge

local WEIGHTS = { 1.2, 1.2, 1.5, 2.8, 5 }
local MODE_RGB = {
  Default = '215,119,87', Plan = '72,150,140', Edits = '175,135,255',
  Auto = '255,193,7', Bypass = '255,107,128',
}
local GREEN, RED, ORANGE = '50,215,75', '255,69,58', '255,159,10'

-- Spring with framer-motion constants (stiffness, damping, mass), 4 substeps per frame
local Spring = {}
Spring.__index = Spring
function Spring.new(k, c, m, x)
  return setmetatable({ k = k, c = c, m = m or 1, x = x or 0, v = 0, to = x or 0 }, Spring)
end
function Spring:step(dt)
  local h = dt / 4
  for _ = 1, 4 do
    self.v = self.v + (self.k * (self.to - self.x) - self.c * self.v) / self.m * h
    self.x = self.x + self.v * h
  end
  if math.abs(self.to - self.x) < 0.001 and math.abs(self.v) < 0.01 then
    self.x, self.v = self.to, 0
  end
end

-- 0..1 progress towards 0 or 1 over `dur` seconds (the CSS fades)
local Fade = {}
Fade.__index = Fade
function Fade.new(dur, x) return setmetatable({ dur = dur, x = x or 0, to = x or 0 }, Fade) end
function Fade:step(dt)
  local d = dt / self.dur
  if self.x < self.to then self.x = math.min(self.to, self.x + d)
  else self.x = math.max(self.to, self.x - d) end
end
local function ease(p) return p * p * (3 - 2 * p) end

local S = {}              -- all animated state
local cache = {}          -- last value sent per variable
local t = 0

function Initialize()
  DT = (tonumber(SKIN:GetVariable('UpdateMs')) or 16) / 1000
  S.w = Spring.new(400, 31, 1, CLOCK_W)
  S.h = Spring.new(450, 29, 1, 36)
  S.bg = Fade.new(0.3)                         -- hover/expanded darkening
  S.mute = Fade.new(0.2)                       -- clock dims on hover
  S.vis = Fade.new(0.2)                        -- compact visualizer slot
  S.art = Fade.new(0.12)                       -- compact album art slot
  S.small = Fade.new(0.2)                      -- art shrinks 24 -> 20 when paused
  S.glow = Fade.new(0.6)
  S.layer = { cur = 'row', want = 'row', a = 1 }
  S.bubble = Spring.new(400, 31, 1, 0)
  S.bubbleA = Fade.new(0.15)
  S.bars, S.smooth, S.peak = {}, {}, {}
  for i = 1, 5 do
    S.bars[i] = Spring.new(600, 30, 0.5, 0.1)
    S.smooth[i], S.peak[i] = 0, 1e-4
  end
  S.pulses = {}
  S.paused = 99
  S.spin = 0
  S.mq = 0
  S.lastClaude, S.lastBattery = nil, 0
  S.hover, S.expanded = false, false
end

-- Mouse, called from the skin with !CommandMeasure
function Hover(on)
  S.hover = on == 1
  if not S.hover then S.expanded = false end    -- Bloom closes as soon as the mouse leaves
end
function Click()
  if S.hasMusic then S.expanded = not S.expanded end
end

local dirty = true        -- meters only redraw when something changed (they have UpdateDivider=-1)
local function set(name, value)
  if type(value) == 'number' then value = string.format('%.2f', value) end
  if cache[name] ~= value then
    cache[name] = value
    dirty = true
    SKIN:Bang('!SetVariable', name, value)
  end
end
local function str(m) return SKIN:GetMeasure(m):GetStringValue() end
local function num(m) return SKIN:GetMeasure(m):GetValue() end
local function alpha(a) return string.format('%d', math.floor(math.max(0, math.min(1, a)) * 255 + 0.5)) end

local function pillPath(w, h)
  local L, Rt = CX - w / 2, CX + w / 2
  local k = 0.5523 * R
  local f = '%.2f'
  local function p(x, y) return string.format(f .. ',' .. f, x, y) end
  return table.concat({
    p(L - FLARE, 0),
    'CurveTo ' .. p(L, FLARE) .. ',' .. p(L - FLARE + 10, 0) .. ',' .. p(L, FLARE - 10),
    'LineTo ' .. p(L, h - R),
    'CurveTo ' .. p(L + R, h) .. ',' .. p(L, h - R + k) .. ',' .. p(L + R - k, h),
    'LineTo ' .. p(Rt - R, h),
    'CurveTo ' .. p(Rt, h - R) .. ',' .. p(Rt - R + k, h) .. ',' .. p(Rt, h - R + k),
    'LineTo ' .. p(Rt, FLARE),
    'CurveTo ' .. p(Rt + FLARE, 0) .. ',' .. p(Rt, FLARE - 10) .. ',' .. p(Rt + FLARE - 10, 0),
    'ClosePath 1',
  }, ' | ')
end

-- Bloom's marquee: 30 px/s, at least 5 s a cycle; hold to 12 %, scroll to the end by 42 %,
-- hold to 55 %, back by 80 %, hold to 100 %
local function marquee(overflow, dt)
  if overflow <= 1 then S.mq = 0 return 0 end
  local dur = math.max(5, overflow / 30 / 0.30)
  S.mq = (S.mq + dt) % dur
  local p = S.mq / dur
  if p < 0.12 then return 0
  elseif p < 0.42 then return overflow * ease((p - 0.12) / 0.30)
  elseif p < 0.55 then return overflow
  elseif p < 0.80 then return overflow * (1 - ease((p - 0.55) / 0.25))
  end
  return 0
end

local function pushPulse(text, rgb, secs)
  if text and text ~= '' then table.insert(S.pulses, { text = text, rgb = rgb, t = secs }) end
end

local function readEvents()
  -- Claude Code: one pulse per new event (the poller repeats it for 8 s)
  local at = str('MeasureClaudeEventAt')
  local ev = num('MeasureClaudeEvent')
  if S.lastClaude == nil then S.lastClaude = at end   -- don't replay an old event on refresh
  if ev > 0 and at ~= S.lastClaude then
    local rgb = ev == 1 and ORANGE or ev == 2 and GREEN or (MODE_RGB[str('MeasureClaudeMode')] or MODE_RGB.Default)
    pushPulse(str('MeasureClaudeLabel'), rgb, 4)
  end
  S.lastClaude = at
  -- Battery: 2 plug/unplug, 3 low, 4 critical
  local be = num('MeasureEvent')
  if be ~= S.lastBattery and be > 0 then
    local pct = string.format('%d%%', num('MeasureBatteryPercent'))
    if be == 2 then
      local charging = num('MeasureBatteryCharging') == 1
      pushPulse((charging and 'Charging ' or 'Battery ') .. pct, charging and GREEN or '255,255,255', 4)
    else
      pushPulse('Low battery ' .. pct, RED, be == 4 and 6 or 5)
    end
  end
  S.lastBattery = be
end

local function visualizer(playing)
  for i = 1, 5 do
    local raw = num('MeasureBand' .. i) * WEIGHTS[i]
    S.peak[i] = math.max(S.peak[i] * 0.99, raw, 1e-4)
    local v = math.max(0.18, math.min(1, (raw / S.peak[i]) ^ 0.75))
    S.smooth[i] = S.smooth[i] + (v - S.smooth[i]) * (v > S.smooth[i] and 0.10 or 0.20)
    S.bars[i].to = playing and math.max(0.2, S.smooth[i]) or 0.1
    S.bars[i]:step(DT)
  end
end

-- true when nothing is moving: then a frame with unchanged inputs can be skipped entirely
local function settled()
  if #S.pulses > 0 or S.layer.cur ~= S.layer.want or (S.layer.a ~= 0 and S.layer.a ~= 1) then return false end
  for _, s in ipairs({ S.w, S.h, S.bubble, S.bars[1], S.bars[2], S.bars[3], S.bars[4], S.bars[5] }) do
    if s.x ~= s.to or s.v ~= 0 then return false end
  end
  for _, f in ipairs({ S.bg, S.mute, S.vis, S.art, S.small, S.glow, S.bubbleA }) do
    if f.x ~= f.to then return false end
  end
  return true
end

function Update()
  local dt = DT
  t = t + dt

  -- inputs
  local track = str('MeasureTrack')
  local playing = num('MeasureIsPlaying') == 1
  S.hasMusic = track ~= ''
  if playing then S.paused = 0 else S.paused = S.paused + dt end
  local compact = S.hasMusic and (playing or S.paused < 5)
  if not S.hasMusic then S.expanded = false end

  -- fast path: all at rest and nothing new since last frame (most frames when idle)
  local cs = num('MeasureClaudeState')
  local sig = table.concat({ track, str('MeasureArtist'), tostring(playing), tostring(compact),
    str('MeasureCover'), str('MeasureClock'), cs, str('MeasureClaudeMode'), str('MeasureClaudeEventAt'),
    num('MeasureEvent'), num('MeasureMicActive'), num('MeasureCamActive'), num('MeasureVolume'),
    tostring(S.hover), tostring(S.expanded),
    cs == 1 and math.floor(t / 0.25) or cs == 2 and math.floor(t / 0.5) or 0 }, '|')
  if sig == S.sig and S.rest then return 0 end
  S.sig = sig
  readEvents()

  -- what the island should be
  local pulse = S.pulses[1]
  local want, w, h
  if S.expanded then
    want, w, h = 'expanded', 340, 120
  elseif pulse and not S.hover then
    want, w, h = 'pulse', 200, 36
    pulse.t = pulse.t - dt
    if pulse.t <= 0 then table.remove(S.pulses, 1) end
  else
    want, h = 'row', 36
    w = CLOCK_W + (compact and SLOT or 0) + (compact and playing and SLOT or 0)
  end
  S.layer.want = want
  S.w.to, S.h.to = w, h
  S.w:step(dt)
  S.h:step(dt)

  -- content swap like AnimatePresence "wait": old layer fades out in 0.1 s, then the new one in
  local L = S.layer
  if L.want ~= L.cur then
    L.a = math.max(0, L.a - dt / 0.1)
    if L.a == 0 then L.cur = L.want end
  else
    L.a = math.min(1, L.a + dt / 0.2)
  end
  local rowA = L.cur == 'row' and L.a or 0
  local expA = L.cur == 'expanded' and L.a or 0
  local pulseA = L.cur == 'pulse' and L.a or 0

  S.bg.to = (S.hover or S.expanded) and 1 or 0
  S.mute.to = (S.hover and not S.expanded) and 1 or 0
  S.vis.to = (compact and playing) and 1 or 0
  S.art.to = compact and 1 or 0
  S.small.to = playing and 0 or 1
  S.glow.to = L.cur == 'expanded' and 1 or 0
  for _, f in ipairs({ S.bg, S.mute, S.vis, S.art, S.small, S.glow }) do f:step(dt) end
  visualizer(playing)

  local W, H = S.w.x, S.h.x
  local left = CX - W / 2
  set('PillPath', pillPath(W, H))
  local cover = str('MeasureCover')
  set('Art', cover ~= '' and cover or 'Blank')   -- file slot written by cover.py
  set('bgA', alpha(0.80 + 0.12 * ease(S.bg.x)))
  set('L', left)
  set('W', W)
  set('H', H)

  -- row: [visualizer] clock [art]
  local visSlot, artSlot = SLOT * S.vis.x, SLOT * S.art.x
  set('ClockX', left + visSlot + (W - visSlot - artSlot) / 2)
  set('ClockA', alpha(rowA * (1 - 0.4 * ease(S.mute.x))))
  set('VisA', alpha(rowA * S.vis.x * 0.95))
  local artSize = 24 - 4 * ease(S.small.x)
  local artScale = (0.8 + 0.2 * S.art.x) * artSize / 24
  set('ArtSA', alpha(rowA * S.art.x))
  set('ArtSSize', 56 * artScale)
  set('ArtSX', left + W - 12 - 12 - 28 * artScale)
  set('ArtSY', 18 - 28 * artScale)
  local dots = rowA * (1 - S.art.x)          -- privacy dots only when the art slot is free
  set('MicA', alpha(dots * num('MeasureMicActive')))
  set('CamA', alpha(dots * num('MeasureCamActive')))
  S.frame = (S.frame or 0) + 1
  if S.frame % 2 == 0 then                 -- bars redraw at 30 fps (the springs still run at 60)
    for i = 1, 5 do
      set('Bar' .. i, 20 * math.max(0.1, S.bars[i].x))
      set('BarE' .. i, 18 * math.max(0.1, S.bars[i].x))   -- the expanded view's bars are 18 px
    end
  end

  -- pulse
  set('PulseA', alpha(pulseA))
  if pulse then set('PulseText', pulse.text) set('PulseRGB', pulse.rgb) end

  -- expanded music
  set('ExpA', alpha(expA))
  set('ExpMutedA', alpha(expA * 0.6))
  set('ExpIconA', alpha(expA * 0.5))
  set('ExpTrackA', alpha(expA * 0.15))
  set('ExpVisA', alpha(expA * (playing and 0.8 or 0.5)))
  set('GlowA', alpha(ease(S.glow.x)))     -- the 0.85 opacity is baked into the glow image
  set('HitA', expA > 0.5 and '1' or '0')
  set('PlayA', alpha(expA * (playing and 0 or 1)))
  set('PauseA', alpha(expA * (playing and 1 or 0)))
  local colW = W - 130 - 12
  local top = (H - 99) / 2
  set('ColX', left + 130)
  set('ColW', colW)
  set('Top', top)
  set('VolW', (colW - 12 - 14 - 16) * math.max(0, math.min(100, num('MeasureVolume'))) / 100)
  local titleW = colW - 25 - 12
  set('TitleW', titleW)
  set('TitleFade', (titleW - 8) / titleW)
  local meter = SKIN:GetMeter('MeterTitle')
  local overflow = meter and (meter:GetW() - titleW) or 0
  S.marqueeOn = L.cur == 'expanded' and overflow > 1
  set('TitleX', -marquee(S.marqueeOn and overflow or 0, dt))

  -- Claude bubble beside the pill (Bloom's live-activity bubble: 30x30, r10, 8 px gap)
  local active = cs > 0 and not S.expanded
  S.bubble.to = active and 1 or 0
  S.bubbleA.to = active and 1 or 0
  S.bubble:step(dt)
  S.bubbleA:step(dt)
  local p = S.bubble.x
  set('BubbleX', left - 8 - 30 + 28 * (1 - p))
  set('BubbleS', 0.4 + 0.6 * math.max(0, p))
  set('BubbleA', alpha(S.bubbleA.x * (0.80 + 0.12 * ease(S.bg.x))))
  -- stepped like Claude Code's own spinner: each step is a full redraw, so 4 a second, not 60
  local sparkA = 1
  if cs == 1 then S.spin = (math.floor(t / 0.25) * 30) % 360        -- long and short rays swap: twinkle
  elseif cs == 2 then sparkA = math.floor(t / 0.5) % 2 == 0 and 1 or 0.35
  elseif cs == 3 then sparkA = 0.55 end
  set('SparkAngle', S.spin)
  set('SparkRGB', MODE_RGB[str('MeasureClaudeMode')] or MODE_RGB.Default)
  set('SparkA', alpha(S.bubbleA.x * sparkA))

  -- text the meters show straight from measures
  set('_clock', str('MeasureClock'))
  set('_track', track)
  set('_artist', str('MeasureArtist'))

  -- the audio analysis only runs while something plays
  local wantAudio = playing or S.paused < 1
  if wantAudio ~= S.audioOn then
    S.audioOn = wantAudio
    SKIN:Bang(wantAudio and '!EnableMeasureGroup' or '!DisableMeasureGroup', 'Audio')
  end

  S.rest = settled() and not playing and not S.marqueeOn
  if dirty then
    dirty = false
    SKIN:Bang('!UpdateMeterGroup', 'Island')
    SKIN:Bang('!Redraw')
  end
  return 0
end
