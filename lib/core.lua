-- midirouter/lib/core.lua  v1.03
--
-- MIDI routing engine for norns.
--
-- Critical: _norns.midi.event is hooked at MODULE LOAD TIME (not in a
-- lifecycle hook). This ensures routing works immediately when devices appear.

local Core = {}

-- ─── Public state ────────────────────────────────────────────────────────

Core.debug       = false
Core.sysex_debug = false
Core.rules       = {}
Core.devices     = {}          -- port -> { id, name, port, connect }
Core.id_to_port  = {}          -- device id -> port
Core.name_to_port = {}         -- device name -> port

-- ─── Constants ───────────────────────────────────────────────────────────

local SAVE_DIR      = "/home/we/dust/data/midirouter"
local SAVE_FILE     = SAVE_DIR .. "/rules.lua"
local SAVE_BACKUP   = SAVE_FILE .. ".bak"
local MAX_RULES     = 16
Core.MAX_RULES      = MAX_RULES  -- FIX (v1.01): expose so mod.lua reads from one source of truth
local SYSEX_TIMEOUT = 2.0
local SYSEX_MAX_LEN = 8192  -- FIX (v1.03): prevent unbounded memory growth from malformed SysEx (missing 0xF7)
local SAVE_DELAY    = 2.0

-- ─── Type bitmasks ───────────────────────────────────────────────────────

local TYPE_NOTE  = 0x01
local TYPE_CC    = 0x02
local TYPE_PC    = 0x04
local TYPE_PB    = 0x08
local TYPE_AT    = 0x10
local TYPE_CLOCK = 0x20

-- ─── Private state ───────────────────────────────────────────────────────

local _cache     = {}
local _any_clock = false

local _sx_ev = {}
local _sx_vp = {}
local _sx_seen_ev = {} -- port -> true once SysEx successfully completes via _norns.midi.event path

local _save_clock    = nil
local _sx_handlers   = {}

-- FIX (BUG-01): Removed module-level shared buffers _buf2 and _buf3.
-- remap_channel() was returning references to these shared tables, meaning
-- multiple rules routing the same event with different dst_ch values could
-- corrupt each other's data before send_safe() completed. The fix allocates
-- a fresh table on every call instead (see remap_channel below).

-- ─── Resolve device name to port ─────────────────────────────────────────

local function resolve_port(name_or_all)
  if name_or_all == "all" then return nil end
  if type(name_or_all) == "string" then
    return Core.name_to_port[name_or_all]
  end
  if type(name_or_all) == "number" then
    return Core.devices[name_or_all] and name_or_all or nil
  end
  return nil
end

-- ─── Safe send ───────────────────────────────────────────────────────────

local function send_safe(connect, data)
  local ok, err = pcall(connect.send, connect, data)
  if not ok and Core.debug then
    print("[midirouter] send error: " .. tostring(err))
  end
end

-- ─── Rule cache ──────────────────────────────────────────────────────────

