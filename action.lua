-- Event handlers only run in `rex do` scripts, so these actions start or stop
-- one. Enabling survives restarts: while amber.enabled exists, loading this
-- file starts Amber again if it isn't running, and Rex loads it on every start
-- and config reload.

local home = os.getenv("HOME")
local dir = (os.getenv("XDG_CONFIG_HOME") or (home .. "/.config")) .. "/rex/amber"
local script_path = dir .. "/amber.lua"
local enabled_path = dir .. "/amber.enabled"
local log_path = dir .. "/amber.log"
-- Actions run with the server's bare environment, so `rex` isn't on PATH.
-- This is the directory Rex exports as REX_BIN_DIR in its own terminals.
local rex_bin = home .. "/Library/Application Support/com.superlogical.rex/"
  .. "RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"

local function exists(path)
  local file = io.open(path)
  if file then file:close() end
  return file ~= nil
end

-- Amber's processes, found by command line rather than a pid file, so a lost
-- or stale record can neither hide one nor let a second one start.
local function running_pids()
  local pids = {}
  local suffix = " do --all " .. script_path
  local ps = rex.exec({ "ps", "-Ax", "-o", "pid=,command=" })
  for pid, command in ((ps and ps.stdout) or ""):gmatch("%s*(%d+) ([^\n]*)") do
    if command:sub(-#suffix) == suffix then table.insert(pids, pid) end
  end
  return pids
end

local function start()
  local process, err = rex.exec.start(
    -- The shell only sends the output to amber.log, then becomes `rex do`.
    -- Without --autostart=false, `rex do` could start a server of its own.
    { "/bin/sh", "-c", 'exec "$0" "$@" >"$AMBER_LOG" 2>&1',
      rex_bin, "--autostart=false", "do", "--all", script_path },
    {
      detach = true,
      stdout = false,
      stderr = false,
      env = {
        -- The server's PATH lacks the places `claude` gets installed: the
        -- native installer's ~/.local/bin and Homebrew.
        PATH = home .. "/.local/bin:/opt/homebrew/bin:/usr/local/bin:" .. (os.getenv("PATH") or "/usr/bin:/bin"),
        AMBER_LOG = log_path,
      },
    })
  if not process then error("couldn't start Amber: " .. tostring(err), 0) end
  return process
end

local function stop()
  for _, pid in ipairs(running_pids()) do rex.exec({ "kill", pid }) end
  -- A review in progress is a process of its own, and the only one with this argument.
  rex.exec({ "pkill", "-f", "--", "--system-prompt-file " .. dir .. "/review-prompt.md" })
  for _ = 1, 20 do
    if #running_pids() == 0 then return end
    rex.exec({ "sleep", "0.1" })
  end
  error("Amber didn't stop; its processes are still running", 0)
end

rex.action{
  name = "enable_amber",
  title = "Enable Amber",
  description = "When a Claude Code session goes idle, suggest changes to its project's instructions.",
  keywords = "amber learner claude claude.md suggestions",
  run = function()
    local file = assert(io.open(enabled_path, "w"))
    file:close()
    if #running_pids() > 0 then return end
    local process = start()
    -- A broken amber.lua exits right away, so say so instead of looking enabled.
    rex.exec({ "sleep", "1" })
    if not process:running() then
      os.remove(enabled_path)
      error("Amber stopped right after starting. See " .. log_path, 0)
    end
  end,
}

rex.action{
  name = "disable_amber",
  title = "Disable Amber",
  description = "Stop suggesting changes from Claude Code sessions.",
  keywords = "amber learner claude claude.md suggestions",
  run = function()
    os.remove(enabled_path)
    stop()
  end,
}

if exists(enabled_path) and #running_pids() == 0 then pcall(start) end
