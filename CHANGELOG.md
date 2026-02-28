# MidiRouter CHANGELOG

## v1.01 — 2026-02-28

### Summary

Six bugs fixed across `core.lua` and `mod.lua` based on deep code review.
No functional changes to routing behaviour — all fixes improve robustness,
correctness and efficiency.

---

### Fixes

#### core.lua — Expose MAX_RULES as public constant
- **File:** `lib/core.lua`
- **Description:** `MAX_RULES` is now exposed as `Core.MAX_RULES` so `mod.lua` can read it directly instead of maintaining a duplicate hardcoded constant. Eliminates a maintenance hazard where changing the limit in one file would silently diverge from the other.

#### core.lua — Prune stale SysEx accumulators on device disconnect
- **File:** `lib/core.lua`
- **Function:** `Core.scan_devices()`
- **Description:** `_sx_ev` and `_sx_vp` accumulator tables were never pruned when devices disconnected. On systems with frequent hot-plug cycles, entries for old ports accumulated indefinitely. Fixed by removing entries for ports no longer present after each scan.

#### mod.lua — MAX_RULES read from core instead of duplicated
- **File:** `lib/mod.lua`
- **Description:** `MAX_RULES` now reads `core.MAX_RULES` (with fallback to 16) instead of a hardcoded local constant.

#### mod.lua — system_post_startup made idempotent
- **File:** `lib/mod.lua`
- **Function:** `system_post_startup` hook
- **Description:** Added a `_startup_done` guard flag. If the hook somehow fires more than once, the second call returns immediately, preventing duplicate default rules from being created when `core.load()` fails.

#### mod.lua — script_post_init made idempotent
- **File:** `lib/mod.lua`
- **Function:** `script_post_init` hook
- **Description:** Added a `_params_registered` guard flag, reset in `script_post_cleanup`. Prevents duplicate `params:add_*` entries with identical keys if the hook fires more than once for the same script load, which would cause undefined behaviour in the norns params system.

#### mod.lua — Cache device options list in change_val()
- **File:** `lib/mod.lua`
- **Function:** `change_val()`, `refresh_dev_names()`
- **Description:** The `opts` table for device selection was allocated on every encoder turn. Now built once in `refresh_dev_names()` and reused as `_dev_opts`, eliminating repeated GC pressure during fast encoder sweeps.

---

## v1.0 — 2026-02-27

### Summary

Four bugs were fixed to produce a stable v1.0 release. The primary fix (BUG-12)
resolves the "must activate M8 Launchpad Mode twice" issue. Root cause: norns
allocates `midi.vports[port]` lazily on first MIDI arrival — not during
`midi.connect()` — so no `vp.event` SysEx handler existed when the first M8
SysEx burst arrived. The fix installs the handler lazily inside `handle_event()`
the instant the vport becomes available, with a Path A fallback for safety.
Three additional UI correctness fixes prevent crashes and missing dialogs.

---

### Fixes

---

#### BUG-12 — Lazy vport allocation causes first M8 SysEx burst to be dropped
- **Severity:** HIGH
- **File:** `lib/core.lua`
- **Functions:** `Core.handle_event()`, `Core.install_sysex_handlers()`
- **Description:** norns allocates `midi.vports[port]` lazily — the table entry
  is `nil` until the very first MIDI event arrives on that port, regardless of
  whether `midi.connect(port)` has been called. `install_sysex_handlers()` ran
  at `system_post_startup`, found `midi.vports[1]` nil, and silently skipped
  installing the `vp.event` SysEx handler. A deferred retry (0.5 s `clock.run`)
  was attempted first but always fired before any MIDI arrived, so `vp.event`
  remained uninstalled. Because the "virtual" (TRS/ttymidi) port relies
  exclusively on Path B (`vp.event`) for SysEx routing, the first M8 Launchpad
  Mode activation was silently dropped. The second activation worked because
  `_norns.midi.add` had fired in the meantime, triggering a rescan that found
  the vport ready. The fix installs the handler lazily at the top of
  `handle_event()`: every `_norns.midi.event` callback checks whether the
  vport handler is missing or stale and calls `install_sysex_handlers()` if so.
  Because `_norns.midi.event` fires **before** `vp.event` for the same packet,
  the newly installed handler is invoked for that very packet. A Path A fallback
  routing path for the virtual port is also added: if `vp.event` is still not
  properly chained when a complete SysEx (0xF7) arrives on the virtual port,
  `handle_event()` routes it directly rather than waiting for `vp.event`.

---