local function build_cache()
  _cache     = {}
  _any_clock = false

  for _, r in ipairs(Core.rules) do
    if not r.enabled then goto next_rule end

    local src_port = resolve_port(r.src_dev)
    if r.src_dev ~= "all" and not src_port then goto next_rule end

    local dsts = {}
    if r.dst_dev == "all" then
      for port, _ in pairs(Core.devices) do
        if r.src_dev == "all" or port ~= src_port then
          dsts[#dsts + 1] = port
        end
      end
    else
      local dp = resolve_port(r.dst_dev)
      if dp then dsts[#dsts + 1] = dp end
    end

    if #dsts == 0 then goto next_rule end

    local mask = 0
    if r.note       then mask = mask | TYPE_NOTE  end
    if r.cc         then mask = mask | TYPE_CC    end
    if r.pc         then mask = mask | TYPE_PC    end
    if r.pitchbend  then mask = mask | TYPE_PB    end
    if r.aftertouch then mask = mask | TYPE_AT    end
    if r.clock      then mask = mask | TYPE_CLOCK; _any_clock = true end

    local dst_ch = nil
    if type(r.dst_ch) == "number" then
      dst_ch = (r.dst_ch - 1) & 0x0F
    end

    _cache[#_cache + 1] = {
      src_port  = src_port,
      src_ch    = (r.src_ch ~= "all") and r.src_ch or nil,
      dst_ports = dsts,
      mask      = mask,
      dst_ch    = dst_ch,
      sysex     = r.sysex or false,
    }

    ::next_rule::
  end
end

function Core.rebuild_cache() build_cache() end
function Core._get_cache() return _cache end

-- ─── Channel remap ───────────────────────────────────────────────────────

-- FIX (BUG-01): Return a freshly allocated table on every call instead of
-- writing into the shared module-level buffers _buf2 / _buf3 and returning
-- a reference to them. The old code was a latent data-corruption bug: when
-- multiple rules matched the same event with different dst_ch values, the
-- second rule's write into the shared buffer happened before send_safe()
-- finished using the first rule's data, causing the first send to transmit
-- the second rule's channel byte. Allocating a new table per call is safe
-- at the cost of slightly more GC pressure (acceptable on norns hardware).
local function remap_channel(data, b0_remapped, len)
  if len == 3 then
    return { b0_remapped, data[2], data[3] }  -- FIX (BUG-01): new table, not _buf3 reference
  elseif len == 2 then
    return { b0_remapped, data[2] }            -- FIX (BUG-01): new table, not _buf2 reference
  end
  local out = { b0_remapped }
  for i = 2, len do out[i] = data[i] end
  return out
end

-- ─── Route channel messages ──────────────────────────────────────────────

local function route_midi(src_port, data)
  local b0  = data[1]
  local len = #data

  if b0 >= 0xF8 then
    if not _any_clock then return end
    for _, c in ipairs(_cache) do
      if (c.mask & TYPE_CLOCK) ~= 0 then  -- FIX (BUG-08): explicit parentheses around bitwise & operand for clarity (& already has higher precedence than ~= in Lua 5.3, but parentheses prevent misreading)
        if not c.src_port or c.src_port == src_port then
          for _, dp in ipairs(c.dst_ports) do
            if dp ~= src_port then
              local dev = Core.devices[dp]
              if dev then send_safe(dev.connect, data) end
            end
          end
        end
      end
    end
    return
  end

  local stype = b0 & 0xF0
  local tmask
  if     stype == 0x80 or stype == 0x90 then tmask = TYPE_NOTE
  elseif stype == 0xB0                  then tmask = TYPE_CC
  elseif stype == 0xC0                  then tmask = TYPE_PC
  elseif stype == 0xE0                  then tmask = TYPE_PB
  elseif stype == 0xA0 or stype == 0xD0 then tmask = TYPE_AT
  else   return
  end

  local sch = (b0 & 0x0F) + 1

  for _, c in ipairs(_cache) do
    if c.src_port and c.src_port ~= src_port then goto cont end
    if c.src_ch   and c.src_ch   ~= sch      then goto cont end
    if (c.mask & tmask) == 0                  then goto cont end  -- FIX (BUG-08): explicit parentheses around bitwise & operand for clarity (& already has higher precedence than == in Lua 5.3, but parentheses prevent misreading)

    for _, dp in ipairs(c.dst_ports) do
      if dp ~= src_port then
        local dev = Core.devices[dp]
        if dev then
          if c.dst_ch then
            send_safe(dev.connect,
              remap_channel(data, (b0 & 0xF0) | c.dst_ch, len))
          else
            send_safe(dev.connect, data)
          end
        end
      end
    end
    ::cont::
  end
end

-- ─── Route SysEx ─────────────────────────────────────────────────────────

local function route_sysex(src_port, data)
  if Core.sysex_debug then
    print(string.format("[midirouter] SysEx route port%d len=%d",
      src_port, #data))
  end
  for i, c in ipairs(_cache) do
    if c.sysex then
      if not c.src_port or c.src_port == src_port then
        for _, dp in ipairs(c.dst_ports) do
          if dp ~= src_port then
            local dev = Core.devices[dp]
            if dev then
              if Core.sysex_debug then
                print(string.format("[midirouter] SysEx rule%d: port%d -> port%d",
                  i, src_port, dp))
              end
              send_safe(dev.connect, data)
            end
          end
        end
      end
    end
  end
end

-- ─── SysEx accumulator (per-path, byte-by-byte) ─────────────────────────

local function sx_reset(acc)
  acc.buf    = {}
  acc.active = false
end

local function sx_ensure(tbl, port)
  if not tbl[port] then
    tbl[port] = { buf = {}, active = false, started = 0 }
  end
  return tbl[port]
end

local function accumulate_sysex(acc, port, data, tag)
  if not data or #data == 0 then return false end

  local now = util.time()  -- FIX (KNOWN-03): was os.time() (integer seconds) which gives up to ~3s effective timeout instead of 2.0s due to integer truncation. util.time() returns a float with sub-second precision for accurate SYSEX_TIMEOUT comparisons.
  local any_consumed = false

  for i = 1, #data do
    local byte = data[i]

    if acc.active and (now - acc.started) > SYSEX_TIMEOUT then
      if Core.sysex_debug then
        print(string.format("[midirouter] SysEx timeout port%d (%s), discarding %d bytes",
          port, tag, #acc.buf))
      end
      sx_reset(acc)
    end

    if byte == 0xF0 then
      acc.active  = true
      acc.buf     = { 0xF0 }
      acc.started = now
      any_consumed = true
      if Core.sysex_debug then
        print(string.format("[midirouter] SysEx START port%d (%s)", port, tag))
      end

    elseif acc.active then
      if byte == 0xF7 then
        acc.buf[#acc.buf + 1] = 0xF7
        if Core.sysex_debug then
          print(string.format("[midirouter] SysEx END port%d (%s) len=%d",
            port, tag, #acc.buf))
        end
        route_sysex(port, acc.buf)
        sx_reset(acc)
        any_consumed = true
      elseif byte >= 0xF8 then  -- luacheck: ignore
        -- Realtime bytes (clock, start, stop etc.) are transparent per MIDI spec;
        -- they must not interrupt SysEx accumulation, so we intentionally do nothing.
      elseif byte >= 0x80 then
        if Core.sysex_debug then
          print(string.format("[midirouter] SysEx aborted port%d (%s) by 0x%02X",
            port, tag, byte))
        end
        sx_reset(acc)
      else
        -- FIX (v1.03): guard against unbounded accumulation from malformed SysEx
        if #acc.buf >= SYSEX_MAX_LEN then
          if Core.sysex_debug then
            print(string.format("[midirouter] SysEx too long port%d (%s), discarding %d bytes",
              port, tag, #acc.buf))
          end
          sx_reset(acc)
        else
          acc.buf[#acc.buf + 1] = byte
          any_consumed = true
        end
      end
    end
  end

  return any_consumed
end

-- ─── Path A: _norns.midi.event → handle_event ───────────────────────────

function Core.handle_event(id, data)
  if not data or #data == 0 then return end

  local src_port = Core.id_to_port[id]
  if not src_port then return end

  -- FIX (BUG-12): midi.vports[port] is nil at system_post_startup because
  -- norns allocates vports lazily on first MIDI arrival, not on midi.connect().
  -- The deferred retry in install_sysex_handlers() fires too early (0.5s after
  -- boot, before any MIDI arrives) and always finds the vport still nil.
  -- By installing here we catch the exact moment the vport becomes available:
  -- norns calls _norns.midi.event BEFORE vp.event for the same MIDI packet, so
  -- a handler installed here will fire for this very packet via vp.event.
  local _vp_lazy = midi.vports[src_port]
  if _vp_lazy and (not _sx_handlers[src_port]
      or _vp_lazy.event ~= _sx_handlers[src_port]) then
    Core.install_sysex_handlers()
  end

  local acc = sx_ensure(_sx_ev, src_port)
  local b0  = data[1]

  -- Fast path: no active SysEx and not starting one
  if not acc.active and b0 ~= 0xF0 then
    route_midi(src_port, data)
    return
  end

  -- Byte-by-byte processing for SysEx-involved chunks
  local midi_buf = nil

  for i = 1, #data do
    local byte = data[i]
    local now  = util.time()  -- FIX (KNOWN-03): was os.time() (integer seconds) which gives up to ~3s effective timeout instead of 2.0s due to integer truncation. util.time() returns a float with sub-second precision for accurate SYSEX_TIMEOUT comparisons.

    if acc.active and (now - acc.started) > SYSEX_TIMEOUT then
      if Core.sysex_debug then
        print(string.format("[midirouter] SysEx timeout port%d (ev), discarding %d bytes",
          src_port, #acc.buf))
      end
      sx_reset(acc)
    end

    if byte == 0xF0 then
      if midi_buf then route_midi(src_port, midi_buf); midi_buf = nil end
      acc.active  = true
      acc.buf     = { 0xF0 }
      acc.started = now
      -- FIX (BUG-04): Set _sx_seen_ev tentatively at the START of a SysEx
      -- transfer (0xF0 byte) rather than only at completion (0xF7). The Lua
      -- vp.event handler fires with the complete SysEx packet, potentially
      -- before Path A finishes accumulating byte-by-byte. By marking the port
      -- as "seen" on the opening byte we prevent Path B from routing a
      -- duplicate for this transfer even if vp.event fires first.
      -- NOTE: For virtual/TRS devices we intentionally skip Path A routing
      -- (handled below at 0xF7), so we must NOT set the flag here for them —
      -- check is deferred to the 0xF7 handler as before for that branch.
      local dev_name_f0 = Core.devices[src_port] and Core.devices[src_port].name or ""
      if dev_name_f0 ~= "virtual" then
        _sx_seen_ev[src_port] = true  -- FIX (BUG-04): tentative early flag to block Path B duplicate
      end
      if Core.sysex_debug then
        print(string.format("[midirouter] SysEx START port%d (ev)", src_port))
      end

    elseif acc.active then
      if byte == 0xF7 then
        acc.buf[#acc.buf + 1] = 0xF7
        if Core.sysex_debug then
          print(string.format("[midirouter] SysEx END port%d (ev) len=%d",
            src_port, #acc.buf))
        end
        local dev_name = Core.devices[src_port] and Core.devices[src_port].name or ""
        if dev_name == "virtual" then
          -- Prefer Path B (vp.event) for TRS/virtual devices. Fall back to
          -- Path A if the handler is still missing after the lazy install above
          -- (guards against vp.event firing before _norns.midi.event on some
          -- norns builds, or any other edge case where the handler is absent).
          local _vp_now = midi.vports[src_port]
          local _handler_ok = _vp_now and _sx_handlers[src_port]
            and _vp_now.event == _sx_handlers[src_port]
          if not _handler_ok then
            if Core.sysex_debug then
              print(string.format("[midirouter] SysEx fallback route port%d (no vp handler)", src_port))
            end
            route_sysex(src_port, acc.buf)
          end
          -- handler_ok: vp.event will route
        else
          -- FIX (BUG-04): _sx_seen_ev[src_port] is already set at 0xF0 above
          -- for non-virtual devices. Keep the assignment here as well so the
          -- flag is definitely set if the 0xF0 branch somehow ran without it
          -- (defensive: belt-and-suspenders).
          _sx_seen_ev[src_port] = true
          route_sysex(src_port, acc.buf)
          -- FIX (BUG-04 / BUG-11): Reset flag to nil immediately after routing
          -- so that _sx_seen_ev applies per-transfer only. If Path A fails on
          -- the NEXT SysEx (e.g., after a device reconnect), Path B is free to
          -- handle it rather than being permanently suppressed by a stale flag.
          _sx_seen_ev[src_port] = nil
        end
        sx_reset(acc)
      elseif byte >= 0xF8 then
        route_midi(src_port, { byte })
      elseif byte >= 0x80 then
        if Core.sysex_debug then
          print(string.format("[midirouter] SysEx aborted port%d (ev) by 0x%02X",
            src_port, byte))
        end
        sx_reset(acc)
        _sx_seen_ev[src_port] = nil  -- FIX (KNOWN-01): clear tentative flag set at 0xF0 so Path B is not permanently suppressed after a SysEx abort
        midi_buf = { byte }
      else
        -- FIX (v1.03): guard against unbounded accumulation
        if #acc.buf >= SYSEX_MAX_LEN then
          if Core.sysex_debug then
            print(string.format("[midirouter] SysEx too long port%d (ev), discarding %d bytes",
              src_port, #acc.buf))
          end
          sx_reset(acc)
          _sx_seen_ev[src_port] = nil
        else
          acc.buf[#acc.buf + 1] = byte
        end
      end

    else
      if not midi_buf then midi_buf = {} end
      midi_buf[#midi_buf + 1] = byte
    end
  end

  if midi_buf then route_midi(src_port, midi_buf) end
end

-- ─── HOOK _norns.midi.event AT MODULE LOAD TIME ─────────────────────────
-- This is the critical pattern from passthrough: hook immediately when
-- the module is loaded, not in a lifecycle callback.

local _orig_midi_event = _norns.midi.event

_norns.midi.event = function(id, data)
  _orig_midi_event(id, data)
  Core.handle_event(id, data)
end

print("[midirouter] _norns.midi.event hooked")

-- ─── Path B: vp.event handler ────────────────────────────────────────────

local function make_sysex_handler(port)
  -- FIX (BUG-02): Capture any pre-existing vp.event handler so we can chain
  -- it. The original code did vp.event = _sx_handlers[port] unconditionally,
  -- silently discarding whatever handler was already installed. This broke
  -- scripts that set their own vp.event handler, and caused double-install
  -- problems when scan_devices() ran again after a script reload. By saving
  -- and calling the original handler first, both the script's handler and
  -- midirouter's SysEx routing can coexist. We intentionally capture the
  -- CURRENT handler at make_sysex_handler() call time (not at vp.event
  -- assignment time) so the closure holds a stable reference.
  local vp = midi.vports[port]
  -- Only chain if there is an existing handler AND it is not already one of
  -- our own handlers (prevents double-chaining on repeated scan_devices calls).
  local existing = vp and vp.event
  local orig = (existing ~= _sx_handlers[port]) and existing or nil  -- FIX (BUG-02): avoid chaining our own old handler onto itself

  return function(data)
    if orig then orig(data) end  -- FIX (BUG-02): call original handler first so scripts retain their vp.event functionality
    if not data or #data == 0 then return end
    local dev_name = Core.devices[port] and Core.devices[port].name or ""
    -- For "virtual" (TRS) port we always use vp path only; for others avoid duplicate.
    if dev_name ~= "virtual" and _sx_seen_ev[port] then return end
    local acc = sx_ensure(_sx_vp, port)
    if data[1] == 0xF0 or acc.active then
      accumulate_sysex(acc, port, data, "vp")
    end
  end
end

function Core.install_sysex_handlers()
  for port, _ in pairs(Core.devices) do
    local vp = midi.vports[port]
    if vp then
      sx_ensure(_sx_vp, port)
      _sx_handlers[port] = make_sysex_handler(port)
      vp.event = _sx_handlers[port]
    else
      -- vport not yet allocated; handle_event() will install the handler
      -- lazily the moment the first MIDI packet arrives (BUG-12 fix).
      if Core.debug then
        print(string.format("[midirouter] vport %d not ready at scan time, will install on first MIDI", port))
      end
    end
  end
end

-- ─── Device scan ─────────────────────────────────────────────────────────

function Core.scan_devices()
  -- Force norns to refresh its device list
  if midi.update_devices then midi.update_devices() end

  -- FIX (BUG-03): Reset _sx_seen_ev completely at the start of every scan.
  -- The old code never cleared this table: once a port was marked as having
  -- successfully routed SysEx via Path A, it remained marked permanently —
  -- even after the device was unplugged and reconnected. If Path A then failed
  -- for the reconnected device (e.g., due to a UART glitch), Path B was still
  -- suppressed, causing a complete SysEx outage. By resetting the table here
  -- we ensure that each scan starts with a clean slate so both paths get a
  -- fair chance on the next SysEx transfer.
  _sx_seen_ev = {}  -- FIX (BUG-03): reset per-port seen flags on every rescan

  local id_map   = {}
  local name_map = {}
  local devs     = {}
  for _, dev in pairs(midi.devices) do
    if dev.port ~= nil then
      local name = dev.name or ("Device " .. dev.port)
      id_map[dev.id] = dev.port
      name_map[name] = dev.port

      -- FIX (BUG-05): Reuse the existing midi.connect() object when the port
      -- has not changed instead of calling midi.connect() unconditionally.
      -- The original code created a new connection object on every scan_devices()
      -- call (which runs on every device add/remove and every script clear).
      -- If midi.connect() registers internal callbacks or file descriptors,
      -- each call leaks those resources. On norns with limited RAM and frequent
      -- hot-plug events this can cause memory exhaustion over time.
      local existing_dev = Core.devices[dev.port]
      local conn
      if existing_dev and existing_dev.port == dev.port and existing_dev.connect then
        conn = existing_dev.connect  -- FIX (BUG-05): reuse existing connection object
      else
        conn = midi.connect(dev.port)  -- FIX (BUG-05): only allocate a new connection when the port is genuinely new
      end

      devs[dev.port] = {
        id      = dev.id,
        name    = name,
        port    = dev.port,
        connect = conn,
      }
      sx_ensure(_sx_ev, dev.port)
      sx_ensure(_sx_vp, dev.port)
    end
  end
  Core.devices      = devs
  Core.id_to_port   = id_map
  Core.name_to_port = name_map

  -- FIX (v1.01): Remove accumulator entries for ports that are no longer
  -- connected. Previously _sx_ev and _sx_vp grew indefinitely with entries
  -- for disconnected ports, since sx_ensure() only ever added entries and
  -- scan_devices() never pruned stale ones. On a device with frequent
  -- connect/disconnect cycles this caused unbounded memory growth.
  for port in pairs(_sx_ev) do if not devs[port] then _sx_ev[port] = nil end end
  for port in pairs(_sx_vp) do if not devs[port] then _sx_vp[port] = nil end end

  build_cache()
  Core.install_sysex_handlers()
end

-- ─── Device name helpers ─────────────────────────────────────────────────

function Core.device_name(dev_ref)
  if dev_ref == "all" then return "all" end
  if type(dev_ref) == "string" then return dev_ref end
  if type(dev_ref) == "number" then
    local d = Core.devices[dev_ref]
    return d and d.name or ("port " .. tostring(dev_ref))
  end
  return tostring(dev_ref)
end

function Core.device_label(dev_ref, maxlen)
  maxlen = maxlen or 12
  local nm = Core.device_name(dev_ref)
  if nm == "all" then return "all" end
  if #nm <= maxlen then return nm end
  local tail = 4
  local head = maxlen - tail - 2
  if head < 3 then head = 3 end
  return nm:sub(1, head) .. ".." .. nm:sub(-tail)
end

function Core.device_names()
  local names = {}
  local ports = {}
  for port, _ in pairs(Core.devices) do ports[#ports + 1] = port end
  table.sort(ports)
  for _, port in ipairs(ports) do
    names[#names + 1] = Core.devices[port].name
  end
  return names
end

-- ─── Rules ───────────────────────────────────────────────────────────────

function Core.default_rule()
  local names = Core.device_names()
  return {
    enabled    = true,
    src_dev    = names[1] or "all",
    src_ch     = "all",
    dst_dev    = names[2] or "all",
    dst_ch     = "same",
    note       = true,
    cc         = true,
    pc         = true,
    pitchbend  = true,
    aftertouch = true,
    clock      = false,
    sysex      = false,
  }
end

function Core.add_rule(r)
  if #Core.rules >= MAX_RULES then
    print("[midirouter] max " .. MAX_RULES .. " rules")
    return nil
  end
  Core.rules[#Core.rules + 1] = r or Core.default_rule()
  build_cache()
  return #Core.rules
end

function Core.remove_rule(i)
  if Core.rules[i] then
    table.remove(Core.rules, i)
    build_cache()
  end
end

-- ─── Persistence ─────────────────────────────────────────────────────────

function Core.save()
  -- FIX (v1.03): check mkdir return value
  local ok = os.execute("mkdir -p " .. SAVE_DIR)
  if not ok then
    print("[midirouter] WARNING: could not create save directory " .. SAVE_DIR)
    return
  end
  local f = io.open(SAVE_FILE, "r")
  if f then
    f:close()
    os.rename(SAVE_FILE, SAVE_BACKUP)
  end
  -- FIX (v1.03): check tab.save return value
  local saved = tab.save(Core.rules, SAVE_FILE)
  if not saved then
    print("[midirouter] WARNING: failed to save rules to " .. SAVE_FILE)
  end
end

function Core.save_deferred()
  if _save_clock then clock.cancel(_save_clock) end
  _save_clock = clock.run(function()
    clock.sleep(SAVE_DELAY)
    Core.save()
    _save_clock = nil
  end)
end

function Core.load()
  local f = io.open(SAVE_FILE, "r")
  if not f then return false end
  f:close()
  local loaded = tab.load(SAVE_FILE)
  if not loaded or type(loaded) ~= "table" then
    print("[midirouter] primary save corrupt, trying backup...")
    loaded = tab.load(SAVE_BACKUP)
    if not loaded or type(loaded) ~= "table" then return false end
  end

  -- Migrate old formats
  local migrated = false
  for _, r in ipairs(loaded) do
    if r.src_port and not r.src_dev then r.src_dev = r.src_port; r.src_port = nil; migrated = true end
    if r.dst_port and not r.dst_dev then r.dst_dev = r.dst_port; r.dst_port = nil; migrated = true end
    if type(r.src_dev) == "number" then
      local d = Core.devices[r.src_dev]
      if d then r.src_dev = d.name; migrated = true
      else
        -- FIX (BUG-09): Warn when a src_dev port number cannot be resolved to
        -- a device name during migration. The old code silently fell back to
        -- "all" which could cause a rule that previously targeted a specific
        -- device to suddenly route to every connected device — a potentially
        -- damaging and invisible change. The print() here alerts the user via
        -- maiden/norns logs so they know to check and correct the affected rule.
        print(string.format("[midirouter] WARNING: src port %d not connected during migration, rule set to 'all'", r.src_dev))  -- FIX (BUG-09): print warning before silent fallback to "all"
        r.src_dev = "all"; migrated = true
      end
    end
    if type(r.dst_dev) == "number" then
      local d = Core.devices[r.dst_dev]
      if d then r.dst_dev = d.name; migrated = true
      else
        -- FIX (BUG-09): Same warning for dst_dev. Identical reasoning to the
        -- src_dev case above — silent data loss is worse than a noisy log line.
        print(string.format("[midirouter] WARNING: dst port %d not connected during migration, rule set to 'all'", r.dst_dev))  -- FIX (BUG-09): print warning before silent fallback to "all"
        r.dst_dev = "all"; migrated = true
      end
    end
  end

  Core.rules = loaded
  build_cache()

  if migrated then
    print("[midirouter] migrated rules to name-based format")
    Core.save()
  end

  print("[midirouter] loaded " .. #Core.rules .. " rules")
  return true
end

-- ─── Diagnostics ─────────────────────────────────────────────────────────

function Core.diag()
  print("=== midirouter v1.03 ===")
  print("  cached rules:      " .. #_cache)
  print("  total rules:       " .. #Core.rules)
  print("  save pending:      " .. tostring(_save_clock ~= nil))

  print("  devices:")
  for port, d in pairs(Core.devices) do
    local ev = _sx_ev[port]
    local vp_acc = _sx_vp[port]
    local ev_st = ev and ev.active and "accumulating" or "idle"
    local vp_st = vp_acc and vp_acc.active and "accumulating" or "idle"
    local vp = midi.vports[port]
    local h_ok = vp and (vp.event == _sx_handlers[port]) or false
    print(string.format("    port %d: %s (id=%s, sx_ev=%s, sx_vp=%s, handler=%s)",
      port, d.name, tostring(d.id), ev_st, vp_st,
      h_ok and "OK" or "MISSING"))
  end

  print("  name_to_port:")
  for name, port in pairs(Core.name_to_port) do
    print(string.format("    '%s' -> port %d", name, port))
  end

  print("  rules:")
  for i, r in ipairs(Core.rules) do
    local sp = resolve_port(r.src_dev)
    local dp = resolve_port(r.dst_dev)
    print(string.format("    R%d [%s] '%s'(p%s) ch%s -> '%s'(p%s) ch%s  SX=%s CLK=%s",
      i, r.enabled and "ON " or "off",
      tostring(r.src_dev), sp and tostring(sp) or "?", tostring(r.src_ch),
      tostring(r.dst_dev), dp and tostring(dp) or "?", tostring(r.dst_ch),
      tostring(r.sysex), tostring(r.clock)))
  end
  print("=========================")
end

return Core
