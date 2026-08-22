-- =============================================================================
-- logger.lua  —  MEDINA logging
--
-- Lightweight logger with a configurable backend. Same interface everywhere:
--   local logging = dofile("/home/logger.lua")
--   local log = logging.createLogger("broker")
--   log:info("message");  log:error("oops");  log:warn(...);  log:debug(...)
--
-- Backends (set in config.lua under `config.logging`):
--   enabled = false        -- master switch (default)
--   backend = "file"       -- "file" (default) | "loki" | "console"
--   file    = "/tmp/spacemining.log"
--   maxFileBytes = 65536   -- rotate/truncate when the log exceeds this
--   lokiHost = "127.0.0.1" -- only used when backend == "loki"
--   lokiPort = 3100
--
-- DEFAULT BEHAVIOR (enabled = false): writes ERROR and WARN lines to the log
-- file only — quiet on screen, no network — so a fresh install still records
-- failures you can read at /tmp/spacemining.log. Set enabled = true to also
-- capture INFO/DEBUG and to use the loki/console backends.
--
-- The file lives on OpenComputers' /tmp (a small RAM disk wiped on reboot), so
-- we cap its size to avoid filling the disk on a long run.
-- =============================================================================

local component = require("component")
local computer  = require("computer")

-- Pull logging config if present; fall back to safe defaults.
local ok, config = pcall(dofile, "/home/config.lua")
local L = (ok and config and config.logging) or {}

local ENABLED   = L.enabled == true
local BACKEND   = L.backend or "file"
local LOGFILE   = L.file or "/tmp/spacemining.log"
local MAXBYTES  = L.maxFileBytes or 65536
local LOKI_HOST = L.lokiHost or "127.0.0.1"
local LOKI_PORT = L.lokiPort or 3100
local LOKI_URL  = "http://" .. LOKI_HOST .. ":" .. LOKI_PORT .. "/loki/api/v1/push"

-- ---------------------------------------------------------------------------
-- Timestamp: seconds since boot anchored to an approximate wall time. Without an
-- internet card we can't fetch real time, so this is best-effort and monotonic.
-- (If you run an internet card + a time source, swap getCurrentTimestamp out.)
-- ---------------------------------------------------------------------------
local bootApprox = L.bootUnixTime or 0   -- optional: set a real epoch in config
local bootUptime = computer.uptime()
local function getCurrentTimestamp()
  return bootApprox + (computer.uptime() - bootUptime)
end

local function isoTime()
  local t = math.floor(getCurrentTimestamp())
  if t > 0 then return os.date("!%Y-%m-%dT%H:%M:%SZ", t) end
  return string.format("+%.1fs", computer.uptime() - bootUptime)  -- uptime-relative
end

-- ---------------------------------------------------------------------------
-- File backend with a simple size cap (truncate when it grows past MAXBYTES).
-- ---------------------------------------------------------------------------
local function fileSize(path)
  local f = io.open(path, "r")
  if not f then return 0 end
  local size = f:seek("end") or 0
  f:close()
  return size
end

local function writeFile(line)
  if fileSize(LOGFILE) > MAXBYTES then
    local f = io.open(LOGFILE, "w")          -- truncate
    if f then f:write("[log truncated]\n"); f:close() end
  end
  local f = io.open(LOGFILE, "a")
  if f then f:write(line .. "\n"); f:close() end
end

-- ---------------------------------------------------------------------------
-- Optional Loki backend (only if an internet card is present).
-- ---------------------------------------------------------------------------
local internet = component.isAvailable("internet") and component.internet or nil

local function jsonEscape(s) return (s:gsub("\\", "\\\\"):gsub('"', '\\"')) end

local function sendLoki(jobName, level, logLine)
  if not internet then writeFile(logLine); return end
  local nanos = tostring(math.floor(getCurrentTimestamp() * 1e9))
  local payload = '{"streams":[{"stream":{"job":"' .. jsonEscape(jobName) ..
    '","level":"' .. level .. '"},"values":[["' .. nanos .. '","' ..
    jsonEscape(logLine) .. '"]]}]}'
  pcall(function()
    local resp = internet.request(LOKI_URL, payload, { ["Content-Type"] = "application/json" })
    if resp then for _ in resp do end end  -- drain to avoid leak
  end)
end

-- ---------------------------------------------------------------------------
-- Logger factory
-- ---------------------------------------------------------------------------
local function shouldEmit(level)
  if ENABLED then return true end
  -- When disabled, still record problems to the file.
  return level == "ERROR" or level == "WARN"
end

local function createLogger(jobName)
  local logger = {}

  local function emit(level, message)
    if not shouldEmit(level) then return end
    local line = "[" .. isoTime() .. "] [" .. jobName .. "] [" .. level .. "] " .. tostring(message)

    if ENABLED and BACKEND == "loki" then
      sendLoki(jobName, level, line)
    elseif ENABLED and BACKEND == "console" then
      print(line)
    else
      writeFile(line)   -- default, and the disabled-but-error case
    end
  end

  function logger:info(m)  emit("INFO",  m) end
  function logger:warn(m)  emit("WARN",  m) end
  function logger:error(m) emit("ERROR", m) end
  function logger:debug(m) emit("DEBUG", m) end

  return logger
end

return {
  createLogger        = createLogger,
  getCurrentTimestamp = getCurrentTimestamp,
}
