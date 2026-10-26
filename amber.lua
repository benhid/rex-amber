-- Amber watches Claude Code panes. When an agent has been idle for a while, a
-- reviewer reads what's new in its conversation and suggests changes to the
-- project's instructions. Suggestions land in .claude-suggestions/, and the
-- review-suggestions skill in .claude/skills/ applies or rejects them.
--
-- Only projects whose directory has a .claude/CLAUDE.md take part.
--
--   rex do --all amber.lua [idle=600] [model=claude-sonnet-5-5]

local HOME = os.getenv("HOME")
local AMBER_DIR = (os.getenv("XDG_CONFIG_HOME") or (HOME .. "/.config")) .. "/rex/amber"
local CLAUDE_DIR = os.getenv("CLAUDE_CONFIG_DIR") or (HOME .. "/.claude")
local SKILL_TEMPLATE_PATH = AMBER_DIR .. "/review-suggestions.md"
local REVIEW_PROMPT_PATH = AMBER_DIR .. "/review-prompt.md"
local MODEL = rex.args.model or "claude-sonnet-5-5"
local IDLE_SECONDS = tonumber(rex.args.idle) or 600
local REVIEW_TIMEOUT_SECONDS = 900
-- A long backlog is reviewed in parts, one per idle period, so no single
-- review gets too big to finish.
local MAX_READ_BYTES = 16 * 1024 * 1024
local MAX_CONVERSATION_BYTES = 200 * 1024
-- A part that keeps failing is skipped, so it can't be retried forever.
local MAX_FAILURES = 3

local idle_timers = {}  -- block_id -> timer

-- Files ----------------------------------------------------------------------

local function read_file(path)
  local file = io.open(path)
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  return text
end

-- Written next to the target and renamed over it, so it's never left half written.
local function write_file(path, text)
  local temp = path .. ".tmp"
  local file = assert(io.open(temp, "w"))
  file:write(text)
  file:close()
  assert(os.rename(temp, path))
end

local function exists(path)
  local file = io.open(path)
  if file then file:close() end
  return file ~= nil
end

local function is_dir(path)
  local result = rex.exec({ "test", "-d", path })
  return result and result.ok
end

local function file_size(path)
  local file = io.open(path)
  if not file then return nil end
  local size = file:seek("end")
  file:close()
  return size
end

local function file_hash(path)
  local result = rex.exec({ "shasum", "-a", "256", path })
  return result and result.ok and result.stdout:match("^(%x+)") or nil
end

-- Progress ---------------------------------------------------------------------

-- Each project keeps how many transcript bytes of each session were reviewed,
-- failed attempts at the next part, and the CLAUDE.md it last audited.
local function progress_path(cwd)
  return cwd .. "/.claude-suggestions/.progress.json"
end

local function read_progress(cwd)
  local progress = rex.json.decode(read_file(progress_path(cwd)) or "")
  if type(progress) ~= "table" then progress = {} end
  if type(progress.sessions) ~= "table" then progress.sessions = {} end
  if type(progress.failures) ~= "table" then progress.failures = {} end
  return progress
end

local function save_progress(cwd, progress)
  if next(progress.failures) == nil then progress.failures = nil end
  rex.exec({ "mkdir", "-p", cwd .. "/.claude-suggestions" })
  write_file(progress_path(cwd), rex.json.encode(progress, { indent = true }))
end

-- Claude Code ----------------------------------------------------------------

-- Claude Code keeps <config>/sessions/<pid>.json with the session id and cwd.
local function claude_session(pid)
  local path = string.format("%s/sessions/%d.json", CLAUDE_DIR, pid)
  local session = rex.json.decode(read_file(path) or "")
  if type(session) == "table" and session.sessionId and session.cwd then return session end
end

-- Transcripts live in <config>/projects/<project>/<session>.jsonl, next to the
-- project's private memory. The folder is usually the cwd with every
-- non-alphanumeric character as "-", but long or non-ASCII paths are named
-- differently, so the session id, which is unique, is what finds it.
local function find_transcript(cwd, session_id)
  local guess = string.format("%s/projects/%s/%s.jsonl", CLAUDE_DIR, (cwd:gsub("[^%w]", "-")), session_id)
  if exists(guess) then return guess end
  local result = rex.exec({ "find", CLAUDE_DIR .. "/projects", "-mindepth", "2", "-maxdepth", "2",
    "-name", session_id .. ".jsonl" })
  return result and result.ok and result.stdout:match("[^\n]+") or nil