#### UI-01 — Add Rule dialog not visible when no rules exist
- **Severity:** MEDIUM
- **File:** `lib/mod.lua`
- **Function:** `m.redraw()`
- **Description:** `m.redraw()` contained an early return for the `nr == 0`
  case (showing "No rules defined / Hold K2 to add one") that fired before the
  `V_ADD` and `V_DEL` view checks. When the user held K2 to open the Add dialog
  from the empty state, `st.view` was correctly set to `V_ADD` but `redraw()`
  always returned the "No rules" screen, making the Add dialog invisible. The
  fix moves both dialog view checks (`V_ADD`, `V_DEL`) above the `nr == 0`
  early return so they are always reachable regardless of rule count.

---

#### UI-02 — K3 press with no rules causes nil dereference crash
- **Severity:** MEDIUM
- **File:** `lib/mod.lua`
- **Function:** `m.key()`
- **Description:** Pressing K3 while in `V_LIST` view with no rules set
  `st.view = V_RULE` unconditionally. The `V_RULE` redraw path then
  dereferenced `rule.src_dev` and `rule.dst_dev` where `rule` was nil
  (returned by `current_rule()` when `#core.rules == 0`), causing a Lua error.
  The fix adds a `#core.rules > 0` guard in the K3 press handler so `V_RULE`
  is only entered when there is at least one rule to display.

---

#### UI-03 — Delete dialog opens when no rules exist
- **Severity:** LOW
- **File:** `lib/mod.lua`
- **Function:** `m.key()`
- **Description:** Holding K3+K2 opened the V_DEL dialog unconditionally,
  including when `#core.rules == 0`. While not a crash (with the UI-01 fix,
  V_DEL is now rendered safely with a nil-safe subtitle), it presents a
  "Delete rule 1?" dialog when there is nothing to delete. The fix adds a
  `#core.rules > 0` guard so the delete dialog can only be opened when at
  least one rule exists.

---

## v0.9.1-beta — Known Issue Fixes — 2026-02-27

### Summary

Three known residual issues from v0.9-beta were fixed in this patch.

---

### Fixes

---

#### KNOWN-01 — _sx_seen_ev not cleared on SysEx abort in Path A
- **Severity:** LOW
- **File:** `lib/core.lua`
- **Function:** `Core.handle_event()`
- **Description:** When a SysEx accumulation in Path A was aborted by an
  unexpected non-realtime status byte (`byte >= 0x80 and byte < 0xF8`),
  `sx_reset()` was called to discard the accumulator but
  `_sx_seen_ev[src_port]` — set tentatively at the `0xF0` byte by the BUG-04
  fix — was never cleared. This left Path B (the `vp.event` handler)
  permanently suppressed for that port until the next `scan_devices()` call,
  meaning the SysEx transfer immediately following an abort would be silently
  dropped even though Path A never completed its routing. The fix adds
  `_sx_seen_ev[src_port] = nil` immediately after `sx_reset(acc)` in the
  abort branch of `Core.handle_event()`.

---

#### KNOWN-02 — Wrong FIX comment label on dialog cursor code in mod.lua
- **Severity:** INFORMATIONAL
- **File:** `lib/mod.lua`
- **Functions:** `draw_dialog()`, `m.enc()`, `m.key()`, `st` table
- **Description:** Agent 2 applied `-- FIX (BUG-04):` comment labels to the
  dialog cursor clamping and initialization code in `mod.lua`. BUG-04 in
  PLAN.md refers to the SysEx Path A/Path B race condition in `core.lua` —
  a completely unrelated issue. All five occurrences were relabeled to
  `-- FIX (KNOWN-02):`. The cursor clamping logic itself was already correct.

---

#### KNOWN-03 — os.time() integer precision causes up to ~3s timeout instead of 2.0s
- **Severity:** LOW
- **File:** `lib/core.lua`
- **Functions:** `accumulate_sysex()`, `Core.handle_event()`
- **Description:** The BUG-06 fix replaced `os.clock()` with `os.time()`,
  which returns wall-clock time as an integer number of seconds. Because
  `SYSEX_TIMEOUT` is `2.0`, the effective timeout could be anywhere from just
  over 2 s to just under 3 s depending on when within the current second
  accumulation began. The fix replaces both `os.time()` calls with
  `util.time()`, which returns a float with sub-second precision.

---

## v0.9.1-beta — 2026-02-27

### Summary

Eleven bugs were identified in the v0.9-beta code review. Nine were fully fixed
across two work packages (WP1 → core.lua, WP2 → mod.lua). One item (BUG-08)
was correctly diagnosed as not a functional bug in Lua 5.3 but improved for
readability. All fixes were verified by the Lead Agent prior to deployment.

---

### Fixes

---

#### BUG-01 — Shared channel-remap buffer data corruption
- **Severity:** CRITICAL
- **File:** `lib/core.lua`
- **Function:** `remap_channel()`
- **Description:** `remap_channel()` wrote into module-level shared tables
  `_buf2`/`_buf3` and returned a reference. When multiple rules matched the
  same event with different `dst_ch` values, the second rule's write overwrote
  the first rule's buffer before `send_safe()` finished, causing the first
  destination to receive the second rule's channel byte. Fix: remove shared
  buffers; allocate a fresh table on every call.

