# 参考资料清单（阶段 1）

> 调研日期 2026-11-20。目标：KOReader 最新稳定版（v2026.07.1，发布于 2026-08-01）的 Lua 5.1 user patch。
> 格式固定为：`- 结论 — 来源 URL — 许可证 — 是否可商用引用`。
> 「是否可商用引用 = 否」的条目**只参考接口契约与设计思路，禁止复制其代码**。
> KOReader 官方仓库经 GitHub API 确认为 **AGPL-3.0**，其源码一律不进入本 MIT 项目；幸运的是本项目只做运行时 monkey-patch，本就不复制源码。

---

## 1. 同类成熟实现对比（≥2）

对比维度聚焦本次优化关心的三点：**错误处理 / 资源释放 / 配置管理**。

| 项目 | 错误处理 | 资源释放 | 配置管理 | 许可证 |
| --- | --- | --- | --- | --- |
| KOReader 官方 AutoTurn | 无 pcall；依赖 `_enabled()` 前置判断 | `_start`/`_unschedule` 成对维护 `pause_auto_suspend`；`onCloseWidget/onCloseDocument/onSuspend` 均 unschedule | `G_reader_settings`：timeout/enabled/distance | AGPL-3.0（禁搬代码） |
| karpushchenko/koreader-rsvp-plugin（FastReader） | 页面类型分支、事件返回值校验 | 单 widget 实例、词数组**整体替换**而非追加、定时器 reschedule 前先 unschedule、按需逐页提取 | 每页预览词数可配置（1–10），影响计算量 | MIT |
| khhf/autowords.koplugin | 文本提取 / 当前页读取 / 菜单刷新用 pcall，失败写 warn 并降级 | `scheduled` 标志 + `stopScheduling()` 统一 unschedule；doc/widget close 清理引用；footer icon 用 `*_added` 幂等标志 | 全部走 `G_reader_settings`；含旧配置迁移；单条 `cache_key/cache_count` 运行时缓存 | MIT |

**借鉴点一（资源释放，来自 FastReader + AutoWords）**：样本集合在结算后**整体置空/替换**，而非逐条删除；定时器重排前先 unschedule。对应本补丁「结算后清空 `S.samples`、重排前 `clear_timers`」，已实现，作为正确性基线保留。FastReader 的 `self.words` 整体替换思路尤其适合采集期样本：`samples = {}` 之后旧数组整体可被 GC，不残留逐条引用。

**借鉴点二（配置管理，来自 AutoWords）**：配置统一从单一 settings 键读取、默认值内联在 `readSetting(k, default)`，避免散落的 `or` 兜底。本补丁已有 `CFG` 单一参数区与 `adaptive_autoturn` 单键，符合；不在本次范围改动。

**借鉴点三（错误处理，来自 AutoWords）**：外部/易变调用（文本提取、状态刷新）用 pcall，失败写日志并**明确降级路径**；核心 UI 调用（scheduleIn/GotoViewRel）保持裸调用以让错误可见。本补丁对所有外部调用一律 pcall 且失败跳过，更保守，符合「fail soft」目标；保留现状。

### 逐条来源

- 官方 AutoTurn 插件当前源码，确认 `autoturn_sec/enabled/task/last_action_time` 字段与 `_start/_unschedule/_schedule/addToMainMenu` 方法；`_unschedule` 清 `pause_auto_suspend`，`cancel_callback` 做 `enabled=false + makeFalse + _unschedule + onResume=nil`（抓取于 2026-11-20，master 分支） — https://raw.githubusercontent.com/koreader/koreader/master/plugins/autoturn.koplugin/main.lua — AGPL-3.0 — 否（仅核对接口契约，不复制代码）
- AutoWords 按字数密度自动翻页、速度可校准；`scheduled` 标志 + `stopScheduling()` 统一清理、pcall 包裹文本提取/菜单刷新、配置全走 `G_reader_settings`、含旧配置迁移（仓库创建 2026-10-08，最后推送 2026-10-22） — https://github.com/khhf/autowords.koplugin — MIT — 是（仅借鉴思路，不复制代码）
- AutoWords 主源码：定时器与 suspend/resume 释放、footer icon 幂等卸载、单条运行时缓存 `cache_key/cache_count` 的做法（抓取于 2026-11-20，main 分支） — https://raw.githubusercontent.com/khhf/autowords.koplugin/main/main.lua — MIT — 是（仅借鉴思路，不复制代码）
- FastReader（RSVP）高级实现：单 widget 实例、`self.words` 整体替换、timer 先 unschedule 再 reschedule、逐页按需提取以限制内存（DeepWiki 文档，仓库 2025 年版权） — https://deepwiki.com/karpushchenko/koreader-rsvp-plugin/9-advanced-topics — MIT — 是（仅借鉴思路，不复制代码）
- FastReader 许可证 MIT，Copyright (c) 2025 Ivan Karpushchenko — https://raw.githubusercontent.com/karpushchenko/koreader-rsvp-plugin/master/LICENSE — MIT — 是

---

## 2. 官方规范与最佳实践（硬约束）