end

-- Suggestions ----------------------------------------------------------------

-- The skill is Amber's own file, so it's refreshed whenever the template changes.
local function install_skill(cwd)
  local dir = cwd .. "/.claude/skills/review-suggestions"
  local template = read_file(SKILL_TEMPLATE_PATH)
  if not template or read_file(dir .. "/SKILL.md") == template then return end
  rex.exec({ "mkdir", "-p", dir })
  write_file(dir .. "/SKILL.md", template)
end

-- One review at a time. Anything that triggers a review meanwhile is skipped:
-- its conversation is still unreviewed, so the next review picks it up.
local reviewing = false

-- Keeps what the person said, what the agent said and did, and tool errors.
-- Injected context, meta entries and compaction summaries are left out.
-- Every transcript line gives exactly one output line, a JSON string with its
-- entries, so the outputs can be matched back to transcript bytes. Anything
-- unexpected in a line drops it instead of failing the whole run.
local CONVERSATION_FILTER = [[
[ (fromjson | select((.type == "user" or .type == "assistant") and (.isMeta | not) and (.isCompactSummary | not))
  | .type as $who | .message.content
  | if type == "string" then (if startswith("<") then empty else {($who): .} end) else .[]
    | if .type == "text" then (if $who == "user" and (.text | startswith("<")) then empty else {($who): .text} end)
      elif .type == "tool_use" then {tool: .name, input: (.input | tostring | .[:300])}
      elif .type == "tool_result" and .is_error then {error: (.content | tostring | .[:300])}
      else empty end
    end)? | tojson ] | join("\n")]]

