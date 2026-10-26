-- Event handlers only run in `rex do` scripts, so these actions start and stop
-- one. Enabling survives restarts: Rex loads this file on every start and
-- config reload, and while amber.enabled exists, that starts Amber again.

local HOME = os.getenv("HOME")
local AMBER_DIR = (os.getenv("XDG_CONFIG_HOME") or HOME .. "/.config") .. "/rex/amber"
local SCRIPT_PATH = AMBER_DIR .. "/amber.lua"
local ENABLED_PATH = AMBER_DIR .. "/amber.enabled"
local LOG_PATH = AMBER_DIR .. "/amber.log"
-- Actions run with the server's bare environment, so `rex` isn't on PATH.
-- This is the directory Rex exports as REX_BIN_DIR in its own terminals.
local REX_BIN = HOME .. "/Library/Application Support/com.superlogical.rex/"
  .. "RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
-- The server's PATH also lacks where `claude` gets installed: the native
-- installer's ~/.local/bin, and Homebrew.
local PATH = HOME .. "/.local/bin:/opt/homebrew/bin:/usr/local/bin:" .. (os.getenv("PATH") or "/usr/bin:/bin")

local function exists(path)
  local file = io.open(path)
  if file then file:close() end
  return file ~= nil
end

-- Amber's processes, found by command line rather than a pid file, so a lost
-- or stale record can neither hide one nor let a second one start.
local function running_pids()
  local pids = {}
  local suffix = " do --all " .. SCRIPT_PATH
  local ps = rex.exec({ "ps", "-Ax", "-o", "pid=,command=" })
  for pid, command in (ps and ps.stdout or ""):gmatch("%s*(%d+) ([^\n]*)") do
    if command:sub(-#suffix) == suffix then table.insert(pids, pid) end
  end
  return pids
end

local function start()
  -- The shell only sends the output to amber.log, then becomes `rex do`.
  -- Without --autostart=false, `rex do` could start a server of its own.
  local process, err = rex.exec.start({
    "/bin/sh", "-c", 'exec "$0" "$@" >"$AMBER_LOG" 2>&1',
    REX_BIN, "--autostart=false", "do", "--all", SCRIPT_PATH,
  }, {
    detach = true,
    stdout = false,
    stderr = false,
    env = { PATH = PATH, AMBER_LOG = LOG_PATH },
  })
  if not process then error("couldn't start Amber: " .. tostring(err), 0) end
  return process
end

local function stop()
  for _, pid in ipairs(running_pids()) do rex.exec({ "kill", pid }) end
  -- A review in progress is a process of its own, the only one with this argument.
  rex.exec({ "pkill", "-f", "--", "--system-prompt-file " .. AMBER_DIR .. "/review-prompt.md" })
  for _ = 1, 20 do
    if #running_pids() == 0 then return end
    rex.exec({ "sleep", "0.1" })
  end
  error("Amber didn't stop: its processes are still running", 0)
end

rex.action{
  name = "enable_amber",
  title = "Enable Amber",
  description = "When a Claude Code session goes idle, suggest changes to its project's instructions.",
  keywords = "amber learner claude claude.md suggestions",
  run = function()
    assert(io.open(ENABLED_PATH, "w")):close()
    if #running_pids() > 0 then return end
    local process = start()
    -- A broken amber.lua exits right away: say so instead of looking enabled.
    rex.exec({ "sleep", "1" })
    if process:running() then return end
    os.remove(ENABLED_PATH)
    error("Amber stopped right after starting. See " .. LOG_PATH, 0)
  end,
}

rex.action{
  name = "disable_amber",
  title = "Disable Amber",
  description = "Stop suggesting changes from Claude Code sessions.",
  keywords = "amber learner claude claude.md suggestions",
  run = function()
    os.remove(ENABLED_PATH)
    stop()
  end,
}

if exists(ENABLED_PATH) and #running_pids() == 0 then pcall(start) end
