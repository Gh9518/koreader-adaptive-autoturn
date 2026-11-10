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

**Trigger.** When you toggle AutoTurn **off → on** from the menu, the patch intercepts the action and shows an interval dialog. Switching it **on → off** is passed straight through. Opening a book is completely silent.

**The interval dialog** offers four choices:

| Choice | Behaviour |
| --- | --- |
| Use learned value | Enable AutoTurn immediately at the stored interval; greyed out until a value exists. |
| Retrain | Learn a new interval from your manual page turns. |
| Set manually | Enter an integer from 3 to 120 seconds; invalid input is rejected and you can retry. |
| Cancel | Leave AutoTurn off, change nothing. |

**Learning flow**

1. A **3-second page hint** appears. AutoTurn is suspended and no samples are counted yet — the taps you make while the hint is still on screen are never recorded.
2. When the hint closes, collection starts. AutoTurn stays off; you turn pages by hand as usual.
3. Collection ends as soon as **40 valid intervals** have been gathered, or at a **30-minute** safety timeout, whichever comes first.
4. The learned interval is written to settings and AutoTurn is enabled at that value.
5. If there is not enough valid data, the existing learned value is left untouched, AutoTurn is enabled at the 120-second default, and a retry is offered.

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

- **The power flag belongs to AutoTurn.** The patch never sets `PluginShare.pause_auto_suspend` itself. Enabling goes through AutoTurn's native `_start()`, and suspending or cancelling through `_unschedule()`, so the flag is always balanced and the device keeps its normal auto-suspend behaviour.
- **Two clocks, one authoritative deadline.** KOReader's `scheduleIn` uses `CLOCK_MONOTONIC`, which does not tick while the device sleeps. The patch therefore treats a wall-clock monotonic deadline from `UIManager:getElapsedTimeSinceBoot()` as authoritative for both the page hint and the 30-minute safety timeout; the scheduled tasks are only "wake me up and re-check" triggers. A long lock-screen session cannot stretch the 30-minute timeout into an hour.
- **Timers are cancelled on suspend.** On `onSuspend` both scheduled tasks are unscheduled and the page-turn timing baseline is cleared. On `onResume` they are rebuilt from the remaining time, or collection is settled immediately if the deadline has already passed. Gaps that span a sleep are never counted as reading samples.
- **No orphan timers.** Opening a book, closing a document, switching books, aborting, settling and suspending all clear both task handles unconditionally.
- **Re-entrancy safe.** AutoTurn's `_schedule()` can dispatch a page turn synchronously and re-enter the event handler — for example when a menu interrupts an auto-turn. The patch marks that window with a counter instead of a boolean, so nested scheduling cannot misclassify an auto-turn as a manual sample.

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
| `default_sec` | `120` | Fallback when collection fails |
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

## Contributing

Issues and pull requests are welcome — especially compatibility reports (device + KOReader version), translations, and suggestions on the statistics. Please keep any change free of global writes and wrap new probes in `pcall`.

## License

[MIT](LICENSE)