-- The part of the transcript after `from`, as compact JSON lines, and where
-- that part ends. Only whole lines are read, and at most MAX_CONVERSATION_BYTES
-- of conversation, so a long backlog takes several reviews.
local function new_conversation(transcript, from)
  local file = io.open(transcript, "rb")
  if not file then return nil end
  file:seek("set", from)
  local raw = file:read(MAX_READ_BYTES) or ""
  file:close()

  local from_end = raw:reverse():find("\n", 1, true)
  if not from_end then
    -- A line longer than a whole read is skipped: what's left of it won't parse.
    if #raw == MAX_READ_BYTES then return "", from + #raw end
    return "", from  -- the line is still being written
  end
  raw = raw:sub(1, #raw - from_end + 1)

  local result = rex.exec({ "jq", "-cR", CONVERSATION_FILTER }, { stdin = raw, timeout = 60 })
  if not (result and result.ok) then return nil end

  -- Walks the transcript lines and their outputs side by side.
  local output = result.stdout
  local parts, size, ends = {}, 0, from
  local line_start, output_start = 1, 1
  while line_start <= #raw do
    local line_end = raw:find("\n", line_start, true)
    local output_end = output:find("\n", output_start, true)
    if not output_end then return nil end
    local entries = rex.json.decode(output:sub(output_start, output_end - 1))
    if type(entries) ~= "string" then return nil end
    if entries ~= "" then
      if size > 0 and size + #entries > MAX_CONVERSATION_BYTES then break end
      table.insert(parts, entries:sub(1, MAX_CONVERSATION_BYTES))
      size = size + #entries + 1
    end
    ends = from + line_end
    line_start, output_start = line_end + 1, output_end + 1
  end
  return table.concat(parts, "\n"), ends
end

local function review(pane)
  if reviewing then return end
  local id = pane.session_id
  local transcript = find_transcript(pane.cwd, id)
  local size = transcript and file_size(transcript)
  if not size then return end
  local progress = read_progress(pane.cwd)
  local reviewed = progress.sessions[id] or 0
  if size < reviewed then reviewed = 0 end  -- the transcript was rewritten
  if size == reviewed then return end

  -- Audit CLAUDE.md only when it changed since the last audit.
  local claude_md_hash = file_hash(pane.cwd .. "/.claude/CLAUDE.md")
  local audit = claude_md_hash ~= progress.audited

  -- The extraction happens here, not in the reviewer, so the reviewer needs no shell.
  local conversation, reviewed_to = new_conversation(transcript, reviewed)
  if not conversation then
    rex.log("warn", "couldn't read the transcript in " .. pane.cwd)
    return
  end

  local function save()
    progress = read_progress(pane.cwd)
    progress.sessions[id] = reviewed_to
    progress.failures[id] = nil
    if audit then progress.audited = claude_md_hash end
    save_progress(pane.cwd, progress)
  end

  local function failed()
    progress = read_progress(pane.cwd)
    local failures = (progress.failures[id] or 0) + 1
    if failures >= MAX_FAILURES then
      rex.log("warn", string.format("skipping part of session %s in %s after %d failed reviews",
        id, pane.cwd, failures))
      progress.sessions[id] = reviewed_to
      failures = nil
    end
    progress.failures[id] = failures
    save_progress(pane.cwd, progress)
  end

  if conversation:match("^%s*$") and not audit then
    if reviewed_to ~= reviewed then save() end
    return
  end

  local memory = transcript:match("^(.*)/") .. "/memory"
  local has_memory = is_dir(memory)

  local input = table.concat({
    "Session: " .. id,
    "Now: " .. os.date("!%Y-%m-%dT%H:%M:%SZ"),
    "Memory: " .. (has_memory and memory or "none"),
    "Audit CLAUDE.md: " .. (audit and "yes" or "no"),
    "",
    "# New part of the conversation",
    "",
    conversation,
  }, "\n")

  -- Started in the background so the script keeps handling events meanwhile.
  -- The reviewer has no shell. Outside the project it can only read the memory
  -- folder, it can't read secrets inside it, and it can only write inside
  -- .claude-suggestions/, except Amber's progress. Claude Code never lets it
  -- write inside .claude/.
  local args = {
    "claude", "-p",
    "--model", MODEL,
    "--tools", "Read,Grep,Glob,Write,Edit",
    -- Reads inside the project and --add-dir need no rule. A bare "Read" here
    -- would allow reading anywhere, so only the suggestions folder is listed.
    "--allowed-tools", "Edit(./.claude-suggestions/**)",
    "--disallowed-tools", "Edit(./.claude-suggestions/.progress*),"
      .. "Read(./**/.env*),Read(./**/*.pem),Read(./**/*.key),Read(./**/id_*)",
    "--setting-sources", "",
    "--strict-mcp-config",
    "--no-session-persistence",
    "--system-prompt-file", REVIEW_PROMPT_PATH,
  }
  if has_memory then
    table.insert(args, "--add-dir")
    table.insert(args, memory)
  end

  local errors = ""
  local process, err = rex.exec.start(args, {
    cwd = pane.cwd,
    stdin = true,
    detach = true,
    timeout = REVIEW_TIMEOUT_SECONDS,
    stdout = false,
    stderr = function(chunk) errors = (errors .. chunk):sub(-2000) end,
  })
  if not process then
    rex.log("warn", "couldn't start the reviewer: " .. tostring(err))
    return
  end
  process:write(input)
  process:close_stdin()
  reviewing = true

  local poll
  poll = rex.every(2, function()
    if process:running() then return end
    poll:cancel()
    reviewing = false
    -- The project may have moved or gone meanwhile; don't recreate it.
    if not exists(pane.cwd .. "/.claude/CLAUDE.md") then return end
    -- It has exited, so wait() returns at once. wait(0) would report a timeout.
    local result = process:wait()
    if not (result and result.ok) then
      rex.log("warn", string.format("review failed in %s (exit %s): %s",
        pane.cwd, tostring(result and result.code), errors))
      failed()
      return
    end
    install_skill(pane.cwd)
    save()
  end)
end

-- Events ---------------------------------------------------------------------

local function eligible_pane(pid)
  local session = claude_session(pid)
  if not session or not exists(session.cwd .. "/.claude/CLAUDE.md") then return nil end
  return { session_id = session.sessionId, cwd = session.cwd }
end

local function cancel_timer(block)
  if idle_timers[block] then idle_timers[block]:cancel() end
  idle_timers[block] = nil
end

rex.on("terminal.program_status_changed", function(ctx, ev)
  local record = ev.record
  if not record or record.effective_app ~= "claude-code" or not record.owner then return end

  cancel_timer(ctx.block_id)
  -- A long turn isn't idleness: only count from when the agent stops working.
  if record.state == "working" then return end

  -- The session is looked up when the timer fires, so it's the current one.
  local pid = record.owner.pid
  idle_timers[ctx.block_id] = rex.after(IDLE_SECONDS, function()
    idle_timers[ctx.block_id] = nil
    local pane = eligible_pane(pid)
    if pane then review(pane) end
  end)
end)

rex.on("block_closed", function(ctx, ev)
  cancel_timer(ev.block_id)
end)
