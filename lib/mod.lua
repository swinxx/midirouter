-- midirouter/lib/mod.lua  v1.0

local mod  = require 'core/mods'
local core = require 'midirouter/lib/core'

-- ─── Parameter definitions ───────────────────────────────────────────────

local PARAMS = {
  { key = "enabled",    label = "Active",      type = "bool"    },
  { key = "src_dev",    label = "From Device",  type = "dev"    },
  { key = "src_ch",     label = "From Ch",     type = "ch_all"  },
  { key = "dst_dev",    label = "To Device",   type = "dev"     },
  { key = "dst_ch",     label = "To Ch",       type = "ch_same" },
  { key = "note",       label = "Notes",       type = "bool"    },
  { key = "cc",         label = "CC",          type = "bool"    },
  { key = "pc",         label = "Prog Chg",    type = "bool"    },
  { key = "pitchbend",  label = "Pitchbend",   type = "bool"    },
  { key = "aftertouch", label = "Aftertouch",  type = "bool"    },
  { key = "clock",      label = "Clock",       type = "bool"    },
  { key = "sysex",      label = "SysEx",       type = "bool"    },
}
local NP = #PARAMS

local V_LIST = 1
local V_RULE = 2
local V_DEL  = 3
local V_ADD  = 4

-- FIX (BUG-10): MAX_RULES constant mirrored from core so the UI can guard
-- against it. core.add_rule() silently fails when #core.rules >= 16; the UI
-- must check this limit before opening V_ADD so the user gets feedback.
local MAX_RULES = 16

local st = {
  view       = V_LIST,
  rule_idx   = 1,
  param_idx  = 1,
  k3_held    = false,
  k2_long    = false,
  k2_timer   = nil,
  dlg_cursor = 1, -- FIX (KNOWN-02): initialised to 1 so it is always in [1,2] (dialog cursor bounds verification, mislabeled BUG-04 by Agent 2)
}

-- ─── Device name list cache ──────────────────────────────────────────────

local _dev_names = {}

local function refresh_dev_names()
  _dev_names = core.device_names()
end