---

#### BUG-02 — vp.event handler overwrite and double-chaining on rescan
- **Severity:** CRITICAL
- **File:** `lib/core.lua`
- **Function:** `make_sysex_handler()`, `Core.install_sysex_handlers()`
- **Description:** `install_sysex_handlers()` unconditionally overwrote
  `vp.event`, discarding any handler installed by a running script, and
  double-chained midirouter's own handler on repeated scans. Fix: capture the
  existing handler at creation time; chain it first; skip if it is already
  midirouter's own handler.

---

#### BUG-03 — _sx_seen_ev never reset, permanently suppressing Path B after reconnect
- **Severity:** MEDIUM
- **File:** `lib/core.lua`
- **Function:** `Core.scan_devices()`
- **Description:** The `_sx_seen_ev` table was never cleared. After a device
  reconnect, if Path A failed, Path B remained permanently suppressed by the
  stale flag. Fix: reset `_sx_seen_ev = {}` at the start of every
  `scan_devices()` call.

---

#### BUG-04 — _sx_seen_ev flag set too late, allowing Path B to race ahead
- **Severity:** MEDIUM
- **File:** `lib/core.lua`
- **Function:** `Core.handle_event()`
- **Description:** The seen flag was set only at SysEx completion (0xF7). If
  Path B's `vp.event` fired with the complete packet before Path A reached
  0xF7, both paths routed the same SysEx. Fix: set the flag tentatively at
  0xF0 for non-virtual devices; clear it immediately after routing at 0xF7.

---

#### BUG-05 — midi.connect() called on every scan, leaking resources
- **Severity:** MEDIUM
- **File:** `lib/core.lua`
- **Function:** `Core.scan_devices()`
- **Description:** `midi.connect()` was called unconditionally on every scan,
  potentially leaking file descriptors or callbacks. Fix: reuse the existing
  connection object when the port number has not changed.

---

#### BUG-06 — os.clock() used for wall-clock timeout (wrong clock source)
- **Severity:** MEDIUM
- **File:** `lib/core.lua`
- **Functions:** `accumulate_sysex()`, `Core.handle_event()`
- **Description:** `os.clock()` returns CPU time, not wall time. Under norns
  load the process may be scheduled infrequently, causing the SysEx timeout to
  fire far too late. Fix: replaced with `os.time()` (later upgraded to
  `util.time()` in KNOWN-03).

---

#### BUG-07 — Missing script_post_cleanup hook causes stale device state after script switch
- **Severity:** MEDIUM
- **File:** `lib/mod.lua`
- **Function:** Lifecycle hooks
- **Description:** No `script_post_cleanup` hook existed. The
  `norns.script.clear` hook fires mid-teardown while device state is still
  transient. Fix: add `script_post_cleanup` hook that calls `update_devices()`
  after the script has fully torn down.

---

#### BUG-08 — Potential operator precedence confusion in bitwise expressions
- **Severity:** LOW (readability only)
- **File:** `lib/core.lua`
- **Function:** `route_midi()`
- **Description:** `c.mask & tmask == 0` is correct in Lua 5.3 (`&` binds
  tighter than `==`) but causes review confusion. Explicit parentheses added
  for clarity. No functional change.

---

#### BUG-09 — Silent data loss during rule migration when device not connected
- **Severity:** LOW
- **File:** `lib/core.lua`
- **Function:** `Core.load()`
- **Description:** Old port-number rules silently fell back to `"all"` during
  migration if the device was not connected, potentially routing to all devices.
  Fix: print a warning before each silent fallback.

---

#### BUG-10 — Add dialog opens and crashes at MAX_RULES limit
- **Severity:** LOW
- **File:** `lib/mod.lua`
- **Function:** `m.key()`, `m.redraw()`
- **Description:** Opening V_ADD at the 16-rule limit showed an "Add" button
  that silently failed, then set `st.rule_idx` beyond the table length. Fix:
  guard K2 long-press and K3 confirm with `#core.rules < MAX_RULES`; show
  "MAX" label in dialog when at limit.

---

#### BUG-11 — _sx_seen_ev not cleared after routing, permanently suppressing Path B
- **Severity:** LOW
- **File:** `lib/core.lua`
- **Function:** `Core.handle_event()`
- **Description:** `_sx_seen_ev[src_port]` was set to `true` at SysEx
  completion but never reset. If Path A failed on the next transfer, Path B
  remained suppressed. Fix: clear to `nil` immediately after `route_sysex()`
  at 0xF7 (implemented jointly with BUG-04).