- `2-` 前缀 patch 在 UIManager 就绪后（late 阶段）执行；文件名首位数字决定时机，patch 由 `pcall(dofile, fullpath)` 执行，失败仅告警不影响启动 — https://github.com/koreader/koreader/blob/93935f34efafb9b8c1c6caddb8e8df5e1dd57d9a/frontend/userpatch.lua — AGPL-3.0 — 否（本项目靠文件名前缀遵循该约定，不复制代码）
- `userpatch.registerPatchPluginFunc(plugin_name, func)` 是官方提供的插件级 hook：回调用来在每次插件实例化时打补丁，可挂多个 func（本补丁首选入口，完全吻合） — https://github.com/koreader/koreader/blob/93935f34efafb9b8c1c6caddb8e8df5e1dd57d9a/frontend/userpatch.lua — AGPL-3.0 — 否（按公开 API 调用，非复制代码）
- **硬约束**：UIManager 用 `CLOCK_MONOTONIC`（休眠期间不计时）；`shiftScheduledTasksBy` 靠负向平移让任务在预期时刻执行 — https://koreader.rocks/doc/modules/ui.uimanager.html — KOReader 官方文档（页面未标注发布时间；经 API 确认主仓库 AGPL-3.0，文档同属官方） — 否（仅采信语义事实，不复制代码）
- **硬约束**：`UIManager:unschedule(action)` 取消匿名函数前必须先保存其函数引用（官方原文 "In order to unschedule anonymous functions, store a reference."）；本补丁全部定时任务都存句柄，正是为满足此约束 — https://koreader.rocks/doc/modules/ui.uimanager.html — KOReader 官方文档（无发布时间标注） — 否（仅采信语义事实）
- **硬约束**：插件自我防护——init 出错会静默禁用插件且无用户反馈，故 init 要短小防御、重活延迟到惰性方法；字符串包裹 `_(...)` 参与翻译；patch/插件须声明目标版本并在内部变更时优雅降级 — https://skillsmp.com/creators/kurokeita/ai-agent/skills-koreader-plugin-development — 第三方整理（非官方，许可证未标注） — 否（只采信思路，不复制代码）
- Lua 5.1 词法作用域与闭包/upvalue 语义：内层函数捕获外层局部变量形成 upvalue，每次执行 `local` 都创建新变量；收紧捕获范围可减少闭包驻留 — https://www.lua.org/manual/5.1/manual.html — Lua 5.1 参考手册（Copyright © 2006–2012 Lua.org, PUC-Rio；MIT 风格） — 是（规范事实，无代码可搬）
- Lua 5.1 弱表语义：`__mode` 含 `'k'` 为弱键、`'v'` 为弱值，`'kv'` 两者皆弱；仅被弱引用的对象可被 GC，任一键/值被回收则整对移除；一旦作为 metatable 使用不应再改 `__mode` — https://www.lua.org/manual/5.1/manual.html — Lua 5.1 参考手册（2006–2012） — 是（规范事实）
- Lua 5.1 通过 `collectgarbage` / C 层 `lua_gc` 控制 GC；`pcall` 是 Lua 层捕获错误的手段 — https://www.lua.org/manual/5.1/manual.html — Lua 5.1 参考手册（2006–2012） — 是（规范事实）
- KOReader 最新稳定版 v2026.07.1（发布于 2026-08-01）仍为小修版本，未见影响 UIManager 调度接口或 AutoTurn 的破坏性变更；仓库 last push 2026-11-19 — https://api.github.com/repos/koreader/koreader/releases/latest — AGPL-3.0（仓库许可） — 否（仅作版本事实引用）
- KOReader 主仓库许可证为 **GNU Affero General Public License v3.0 (AGPL-3.0)**，31.2k stars，last push 2026-11-19 — https://api.github.com/repos/koreader/koreader — AGPL-3.0 — 否（许可证事实引用）
- user patches 的安装/卸载约定：放 `koreader/patches/`，删除即还原、不写磁盘文件；0-仅更新后一次、1-每次启动早期、2-UIManager 就绪后最常见 — https://garden.diego.codes/koreader-user-patches — 第三方个人站点（无许可证标注、无发布时间） — 否（只采信操作约定，不复制代码）

---

## 3. 本阶段产出的硬约束清单（供阶段 2 遵守）

1. **不动 KOReader 源码、不复制其 AGPL 代码**：本项目保持纯运行时 monkey-patch，仅靠公开/探测到的接口交互。
2. **所有定时任务必须存句柄并在关书/中止/结算/休眠时 unschedule**（UIManager 官方硬约束 + 测试已有覆盖）。
3. **采集样本集必须 bounded**：上限由 CFG 的 `target_samples` 与 30 分钟超时共同约束；结算后整体置空释放。
4. **idle 热路径零分配、零时钟调用**：保持 `DORMANT_HANDLERS` 短路，任何优化不得往此路径引入新分配。
5. **零全局写入、零文件 IO、零新增依赖**：保持现有契约。
6. **目标版本 KOReader v2026.07.x（Lua 5.1）**：任何改动须在该接口面下行为一致。
