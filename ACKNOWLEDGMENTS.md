# Acknowledgments

Projects and standards actually consulted during the performance optimization of this patch (2026-11). Only sources that informed a decision are listed.

- KOReader AutoTurn plugin — verified the real interface contract (`_start` / `_unschedule` / `pause_auto_suspend` / menu callback side effects) that this patch hooks into; AGPL-3.0, no code copied — https://github.com/koreader/koreader/tree/master/plugins/autoturn.koplugin
- KOReader `userpatch.lua` — confirmed the `2-` late-load timing and `registerPatchPluginFunc` plugin hook this patch relies on; AGPL-3.0, no code copied — https://github.com/koreader/koreader/blob/master/frontend/userpatch.lua
- KOReader UIManager docs — authoritative `CLOCK_MONOTONIC` semantics and the "store a reference before unschedule" rule that all this patch's timers follow — https://koreader.rocks/doc/modules/ui.uimanager.html
- khhf/autowords.koplugin — compared timer cleanup, settings handling and pcall strategy; "single cached value, no history" approach; MIT, ideas only — https://github.com/khhf/autowords.koplugin
- karpushchenko/koreader-rsvp-plugin (FastReader) — compared memory patterns (single widget instance, whole-array replacement, unschedule-before-reschedule); MIT, ideas only — https://github.com/karpushchenko/koreader-rsvp-plugin
- Lua 5.1 Reference Manual — closure/upvalue capture and weak-table semantics consulted for the memory changes; MIT-style, facts only — https://www.lua.org/manual/5.1/manual.html