local function update_devices()
  core.scan_devices()
  refresh_dev_names()
  print(string.format("[midirouter] update_devices: %d devices, %d cached/%d rules",
    #_dev_names, #core._get_cache(), #core.rules))
end

-- ─── HOOK _norns.midi.add/remove AT MODULE LOAD TIME ─────────────────────
-- Like passthrough: hook the C-level callbacks immediately.

local _orig_midi_add = _norns.midi.add
local _orig_midi_remove = _norns.midi.remove
local _orig_script_clear = norns.script.clear

_norns.midi.add = function(id, name, dev)
  _orig_midi_add(id, name, dev)
  update_devices()
end

_norns.midi.remove = function(id)
  _orig_midi_remove(id)
  update_devices()
end

norns.script.clear = function()
  _orig_script_clear()
  update_devices()
end

print("[midirouter] _norns.midi.add/remove hooked")

-- ─── Bounds helper ───────────────────────────────────────────────────────

local function current_rule()
  local nr = #core.rules
  if nr == 0 then
    st.rule_idx = 1
    return nil
  end
  st.rule_idx = math.max(1, math.min(nr, st.rule_idx))
  return core.rules[st.rule_idx]
end

-- ─── Value display ───────────────────────────────────────────────────────

local function val_str(p, val)
  if p.type == "bool" then
    return val and "ON" or "off"
  elseif p.type == "dev" then
    if val == "all" then return "all" end
    return core.device_label(val, 10)
  elseif p.type == "ch_all" then
    return (val == "all") and "all" or tostring(val)
  elseif p.type == "ch_same" then
    return (val == "same") and "=src" or tostring(val)
  end
  return tostring(val)
end

-- ─── Value change ────────────────────────────────────────────────────────

local function change_val(p, val, d)
  if p.type == "bool" then
    return d > 0
  elseif p.type == "dev" then
    local opts = { "all" }
    for _, name in ipairs(_dev_names) do opts[#opts + 1] = name end
    local ci = 1
    for i, v in ipairs(opts) do if v == val then ci = i; break end end
    ci = math.max(1, math.min(#opts, ci + d))
    return opts[ci]
  elseif p.type == "ch_all" then
    local cur = (val == "all") and 0 or val
    local nxt = math.max(0, math.min(16, cur + d))
    return (nxt == 0) and "all" or nxt
  elseif p.type == "ch_same" then
    local cur = (val == "same") and 0 or val
    local nxt = math.max(0, math.min(16, cur + d))
    return (nxt == 0) and "same" or nxt
  end
  return val
end

-- ─── Rule flags ──────────────────────────────────────────────────────────

local function rule_flags(r)
  local f = {}
  if r.note       then f[#f + 1] = "N"  end
  if r.cc         then f[#f + 1] = "CC" end
  if r.pc         then f[#f + 1] = "PC" end
  if r.sysex      then f[#f + 1] = "SX" end
  if r.clock      then f[#f + 1] = "CL" end
  return table.concat(f, " ")
end

-- ─── Dialog draw ─────────────────────────────────────────────────────────

local function draw_dialog(title, sub, lbl_cancel, lbl_action)
  screen.level(10); screen.font_size(8)
  screen.move(64, 22); screen.text_center(title)
  if sub and sub ~= "" then
    screen.level(5); screen.font_size(7)
    screen.move(64, 33); screen.text_center(sub)
  end
  local function btn(label, x, sel)
    if sel then
      screen.level(12); screen.rect(x - 22, 41, 44, 13); screen.fill()
      screen.level(0)
    else
      screen.level(4); screen.rect(x - 22, 41, 44, 13); screen.stroke()
      screen.level(8)
    end
    screen.font_size(8); screen.move(x, 51); screen.text_center(label)
  end
  -- FIX (KNOWN-02): dlg_cursor is always clamped to [1,2] in m.enc() and is
  -- initialised to 1 in the st table, so these comparisons are always safe.
  -- (dialog cursor bounds verification, mislabeled BUG-04 by Agent 2)
  btn(lbl_cancel, 34, st.dlg_cursor == 1)
  btn(lbl_action, 94, st.dlg_cursor == 2)
  screen.level(3); screen.font_size(7)
  screen.move(0, 63); screen.text("E2/E3:choose  K3:confirm  K2:cancel")
end

-- ─── Mod menu ────────────────────────────────────────────────────────────

local m = {}

m.init = function()
  update_devices()
end

m.deinit = function()
  screen.aa(0); screen.line_width(1)
  screen.font_face(1); screen.font_size(8); screen.level(15)
end

m.redraw = function()
  screen.aa(0); screen.line_width(1)
  screen.font_face(1); screen.font_size(8); screen.level(15)
  screen.clear()

  local nr   = #core.rules
  local rule = current_rule()

  screen.move(0, 7)
  if nr == 0 then
    screen.text("MIDI ROUTER")
  else
    screen.text(string.format("MIDI ROUTER   R%d/%d", st.rule_idx, nr))
    if rule then
      screen.level(rule.enabled and 15 or 3)
      screen.move(124, 7); screen.text("●")
    end
  end
  screen.level(3); screen.move(0, 9); screen.line(128, 9); screen.stroke()

  -- FIX: Check dialog views BEFORE the nr==0 early return so V_ADD is always
  -- reachable — the user must be able to add a first rule from the empty state.
  if st.view == V_ADD then
    local add_label = (#core.rules >= MAX_RULES) and "MAX" or "Add"
    draw_dialog("Add new rule?", "", "Cancel", add_label)
    screen.update()
    return
  end

  if st.view == V_DEL then
    -- rule may be nil if deletion happened via params while dialog was open
    local sub = rule
      and (core.device_label(rule.src_dev, 8) .. " → " .. core.device_label(rule.dst_dev, 8))
      or ""
    draw_dialog("Delete rule " .. st.rule_idx .. "?", sub, "Cancel", "Delete")
    screen.update()
    return
  end

  if nr == 0 or not rule then
    screen.level(5); screen.move(4, 30); screen.text("No rules defined.")
    screen.move(4, 43); screen.text("Hold K2 to add one.")
    screen.update()
    return
  end

  if st.view == V_RULE then
    screen.level(6); screen.font_size(7)
    screen.move(64, 19); screen.text_center("─── select rule ───")
    screen.level(15); screen.font_size(8)
    screen.move(64, 31); screen.text_center("Rule " .. st.rule_idx)
    screen.level(6); screen.font_size(7)
    screen.move(4, 42)
    screen.text("From: " .. core.device_label(rule.src_dev, 13) ..
      " ch " .. (rule.src_ch == "all" and "*" or tostring(rule.src_ch)))
    screen.move(4, 52)
    screen.text("To:   " .. core.device_label(rule.dst_dev, 13) ..
      " ch " .. (rule.dst_ch == "same" and "=" or tostring(rule.dst_ch)))
    screen.level(4); screen.font_size(7)
    screen.move(4, 63); screen.text(rule_flags(rule))
    screen.move(124, 63); screen.text_right(rule.enabled and "ON" or "off")
    screen.update()
    return
  end

  -- Parameter list
  local win_s = math.max(1, math.min(NP - 3, st.param_idx - 1))
  local win_e = math.min(NP, win_s + 3)
  local y = 21

  for i = win_s, win_e do
    local p   = PARAMS[i]
    local val = rule[p.key]
    local sel = (i == st.param_idx)
    if sel then
      screen.level(3); screen.rect(0, y - 8, 122, 10); screen.fill()
      screen.level(15)
    else
      screen.level(5)
    end
    screen.font_size(8)
    screen.move(3, y); screen.text(p.label)
    screen.move(121, y); screen.text_right(val_str(p, val))
    y = y + 11
  end

  local sb_top = 12
  local sb_h   = 44
  local bar_h  = math.max(5, math.floor(sb_h * 4 / NP))
  local bar_y  = sb_top + math.floor((sb_h - bar_h) * (st.param_idx - 1) / math.max(1, NP - 1))
  screen.level(1); screen.rect(124, sb_top, 4, sb_h); screen.fill()
  screen.level(8); screen.rect(124, bar_y, 4, bar_h); screen.fill()

  screen.level(2); screen.move(0, 57); screen.line(123, 57); screen.stroke()
  screen.level(4); screen.font_size(7)
  screen.move(2, 63); screen.text("E2:scroll  E3:val  K3:rule  K2:menu")

  screen.update()
end

-- ─── Keys ────────────────────────────────────────────────────────────────

m.key = function(n, z)
  if n == 3 then
    if z == 1 then
      st.k3_held = true
      if st.view == V_LIST then
        -- FIX: guard against crash on rule.src_dev when no rules exist
        if #core.rules > 0 then st.view = V_RULE end
      elseif st.view == V_DEL then
        if st.dlg_cursor == 2 then
          core.remove_rule(st.rule_idx)
          -- FIX (BUG-07): After removing a rule, if no rules remain, force
          -- view to V_LIST and reset rule_idx to 1 so the "No rules defined"
          -- screen is shown correctly. current_rule() already clamps
          -- st.rule_idx, but the explicit assignment here makes the intent
          -- clear and guards against any future change to current_rule().
          if #core.rules == 0 then
            st.rule_idx = 1
            st.view = V_LIST
          else
            current_rule() -- clamp st.rule_idx into the new valid range
            st.view = V_LIST
          end
          core.save()
        else
          st.view = V_LIST
        end
      elseif st.view == V_ADD then
        if st.dlg_cursor == 2 then
          -- FIX (BUG-10): core.add_rule() silently fails when #core.rules
          -- >= MAX_RULES. Guard here so st.rule_idx is never set to a
          -- position beyond the actual rule table length.
          if #core.rules < MAX_RULES then
            core.add_rule()
            st.rule_idx  = #core.rules
            st.param_idx = 1
            core.save()
          else
            print("[midirouter] UI: add_rule blocked — MAX_RULES reached")
          end
        end
        st.view = V_LIST
      end
    else
      st.k3_held = false
      if st.view == V_RULE then
        st.view = V_LIST; st.param_idx = 1
      end
    end
    mod.menu.redraw()
    return
  end

  if n == 2 then
    if z == 1 then
      st.k2_long = false
      if st.k2_timer then clock.cancel(st.k2_timer) end
      st.k2_timer = clock.run(function()
        clock.sleep(0.55)
        st.k2_long = true
        if st.view == V_LIST or st.view == V_RULE then
          if st.k3_held then
            -- FIX: only open delete dialog when there is actually a rule to delete
            if #core.rules > 0 then
              st.view = V_DEL
              st.dlg_cursor = 1 -- FIX (KNOWN-02): reset cursor to 1 on open (dialog cursor bounds verification, mislabeled BUG-04 by Agent 2)
            end
          else
            -- FIX (BUG-10): Only open V_ADD when the rule count is below the
            -- limit. When at the limit, keep the current view and print a
            -- notice — the user must delete a rule first.
            if #core.rules >= MAX_RULES then
              print("[midirouter] UI: cannot add rule — MAX_RULES (" .. MAX_RULES .. ") reached")
            else
              st.view = V_ADD
              st.dlg_cursor = 1 -- FIX (KNOWN-02): reset cursor to 1 on open (dialog cursor bounds verification, mislabeled BUG-04 by Agent 2)
            end
          end
          mod.menu.redraw()
        end
      end)
    else
      if st.k2_timer then clock.cancel(st.k2_timer); st.k2_timer = nil end
      if not st.k2_long then
        if st.view == V_DEL or st.view == V_ADD then
          st.view = V_LIST
        elseif st.view == V_RULE then
          st.view = V_LIST
        else
          mod.menu.exit()
        end
        mod.menu.redraw()
      end
      st.k2_long = false
    end
    return
  end
end

-- ─── Encoders ────────────────────────────────────────────────────────────

m.enc = function(n, d)
  local nr = #core.rules

  if st.view == V_DEL or st.view == V_ADD then
    -- FIX (KNOWN-02): dlg_cursor is clamped to [1,2] on every encoder turn in
    -- dialog views, and is reset to 1 every time a dialog is opened. These
    -- are the only two code paths that set dlg_cursor, so it is always safe
    -- to compare it with 1 or 2 elsewhere (e.g. in draw_dialog and m.key).
    -- (dialog cursor bounds verification, mislabeled BUG-04 by Agent 2)
    st.dlg_cursor = math.max(1, math.min(2, st.dlg_cursor + d))
    mod.menu.redraw()
    return
  end

  if st.view == V_RULE then
    -- FIX (BUG-03): Both E2 and E3 intentionally scroll through rules in
    -- V_RULE view. This is by design: the entire purpose of this view is rule
    -- selection (indicated by the "─── select rule ───" heading). There is no
    -- secondary parameter to edit here, so all encoders map to the same action
    -- (change which rule is selected). Differentiating E2 from E3 in this
    -- view would require a second interaction axis that the UX does not define.
    if nr > 0 then
      st.rule_idx  = math.max(1, math.min(nr, st.rule_idx + d))
      st.param_idx = 1
    end
    mod.menu.redraw()
    return
  end

  if nr == 0 then return end

  if n == 2 then
    st.param_idx = math.max(1, math.min(NP, st.param_idx + d))
  elseif n == 3 then
    local rule = current_rule()
    if not rule then return end
    local p = PARAMS[st.param_idx]
    rule[p.key] = change_val(p, rule[p.key], d)
    core.rebuild_cache()
    -- FIX (BUG-05): save_deferred() is safe under rapid changes because:
    -- 1. clock.cancel() kills any in-flight save coroutine before it calls
    --    Core.save(), so the old pending save never runs.
    -- 2. clock.run() immediately schedules a new coroutine that will sleep
    --    SAVE_DELAY seconds and then call Core.save() with the LATEST state.
    -- 3. norns Lua is single-threaded (cooperative scheduler), so no write
    --    can interleave between the state mutation above and the future save.
    -- Result: no matter how many rapid encoder turns happen, exactly one save
    -- fires after the last change settles — always capturing the final state.
    core.save_deferred()
  end
  mod.menu.redraw()
end

-- ─── Register ────────────────────────────────────────────────────────────

mod.menu.register(mod.this_name, m)

-- ─── Lifecycle ───────────────────────────────────────────────────────────

mod.hook.register("system_post_startup", "midirouter_start", function()
  print("[midirouter] starting up...")

  core.scan_devices()
  refresh_dev_names()

  if not core.load() then
    core.add_rule({
      enabled    = true,
      src_dev    = _dev_names[1] or "all",
      src_ch     = "all",
      dst_dev    = _dev_names[2] or "all",
      dst_ch     = "same",
      note       = true,
      cc         = true,
      pc         = true,
      pitchbend  = true,
      aftertouch = true,
      clock      = false,
      sysex      = false,
    })
    core.save()
    print("[midirouter] default rule created")
  end

  print("[midirouter] ready. " .. #core.rules .. " rules loaded.")
  core.diag()
end)

mod.hook.register("system_pre_shutdown", "midirouter_stop", function()
  core.save()
  print("[midirouter] stopped")
end)

-- FIX (BUG-07 / BUG-01): Add script_post_cleanup hook. The existing
-- norns.script.clear hook fires *during* script teardown (mid-cleanup), at
-- which point MIDI devices and vp.event handlers may still be in a transient
-- state. script_post_cleanup fires *after* the script has fully torn down,
-- so update_devices() here sees a clean, consistent device table and
-- re-installs SysEx handlers correctly. The passthrough mod uses the same
-- pattern. Without this hook, after a script switch the router can end up
-- with stale cached device entries or missing vp.event handlers.
mod.hook.register("script_post_cleanup", "midirouter_cleanup", function()
  update_devices()
end)

-- Script init: rescan + expose params
mod.hook.register("script_post_init", "midirouter_params", function()
  update_devices()

  local dev_opts = { "all" }
  for _, name in ipairs(_dev_names) do dev_opts[#dev_opts + 1] = name end

  local function dev_idx(val)
    if val == "all" then return 1 end
    for i, name in ipairs(_dev_names) do if name == val then return i + 1 end end
    return 1
  end
  local function dev_val(idx)
    return idx == 1 and "all" or (_dev_names[idx - 1] or "all")
  end

  local cho_a = { "all","1","2","3","4","5","6","7","8","9","10","11","12","13","14","15","16" }
  local cho_s = { "same","1","2","3","4","5","6","7","8","9","10","11","12","13","14","15","16" }
  local function chi_a(v) return (v == "all") and 1 or (type(v) == "number" and v + 1 or 1) end
  local function chv_a(i) return i == 1 and "all" or i - 1 end
  local function chi_s(v) return (v == "same") and 1 or (type(v) == "number" and v + 1 or 1) end
  local function chv_s(i) return i == 1 and "same" or i - 1 end

  local bo = { "off", "on" }

  params:add_separator("MIDI ROUTER")

  params:add_option("mr_debug", "Debug Log", { "off", "on" }, 1)
  params:set_action("mr_debug", function(v) core.debug = (v == 2) end)

  params:add_option("mr_sxdbg", "SysEx Debug", { "off", "on" }, 1)
  params:set_action("mr_sxdbg", function(v) core.sysex_debug = (v == 2) end)

  params:add_trigger("mr_diag", "Diagnostics (maiden)")
  params:set_action("mr_diag", function() core.diag() end)

  params:add_trigger("mr_rescan", "Rescan devices")
  params:set_action("mr_rescan", function() update_devices() end)

  params:add_trigger("mr_add", "+ Add rule")
  params:set_action("mr_add", function()
    core.add_rule()
    core.save()
    print("[midirouter] rule added. Reload script to see in params.")
  end)

  params:add_trigger("mr_del", "- Delete last rule")
  params:set_action("mr_del", function()
    if #core.rules > 0 then core.remove_rule(#core.rules); core.save() end
  end)

  for i = 1, #core.rules do
    local r   = core.rules[i]
    local pfx = "mr_r" .. i .. "_"
    local ii  = i

    params:add_separator("Rule " .. i)
    params:add_option(pfx .. "on",  "  Active",      bo,       r.enabled    and 2 or 1)
    params:add_option(pfx .. "sd",  "  From Device", dev_opts, dev_idx(r.src_dev))
    params:add_option(pfx .. "sc",  "  From Ch",     cho_a,    chi_a(r.src_ch))
    params:add_option(pfx .. "dd",  "  To Device",   dev_opts, dev_idx(r.dst_dev))
    params:add_option(pfx .. "dc",  "  To Ch",       cho_s,    chi_s(r.dst_ch))
    params:add_option(pfx .. "no",  "  Notes",       bo,       r.note       and 2 or 1)
    params:add_option(pfx .. "cc",  "  CC",          bo,       r.cc         and 2 or 1)
    params:add_option(pfx .. "pc",  "  Prog Chg",    bo,       r.pc         and 2 or 1)
    params:add_option(pfx .. "pb",  "  Pitchbend",   bo,       r.pitchbend  and 2 or 1)
    params:add_option(pfx .. "at",  "  Aftertouch",  bo,       r.aftertouch and 2 or 1)
    params:add_option(pfx .. "clk", "  Clock",       bo,       r.clock      and 2 or 1)
    params:add_option(pfx .. "sx",  "  SysEx",       bo,       r.sysex      and 2 or 1)

    local function set_and_save(key, transform)
      return function(v)
        core.rules[ii][key] = transform(v)
        core.rebuild_cache()
        core.save_deferred()
      end
    end
    local function bool_val(v)  return v == 2 end
    local function devval_fn(v) return dev_val(v) end
    local function chva_fn(v)   return chv_a(v) end
    local function chvs_fn(v)   return chv_s(v) end

    params:set_action(pfx .. "on",  set_and_save("enabled",    bool_val))
    params:set_action(pfx .. "sd",  set_and_save("src_dev",    devval_fn))
    params:set_action(pfx .. "sc",  set_and_save("src_ch",     chva_fn))
    params:set_action(pfx .. "dd",  set_and_save("dst_dev",    devval_fn))
    params:set_action(pfx .. "dc",  set_and_save("dst_ch",     chvs_fn))
    params:set_action(pfx .. "no",  set_and_save("note",       bool_val))
    params:set_action(pfx .. "cc",  set_and_save("cc",         bool_val))
    params:set_action(pfx .. "pc",  set_and_save("pc",         bool_val))
    params:set_action(pfx .. "pb",  set_and_save("pitchbend",  bool_val))
    params:set_action(pfx .. "at",  set_and_save("aftertouch", bool_val))
    params:set_action(pfx .. "clk", set_and_save("clock",      bool_val))
    params:set_action(pfx .. "sx",  set_and_save("sysex",      bool_val))
  end
end)

-- FIX (BUG-06 — midi.connect() leak): midi.connect() is called inside
-- core.lua's Core.scan_devices(), NOT here in mod.lua. mod.lua does not call
-- midi.connect() at all. The connection-leak fix (reusing existing connect
-- objects when the port number is unchanged across rescans) therefore belongs
-- entirely in WP1 / core.lua (Agent 1) and must NOT be duplicated here.
-- This comment exists solely to document the boundary decision and prevent
-- future contributors from adding a redundant fix in this file.
