# Adaptive Auto-Turn for KOReader

![Lua 5.1](https://img.shields.io/badge/Lua-5.1-blue) ![License: MIT](https://img.shields.io/badge/License-MIT-green) ![KOReader user patch](https://img.shields.io/badge/KOReader-user%20patch-orange)

**English** · [简体中文](README.zh-CN.md)

> A single-file KOReader user patch that learns your reading pace from your own manual page turns, then drives AutoTurn with an interval that actually fits you.

KOReader ships with an **AutoTurn** plugin that flips pages on a fixed timer. This patch replaces that fixed guess with a measured value — without touching KOReader's source code.

---

## Why this exists

AutoTurn asks you to pick a number of seconds. That number is a guess, and it fails in both directions:

- **Too short** — the page turns before you have finished reading it, so you keep reaching back.
- **Too long** — you finish the page and sit waiting for the device to catch up.

Reading pace is personal. It also moves within a single session: you settle into a chapter and read faster, slow down when tired, or stall on a dense page. One hard-coded number cannot follow that, and tuning it by trial and error is tedious — change a setting, read for a while, change it again.

The idea here is to **let the reader measure it**. Watch a stretch of ordinary manual page turns, keep only the gaps that reflect real reading, average them, and hand the result back to AutoTurn. You never have to guess a number.

A few decisions follow from that idea:

| Decision | Reasoning |
| --- | --- |
| **One global value, not per-book** | Reading pace belongs to the reader, not the book. One learned interval is shared across every book, so opening a new file never triggers retraining. |
| **Zero intrusion** | A `2-` prefixed user patch: runtime monkey-patches only. No KOReader source edits, no global variables, no created directories, no data files, no `lfs`. Delete the file and stock behaviour is fully restored. |
| **Silent until you opt in** | Opening a book produces no prompt. The patch only steps in at the moment **you** switch AutoTurn on. |
| **Keep reasonable samples** | Only genuinely anomalous gaps are dropped. No recency weighting: people tend to read faster as they warm up, and weighting recent samples would bias the result toward turning pages too quickly. A whole-period mean keeps the calm, realistic pace. |
| **Fail soft** | Every `require`, interface probe, widget call and hook is wrapped in `pcall`. If a symbol is missing or a KOReader version differs, the patch logs a warning and steps aside — it can never prevent KOReader from starting. |
| **Native power management** | AutoTurn's own `_start()` / `_unschedule()` pair owns `PluginShare.pause_auto_suspend`. The patch never writes that flag directly, so the device keeps its normal auto-suspend behaviour during collection and after a cancel. |

---

## What it does

**Trigger.** When you toggle AutoTurn **off → on** from the menu, the patch first closes the settings menu and shows an interval dialog, so choosing any option returns you straight to the reading page instead of leaving you in the settings menu; "Manual setup" also shows a single input box rather than stacking a dialog behind the menu. Switching it **on → off** closes it immediately, without the native "set time / disable" dialog. Opening a book is completely silent.

**The interval dialog** asks "About to enable auto page turning — set the page-turn interval:" and offers four choices:

| Choice | Behaviour |
| --- | --- |
| Current interval | With learned data, shows "Current interval: X s/page", enables at that value and hints it for 3 seconds; with no data, shows "Current interval: no data" and tapping it shows "No current data — choose Auto-set or Set manually", then re-opens the dialog after 3 seconds without enabling AutoTurn. |
| Auto-set | Learn a new interval from your manual page turns, also with a 3-second hint before collecting. |
| Set manually | Enter an integer from 3 to 120 seconds; invalid input is rejected and you can retry. |
| Cancel | Leave AutoTurn off, change nothing. |

**Learning flow**

1. A **3-second page hint** — "Learning your page-turn rhythm, please keep turning pages manually." — appears. AutoTurn is suspended and no samples are counted yet — the taps you make while the hint is still on screen are never recorded.
2. When the hint closes, collection starts. AutoTurn stays off; you turn pages by hand as usual.
3. Collection ends as soon as **40 valid intervals** have been gathered, or early after **20 minutes with at least 15 valid samples** so slow readers need not wait the full cap — with a **30-minute** final timeout, whichever comes first.
4. The learned interval is written to settings and AutoTurn is enabled at that value.
5. If there is not enough valid data, the existing learned value is left untouched and AutoTurn stays off; a 3-second hint is shown. You can enable AutoTurn again and retry "Auto setup".
6. **To cancel mid-collection**, tap the AutoTurn menu item (or switch) again. This aborts collection, keeps AutoTurn off, writes nothing, and lets you start again anytime.

### How the interval is computed

Only *anomalies* are removed; everything in a reasonable range is kept, then averaged over the whole collection.

| Side | Rule | What it catches |
| --- | --- | --- |
| Too large | `gap > median × 3` | Walking away, dozing off, long interruptions |
| Too small, sampling | `gap < 6 s` — not recorded, but the timing baseline still advances | Accidental double taps, mis-touches (e.g. a 5 s double flip) |
| Too small, statistics | `gap < max(6 s, median × 0.4)` | Abnormally fast gaps relative to your own pace |

Deliberately **not** used: two-sided IQR, discarding short reading fragments, and recency weighting. The first two erase legitimately slow pages and push the mean down; the third follows the natural warm-up speed-up and pushes it down as well. Both make pages turn too fast. The final value is clamped to 3–120 seconds and rounded.

Only adjacent forward turns count. Jumps, back-flips, table-of-contents / bookmark / search navigation, scan-mode bursts and auto-generated turns are excluded. Timings use KOReader's monotonic clock, so a sleep/wake cycle cannot distort a sample.

### Power and sleep/wake behaviour

Sleep/wake cycles are the hardest case for any timer-driven patch, so this part is deliberately conservative:

- **The power flag stays balanced across sleep.** The patch never sets `PluginShare.pause_auto_suspend` directly. Enabling goes through AutoTurn's native `_start()` (flag → true) and stopping through `_unschedule()` (flag → false). Crucially, on `onSuspend` the patch actively calls the native `_unschedule()` itself instead of relying on AutoTurn's own `onSuspend` handler — AutoTurn registers via `event_hook("InputEvent")`, so the broadcast `Suspend` event is not guaranteed to reach it on every version/plugin combination, which would leave the flag stuck at `true` and prevent the device from ever locking or auto-suspending. This call is idempotent with the native one.
- **Auto-turn is restored on wake.** When the patch stops auto-turn on suspend while idle, it remembers whether it was previously on. On `onResume` it restores it through the native `_start()`, so the flag and the page-turn task are re-armed together. During collection/waiting, auto-turn deliberately stays suspended, so a resume never restarts page turning mid-training.
- **Two clocks, one authoritative deadline.** KOReader's `scheduleIn` uses `CLOCK_MONOTONIC`, which does not tick while the device sleeps. The patch therefore treats a wall-clock monotonic deadline from `UIManager:getElapsedTimeSinceBoot()` as authoritative for both the page hint and the 30-minute safety timeout; the scheduled tasks are only "wake me up and re-check" triggers. A lock-screen session longer than 30 minutes is settled immediately on wake, never stretched into an hour, and the cross-sleep gap is never recorded as a sample.
- **Collection survives a lock screen.** During collection, `pause_auto_suspend` is false so the device can still be locked normally. On `onSuspend` the patch cancels its timers and clears the timing baseline; on `onResume` it rebuilds the timeout from the remaining time — idempotently, without relying on suspend-event bookkeeping — and settles immediately if the deadline already passed. Gaps that span a sleep are never counted as reading samples.
- **No orphan timers.** Opening a book, closing a document, switching books, aborting, settling and suspending all clear every task handle unconditionally.
- **Re-entrancy safe.** AutoTurn's `_schedule()` can dispatch a page turn synchronously and re-enter the event handler — for example when a menu interrupts an auto-turn. The patch marks that window with a counter instead of a boolean, so nested scheduling cannot misclassify an auto-turn as a manual sample.
- **Memory is released with the book.** Closing a document restores every hook and drops all references to the ReaderUI instance, so a closed book (including its rendered document) is never pinned in memory while you browse the file manager. The event wrapper avoids per-event allocations, and page events are only processed during collection — idle page turns cost the patch nothing.
- **Suspend and wake are always observable.** Every suspend and resume event produces one `aat:` log line regardless of patch state, so device-side logs can confirm the events were actually received.
- **Dormant after use.** Once a value is learned or set, the patch keeps no samples or timing state and stays dormant until you turn auto-turn on again. In this state only four low-frequency lifecycle events (book ready, book close, suspend, resume) reach the patch; ordinary page turns, jumps and reflows are short-circuited at the event entry — no clock call, no log, no state change. The patch therefore costs effectively nothing during normal reading. Turning auto-turn back on is the only thing that wakes it, and that path runs through the menu callback wrapper, not the event handler, so waking always works.

### Diagnostic logs

All patch messages use the `aat:` prefix in a compact `key=value` form for quick scanning. The most useful lines when investigating freezes around sleep/wake:

| Log line | Meaning |
| --- | --- |
| `aat: suspend received phase=...` | The patch received the system suspend event and actively stopped auto-turn / cleared the power flag |
| `aat: resume received phase=...` | The patch received the resume event |
| `aat: resume, autoturn restored via native _start` | Auto-turn was on before locking and was restored on wake (flag re-armed) |
| `aat: hooks installed / hooks detached` | Hooks (re)attached on book open / removed on book close |
| `aat: autoturn enabled sec=...` | AutoTurn enabled with the given interval |
| `aat: autoturn disabled (native dialog skipped)` | You turned auto-turn off from the menu; the patch skipped the native dialog, closed it and cleared the power flag |
| `aat: collection done reason= ... learned=...` | Training finished and the value was stored (`reason=`: `enough`=40 samples, `adaptive`=20 min with enough samples, or `timeout`=30 min cap) |
| `aat: collection failed reason=... ... stays=off` | Not enough valid samples; AutoTurn stays off (no default interval applied) |

To isolate whether auto-turn itself is involved in a sleep/wake freeze, no code change is needed: from the AutoTurn menu, turn auto-turn **off** before locking the screen and back **on** after unlocking. If the freeze disappears, the auto-turn-on-during-sleep path is confirmed. (Auto-turn's menu item is generated by `addToMainMenu`; the patch only intercepts off→on, and lets on→off through unchanged.)

---

## Install

1. Copy `2-adaptive-autoturn.lua` into `koreader/patches/`.
2. Keep the filename starting with `2-` — this tells KOReader to load the patch in the late phase, after UIManager is ready.
3. Restart KOReader. Make sure the **AutoTurn** plugin is enabled and you are in paged (not scroll) view.

Do not run another patch that also wraps AutoTurn at the same time; the hooks would stack.

## Uninstall

Delete the file (or rename it to `.disabled`) and restart. Nothing else is left behind: no source edits, no data files, no global state.

---

## Configuration

All knobs live in the `CFG` table at the top of the file. Edit and restart KOReader.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `setting_key` | `adaptive_autoturn` | Key in `G_reader_settings` |
| `hint_timeout` | `3` | Seconds the page hint stays before sampling starts |
| `target_samples` | `40` | Valid intervals needed to finish collection |
| `train_timeout_min` | `30` | Safety timeout, in minutes |
| `min_interval` | `2` | Below this, a gap counts toward scan-mode detection |
| `abs_min_keep` | `6` | Absolute floor; smaller gaps are never recorded |
| `max_interval` | `300` | Longest gap that can be recorded |
| `burst_count` | `3` | Consecutive fast flips that trigger a scan-mode reset |
| `min_samples` | `8` | Minimum samples for a valid result |
| `min_after_trim` | `5` | Minimum samples after outlier removal |
| `outlier_factor` | `3` | Upper bound as a multiple of the median |
| `small_outlier_ratio` | `0.4` | Lower bound as a fraction of the median |
| `min_sec` / `max_sec` | `3` / `120` | Clamp range for the learned value |
| `adaptive_min_minutes` | `20` | Settle early after this many minutes if enough samples exist |
| `adaptive_min_samples` | `15` | Minimum valid samples required for early settlement |
| `suspend_sec` | `86400` | Interval used to hold AutoTurn during collection |

---

## Data and privacy

The only persistent state is one entry in `G_reader_settings.adaptive_autoturn`, which KOReader itself writes to `settings.reader.lua`:

```lua
{
  learned_sec   = 42,   -- learned interval, seconds
  trained       = true, -- a valid value exists
  last_duration = 30,   -- safety timeout used for this training, minutes
}
```

The patch creates no directories, writes no files and sends no data anywhere. Raw turn intervals live only in memory during collection and are discarded afterwards. To forget the learned value, remove the `adaptive_autoturn` entry from `settings.reader.lua`.

Enabling AutoTurn also updates AutoTurn's own `autoturn_timeout_seconds` / `autoturn_enabled` settings and re-attaches its `onResume` handler. Those are native AutoTurn settings, not extra data created by the patch.

---

## Compatibility and limitations

- Written in plain **Lua 5.1** with zero global writes.
- Interfaces are probed at runtime against real KOReader symbols (`ReaderReady`, `PageUpdate`, AutoTurn fields and `_schedule` / `_unschedule` / `_start`, `UIManager:getElapsedTimeSinceBoot()`, `onSuspend` / `onResume`, widgets) rather than hard-coded. If a future KOReader release changes them, the patch detects the mismatch and quietly disables itself instead of breaking startup.
- **Paged view only.** Switching to scroll mode aborts collection with a message.
- The learned interval is global. If your pace differs sharply between, say, comics and dense prose, use *Set manually* for those sessions.
- Not tested on every device and KOReader version combination. Reports about specific firmware and plugin versions are very welcome.
- **Rapid-tap protection:** the patch keeps only one of its own dialogs open at a time, closing any previous one before showing a new selector or input box, so fast repeated taps cannot stack windows and virtual keyboards. If you use a third-party IME plugin such as `pinyin_enhancement`, it is known to conflict with KOReader's input box during Chinese Pinyin entry and can crash it (`inputtext.lua addChars(nil)`; unrelated to this patch). This patch's rapid-tap guard greatly reduces the trigger, but a full fix requires updating/disabling that IME plugin or switching to the English/number keyboard for manual setup.

## Contributing

Issues and pull requests are welcome — especially compatibility reports (device + KOReader version), translations, and suggestions on the statistics. Please keep any change free of global writes and wrap new probes in `pcall`.

## License

[MIT](LICENSE)
