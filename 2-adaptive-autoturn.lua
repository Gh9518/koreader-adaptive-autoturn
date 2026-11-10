--[[==========================================================================
 2-adaptive-autoturn.lua  —  KOReader 用户补丁「自适应翻页」
============================================================================

关于本补丁（设计初衷 / 功能 / 安装 / 数据 / 参数）

设计初衷：
  KOReader 自带的 AutoTurn 按固定秒数翻页，用户只能手动猜一个间隔。但阅读
  速度因人而异，同一人在不同状态下也会变化：太短会没读完就翻，太长要干等。
  本补丁让阅读器从用户自己的手动翻页节奏里学出间隔，而不是让人去猜数字。
  实现坚持零侵入：不改 KOReader 源码、不自建数据文件、删除即还原；学习值
  全局共用一份（同一用户阅读速度相近），不为每本书重复训练。

安装：
  把本文件放到 koreader/patches/2-adaptive-autoturn.lua，重启 KOReader。
  文件名以 "2-" 开头，表示 UIManager 就绪后（late 阶段）加载。
  请勿与其他同样包裹 AutoTurn 的补丁同时使用（会重复挂钩）。

卸载：
  删除本补丁文件（或改名 .disabled），重启 KOReader 即完全还原。补丁只在
  运行时做 monkey-patch，不改 Autoturn 源文件、不注册全局量、不改其它模块
  的持久状态。

功能说明：
  * 全局单值：所有书共用一个学习值 learned_sec，存进 G_reader_settings 的
    adaptive_autoturn 项（KOReader 会自动写进 settings.reader.lua）。
    同一用户阅读速度相近，不做按书隔离。本补丁不创建任何目录、不写任何
    数据文件、不依赖 lfs。
  * 触发 = 「用户开启自动翻页」：开书时不打扰用户，补丁只静默挂好 hook；
    当用户从菜单把 Autoturn 由「关→开」时（wrap_menu /
    wrap_switch_methods 拦截）才弹出间隔选择框：
      使用已有数据 / 重新训练 / 手动设置 / 取消
    「开→关」直接放行原逻辑。取消 = 不开启，保持关闭。
  * 自适应学习（重新训练）：选「重新训练」即进入流程。先弹一个页面提示，
    默认 hint_timeout(3) 秒自动关闭；提示关闭后才正式开始分析采集
    （pending→collecting），刚点完按钮、提示还在时的翻页不会计入样本。
    采集期关闭 Autoturn、纯手动翻页采样。
  * 结束条件（先到先结算）：采够 target_samples(40) 个有效间隔即自动结束；
    另设 train_timeout_min(30) 分钟兜底超时，防止一直采不够。结算后写学习值、
    开启 Autoturn 并设为学习值；有效样本不足用 default_sec 并提示可重试。
  * 手动设置：InputDialog 输入 3~120 的整数，写入学习值并开启 Autoturn。
  * 统计口径：双侧只剔除「异常」间隔、合理范围内一律保留、取全期均值。
      - 上侧（特别大）：> 中位数 × outlier_factor，离开/走神造成的超长间隔。
      - 下侧（特别小）：采样阶段 gap < abs_min_keep(6s) 直接不入池（误触 /
        连翻，例如 5s 的误触双击；仍更新计时基准，不污染后续间隔）；统计阶段
        再剔除 < max(abs_min_keep, 中位数 × small_outlier_ratio) 的相对异常
        小值。两层都只针对「异常快」，不会动合理范围内的偏小值。
      - 不做近期加权：越读越快的近期样本会把均值压小、导致翻页过快；
        全期均值保留所有合理值，更贴近真实、偏从容的阅读节奏。

真实接口适配（依据 KOReader 源码核实，运行时先探测再挂钩）：
  * KOReader 没有 ReaderUI:onReaderReady() 方法，真实就绪点是
    Event:new("ReaderReady", doc_settings)（readerui.lua:517，handler 名为
    "onReaderReady"）。本补丁包裹 ReaderUI 实例的 handleEvent，在原逻辑之后
    捕获该事件；并校验 this.document 存在，避免在文件管理器等界面误弹窗。
    插件实例创建于 readerui.lua:465，早于 ReaderReady，因此 hook 来得及挂。
  * AutoTurn **没有** enable / disable / toggle / setEnabled 公开开关方法。
    真实「开启」发生在 addToMainMenu 生成的 menu_items.autoturn.callback 里：
    直接设 enabled / autoturn_sec / G_reader_settings，再 _unschedule()+_start()
    （plugins/autoturn.koplugin/main.lua:135-171）。
    真实字段：autoturn_sec、autoturn_distance、enabled、last_action_time、task；
    真实方法：_enabled()、_schedule()、_unschedule()、_start()、addToMainMenu()。
    本补丁先 pcall 探测候选开关方法；探测不到时回退到包裹真实的
    addToMainMenu 产物（menu_items.autoturn.callback）来拦截「关→开」；
    两者都拿不到才 logger.warn 并放弃拦截（此时补丁静默，不影响原生行为）。
    挂起/恢复一律用 pcall 探测到的真实字段与方法（enabled + autoturn_sec +
    _unschedule/_schedule），绝不硬编码不存在的符号。
    「使用已有数据/重新训练/手动设置」的开启交回 AutoTurn 原生路径：补齐
    原生 callback 的三项副作用（写 autoturn_timeout_seconds / autoturn_enabled、
    挂 self.onResume = self._onResume），再 _unschedule() + _start()，让
    PluginShare.pause_auto_suspend 由原生 _start(true)/_unschedule(false) 成对
    管理。补丁绝不单边写这个全局标志，否则设备会一直无法自动待机，与电源
    管理争用（锁屏/唤醒卡死根因）。采集期挂起时把 onResume 摘掉并存入快照，
    避免唤醒时原生 _start 把自动翻页重新打开。
  * 页面事件：ReaderPaging 派发 PageUpdate(number, orig_mode)（:1150），
    ReaderRolling 派发 PageUpdate(page)（:1097 等）。两者都在真实翻页时派发
    PageUpdate，故本补丁以 PageUpdate 为唯一页码信号；PosUpdate 是「位置」级
    事件（滚动/同页移动也会发），拿来计页会重复计数，因此不采它。
    事件只给新页码，不给 prev，本补丁自己维护 last_page 算 new-prev。
  * GotoViewRel **不是跳转**：它同时被手动翻页（key_events args=1）与
    Autoturn 自动翻页使用（main.lua:37）。因此 A5 只把绝对跳转类事件
    （GotoPage / GotoPercent / 目录/书签/搜索定位）当跳转；自动翻页由
    auto_firing 标记（包裹 AutoTurn._schedule）单独识别。
  * 滚动模式：真实判定是 ui.view.view_mode == "scroll"（readerrolling.lua），
    命中即中止采集并提示（A1）。
  * 时间：采样间隔 dt、采集截止 collect_end、页面提示截止 hint_end 统一用
    UIManager:getElapsedTimeSinceBoot()（= CLOCK_MONOTONIC + 累计待机时长，
    即含休眠的墙上单调时钟），经 ui/time.to_number() 转秒。UIManager:scheduleIn
    用纯 CLOCK_MONOTONIC（休眠期间不走），KOReader 唤醒时会平移任务队列，
    因此补丁的两个定时任务只是「到点叫醒复核」的触发器，是否真正到点一律
    用 collect_end / hint_end 判定，锁屏再久也不会把 30 分钟拖成 57 分钟。
    onSuspend 撤销两个任务、onResume 按剩余时长重建，且不与 AutoTurn 原生
    _start() 重排的 task 叠加。AutoTurn.last_action_time 的比较发生在 fts 域，
    回填时保留原始值。本补丁不写任何文件。
  * ButtonDialog 的按钮回调不会自动关闭（buttontable.lua:80-85 只调
    btn_entry.callback），必须显式 UIManager:close(dlg)；ConfirmBox 才会自动关。
    ButtonTable 支持 enabled=false 置灰按钮（button.lua:485）。InputDialog
    用 input_type="number" + getInputText()，按钮回调同样不自动关闭。

数据格式：
  学习值存于 G_reader_settings.adaptive_autoturn（KOReader 会写进
  settings.reader.lua），结构为：
    {
      learned_sec   = 42,   -- 全局学习值（秒）
      trained       = true, -- 是否已有有效学习值
      last_duration = 30,   -- 训练超时兜底（分钟），固定 train_timeout_min
    }
  （last_duration 表示本次训练所用的兜底超时分钟数。）
  读取用 pcall(G_reader_settings:readSetting, key)，出错/字段非法一律视为
  「无数据」，不崩。本补丁不创建任何目录、不写任何数据文件、不依赖 lfs。

参数表（文件顶部 CFG 常量区，改完重启生效）：
  | 参数                 | 默认      | 说明 |
  | setting_key          | adaptive_autoturn | 存于 G_reader_settings 的设置项名 |
  | hint_timeout         | 3         | 交互后页面提示自动关闭秒数，关闭后才开始采集 |
  | target_samples       | 40        | 采够这么多个有效间隔即自动结束（主结束条件） |
  | train_timeout_min    | 30        | 兜底超时（分钟），防止一直采不够 |
  | min_interval         | 2         | 连翻/抖动阈值（秒），B1 丢弃并计 burst |
  | abs_min_keep         | 6         | 特别小的异常间隔下限（秒），低于它不入池；如 5s |
  | max_interval         | 300       | 最长有效间隔（秒），B2 丢弃 |
  | burst_count          | 3         | 连续快翻判定「翻找模式」阈值 |
  | min_samples          | 8         | 采集成功最低有效样本数 |
  | min_after_trim       | 5         | 双侧剔除异常值后剩余下限 |
  | outlier_factor       | 3         | 上侧：剔除 > 中位数×此值的特别大间隔 |
  | small_outlier_ratio  | 0.4       | 下侧：剔除 < 中位数×此值的相对异常小值 |
  | min_sec / max_sec    | 3 / 120   | 学习值 clamp 区间 |
  | default_sec          | 120       | 采集失败或手动框默认间隔 |

约束落实：
  * 纯 Lua 5.1；全部局部量，零全局写入（luac -l 校验 SETGLOBAL=0）。
  * 所有 require、接口探测、UI、hook 均包 pcall；任一步失败仅
    logger.warn，绝不中断 KOReader 启动。最外层再包一层 pcall(apply)。
  * 过滤与统计拆成独立纯函数（sorted_copy / quantile / mean /
    trim_outliers / compute_learned），便于离线单测。
  * 唯一持久状态是 G_reader_settings.adaptive_autoturn；不创建目录、不写文件、
    不依赖 lfs、不改 Autoturn 源文件。开启时另由 AutoTurn 原生 _start() 维护
    它自己的 autoturn_enabled / autoturn_timeout_seconds 与 PluginShare 标志。
  * 定时器生命周期：clear_timers() 统一撤销 hint_task / collect_task；开新书、
    关文档、换书 detach、结算、中止、休眠都无条件调用，杜绝幽灵任务。
  * 防自激 auto_firing 用计数：_schedule 内同步派发 GotoViewRel 会重入
    handleEvent，菜单打断 / 嵌套调度时布尔会被内层提前清掉，计数保证整段
    窗口都被识别为自动翻页，不会误计入手动样本。
  * 删除补丁文件后，运行时包裹随进程消失，Autoturn 恢复原生行为。
==========================================================================]]

-- ---------------------------------------------------------------- 依赖探测 --
-- 为什么逐项包 pcall：2- 补丁由框架 pcall(dofile, path) 执行，但 require 失败
-- 若不保护会冒泡成框架弹的 "Error applying patch"，所以这里全部吞掉。
local ok_logger, logger = pcall(require, "logger")
if not ok_logger or type(logger) ~= "table" then return end
local ok_ui, UIManager = pcall(require, "ui/uimanager")
if not ok_ui or type(UIManager) ~= "table" then return end

local ok_time, time         = pcall(require, "ui/time")
local ok_gettext, gettext   = pcall(require, "gettext")
-- 刻意不叫 "_"：Lua 里 "_" 常作丢弃型循环变量，若拿它当 gettext 函数，
-- 某个 for _, x 循环体内调用翻译就会被遮蔽成数字而报错。
local L = (ok_gettext and type(gettext) == "function") and gettext
          or function(s) return s end
local ok_pl, PluginLoader  = pcall(require, "pluginloader")
local ok_up, userpatch     = pcall(require, "userpatch")

local ok_IM, InfoMessage   = pcall(require, "ui/widget/infomessage")
local ok_CB, ConfirmBox    = pcall(require, "ui/widget/confirmbox")
local ok_BD, ButtonDialog  = pcall(require, "ui/widget/buttondialog")
local ok_ID, InputDialog   = pcall(require, "ui/widget/inputdialog")

-- 全局学习值存进 G_reader_settings.adaptive_autoturn。KOReader 的 LuaSettings 在
-- saveSetting 后会写回 settings.reader.lua，无需本补丁碰文件、也不涉及 lfs。
-- G_reader_settings 是启动后已存在的全局表，这里只读取引用，不写全局符号表。
local G_reader_settings = (type(_G.G_reader_settings) == "table") and _G.G_reader_settings or nil

-- ---------------------------------------------------------------- 参数区 ----
local CFG = {
    -- 设置项：存于 G_reader_settings.adaptive_autoturn（settings.reader.lua）
    setting_key    = "adaptive_autoturn",

    -- 交互提示完毕后的页面提示：默认 3 秒自动关闭，关闭后才正式开始分析采集。
    hint_timeout   = 3,

    -- 采集结束条件（先到先结算）：采够 target_samples 即结束；train_timeout_min
    -- 分钟为兜底超时，防止一直采不够。
    target_samples    = 40,
    train_timeout_min = 30,

    -- 采样
    min_interval   = 2,     -- 连翻/抖动阈值：gap<2 丢弃并计 burst
    abs_min_keep   = 6,     -- 特别小的异常间隔：gap<6 不入池（如 5s 误触/连翻）
    max_interval   = 300,
    min_samples    = 8,
    min_after_trim = 5,
    burst_count    = 3,

    -- 统计：双侧只剔除「异常」间隔，合理范围内一律保留、取全期均值。
    --   上侧：> 中位数 × outlier_factor（离开/走神造成的超长间隔）
    --   下侧：< max(abs_min_keep, 中位数 × small_outlier_ratio)（相对异常快）
    -- 不做近期加权：越读越快的近期样本会把均值拉小、导致翻页过快。
    -- 只剔除极端异常值、保留全部合理样本，可避免结果偏快或偏慢。
    outlier_factor      = 3,
    small_outlier_ratio = 0.4,

    -- 学习值
    min_sec        = 3,
    max_sec        = 120,
    default_sec    = 120,

    -- 兜底挂起间隔（秒）：足够大，采集期即使被误开启也不会立刻翻页
    suspend_sec    = 86400,

    LANG = {
        use_learned = "使用已有数据",
        manual      = "手动设置",
        retrain     = "重新训练",
        cancel      = "取消",
        b_title     = "自适应自动翻页",
        b_body      = "自动翻页已开启，请选择翻页间隔方式：",
    },
}

-- ---------------------------------------------------------------- 小工具 ----
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- 单调时钟原始值（fts）。AutoTurn.last_action_time 与 _schedule 的比较发生在
-- fts 域里，所以这里保留原值回填，不要转成秒。
local function now_raw()
    local ok, v = pcall(UIManager.getElapsedTimeSinceBoot, UIManager)
    if ok and v ~= nil then return v end
    return nil
end

-- 单调时钟秒数。优先 ui/time.to_number（fts→秒）；探测不到时退回 tonumber()。
local function now_s()
    local raw = now_raw()
    if raw == nil then return nil end
    if ok_time and type(time) == "table" and type(time.to_number) == "function" then
        local ok, v = pcall(time.to_number, raw)
        if ok and type(v) == "number" then return v end
    end
    local n = tonumber(raw)
    if type(n) == "number" then return n end
    return nil
end

-- ---------------------------------------------------------------- 纯函数 ----
local function sorted_copy(t)
    local s = {}
    for i = 1, #t do s[i] = t[i] end
    table.sort(s)
    return s
end

-- 线性插值分位数（type 7）。入参已升序。
local function quantile(sorted, p)
    local n = #sorted
    if n == 0 then return 0 end
    if n == 1 then return sorted[1] end
    local h = (n - 1) * p + 1
    local lo = math.floor(h)
    local hi = math.ceil(h)
    if lo == hi then return sorted[lo] end
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (h - lo)
end

local function mean(t)
    local n = #t
    if n == 0 then return 0 end
    local sum = 0
    for i = 1, n do sum = sum + t[i] end
    return sum / n
end

-- 统计级过滤：双侧只剔除「异常」间隔，合理范围内一律保留。以中位数为
-- 稳健基准：
--   * 上侧：v > 中位数 × outlier_factor（离开/走神造成的超长间隔）→ 剔除；
--   * 下侧：v < max(abs_min_keep, 中位数 × small_outlier_ratio)（误触/连翻等
--     相对异常快）→ 剔除。
-- 两层都只针对「极端」，中间的正常阅读节奏——无论偏小还是偏大——全部保留。
-- 为什么不用双侧 IQR / 阅读段碎片段丢弃：它们会把「读得慢」的合理样本
-- 一并删掉，把均值压小，使翻页节奏偏快。
local function trim_outliers(vals_in_order)
    local n = #vals_in_order
    if n == 0 then return {} end
    local sorted = sorted_copy(vals_in_order)
    local med = quantile(sorted, 0.5)
    -- 上界：中位数异常小时退化成绝对上限，避免把正常样本误剔光。
    local hi = med * CFG.outlier_factor
    if hi <= 0 then hi = CFG.max_interval end
    -- 下界：绝对下限（如 5s）与「相对中位数异常小」二者取较严者，
    -- 保证 5s 这类值一定被剔除，又不误删合理偏快样本。
    local lo = math.max(CFG.abs_min_keep, med * CFG.small_outlier_ratio)
    local kept = {}
    for i = 1, n do
        local v = vals_in_order[i]
        if v >= lo and v <= hi then kept[#kept + 1] = v end
    end
    return kept
end

-- 学习值计算（全局单值）。顺序：原始样本数下限 → 双侧剔除异常值 →
-- 剔除后下限 → 全期均值 → clamp → 四舍五入。
-- 刻意不做「近期加权」：越读越快的近期样本会把均值拉小，导致翻页太快；
-- 全期均值保留所有合理值，更贴近真实、偏从容的阅读节奏。
local function compute_learned(samples)
    local n = #samples
    if n < CFG.min_samples then return nil, "samples_lt_min" end
    local ordered = {}
    for i = 1, n do ordered[i] = samples[i].v end
    local kept = trim_outliers(ordered)
    if #kept < CFG.min_after_trim then return nil, "trim_lt_min" end
    local value = clamp(mean(kept), CFG.min_sec, CFG.max_sec)
    return math.floor(value + 0.5)
end

-- ---------------------------------------------------------------- 设置项 ----
-- 全局学习值统一存 G_reader_settings.adaptive_autoturn（见 read_learned /
-- write_learned）；本补丁不创建任何目录、不写任何数据文件、不依赖 lfs。

-- ---------------------------------------------------------------- 设置项 I/O --
-- 读取：G_reader_settings.adaptive_autoturn 出错/非表/字段非法 → 视为「无数据」。
local function read_learned()
    if not G_reader_settings
       or type(G_reader_settings.readSetting) ~= "function" then
        return nil
    end
    local ok, data = pcall(G_reader_settings.readSetting, G_reader_settings, CFG.setting_key)
    if not ok or type(data) ~= "table" then return nil end
    local sec = tonumber(data.learned_sec)
    if not sec or sec <= 0 then return nil end
    return {
        learned_sec   = math.floor(clamp(sec, CFG.min_sec, CFG.max_sec) + 0.5),
        trained       = data.trained == true,
        last_duration = tonumber(data.last_duration) or CFG.train_timeout_min,
    }
end

local function has_learned(conf)
    return conf ~= nil and conf.trained == true and type(conf.learned_sec) == "number"
end

-- last_duration 记录本次训练所用的兜底超时分钟数，值固定为
-- train_timeout_min。
local function write_learned(learned_sec, trained)
    if not G_reader_settings
       or type(G_reader_settings.saveSetting) ~= "function" then
        logger.warn("aat: G_reader_settings unavailable, value not persisted")
        return false
    end
    local ok = pcall(function()
        G_reader_settings:saveSetting(CFG.setting_key, {
            learned_sec   = math.floor(learned_sec),
            trained       = trained == true,
            last_duration = math.floor(CFG.train_timeout_min),
        })
        -- flush 兜底：确保学习值写回 settings.reader.lua，避免进程异常退出丢值。
        if type(G_reader_settings.flush) == "function" then
            G_reader_settings:flush()
        end
    end)
    if not ok then
        logger.warn("aat: failed to persist adaptive_autoturn")
        return false
    end
    return true
end

-- 本补丁不写任何翻页事件日志或数据文件，仅把学习值写进
-- G_reader_settings.adaptive_autoturn。

-- ---------------------------------------------------------------- 运行时态 --
local S = {
    conf        = nil,      -- 当前全局配置快照
    inst        = nil,      -- AutoTurn 实例
    ui          = nil,      -- ReaderUI 实例

    -- 会话
    ready_fired = false,    -- 本次会话是否已处理过 ReaderReady

    -- hook 记录（用于换书时 detach）
    orig_handleEvent      = nil, had_own_handleEvent = false,
    orig_schedule         = nil, had_own_schedule = false,
    orig_addToMainMenu    = nil, had_own_addToMainMenu = false,
    orig_switch           = nil, had_own_switch = false, switch_name = nil,
    hooks_on              = false,

    -- 采集
    phase       = "idle",   -- idle / pending(页面提示中) / collecting
    samples     = {},       -- { {v=dt, t=monotonic}, ... }
    last_page   = nil,
    last_turn_ts  = nil,    -- 上次「有效前序翻页」单调时刻
    last_sig_page = nil,    -- PageUpdate 去重：同页短时窗只记一次
    last_sig_ts   = nil,
    burst       = 0,        -- 连续 dt<min_interval 计数
    collect_end = nil,      -- 兜底超时截止时刻（getElapsedTimeSinceBoot，含待机的墙上单调时钟）
    collect_task = nil,     -- 兜底超时倒计时任务句柄（采够样本会提前撤销）
    hint_task   = nil,      -- 「页面提示」自动关闭后启动采集的任务句柄
    hint_end    = nil,      -- 页面提示截止时刻（休眠唤醒后按剩余重建 hint_task）
    suspend_snapshot = nil,

    -- 休眠：挂起时撤销两个定时任务，唤醒时按剩余时长重建（避免休眠期任务与
    -- 原生 _start() 重排的 task 叠加，也避免单调时钟冻结导致倒计时被拖长）。
    suspended_phase = nil,  -- 挂起时正处于 pending / collecting

    -- 防自激：计数而非布尔。_schedule 内会同步派发 GotoViewRel 再重入
    -- handleEvent，嵌套时布尔会被内层提前清掉；计数保证整段窗口都被识别。
    auto_firing = 0,
    probe       = {},
}

-- 统一撤销补丁自己排定的两个定时任务。换书、关文档、休眠、结算、中止都要
-- 无条件调用，杜绝幽灵任务泄漏到下一本书或下一轮唤醒。
local function clear_timers()
    if S.hint_task then
        pcall(UIManager.unschedule, UIManager, S.hint_task)
        S.hint_task = nil
    end
    if S.collect_task then
        pcall(UIManager.unschedule, UIManager, S.collect_task)
        S.collect_task = nil
    end
end

-- ---------------------------------------------------------------- 探测 ------
local SWITCH_ENABLE  = { "enable", "setEnabled", "toggle", "onEnable" }
local SWITCH_DISABLE = { "disable", "setEnabled", "toggle", "onDisable" }

local function probe_all(inst, ui)
    local p = {}
    p.autoturn_sec    = type(inst.autoturn_sec) ~= "nil"
    p.enabled         = type(inst.enabled) ~= "nil"
    p._enabled        = type(inst._enabled) == "function"
    p._schedule       = type(inst._schedule) == "function"
    p._unschedule     = type(inst._unschedule) == "function"
    p._start          = type(inst._start) == "function"
    p.addToMainMenu   = type(inst.addToMainMenu) == "function"
    p.handleEvent     = type(ui.handleEvent) == "function"
    p.ui_document     = type(ui.document) == "table"
    p.ui_doc_settings = type(ui.doc_settings) == "table"
    p.ui_view         = type(ui.view) == "table"
    p.paging          = type(ui.paging) == "table"
    p.rolling         = type(ui.rolling) == "table"
    p.getTopmost      = type(UIManager.getTopmostVisibleWidget) == "function"
    p.time            = (ok_time and type(time) == "table" and type(time.to_number) == "function")
    p.InputDialog     = (ok_ID and type(InputDialog) == "table")
    p.ButtonDialog    = (ok_BD and type(ButtonDialog) == "table")
    p.ConfirmBox      = (ok_CB and type(ConfirmBox) == "table")
    p.InfoMessage     = (ok_IM and type(InfoMessage) == "table")

    -- 开关方法：候选方法逐个探测，一个都不硬编码为「必然存在」。
    p.switch_enable, p.switch_disable = nil, nil
    for _, name in ipairs(SWITCH_ENABLE) do
        if type(inst[name]) == "function" then p.switch_enable = name; break end
    end
    for _, name in ipairs(SWITCH_DISABLE) do
        if type(inst[name]) == "function" then p.switch_disable = name; break end
    end
    S.probe = p
    logger.info("aat: probe",
        "autoturn_sec=", tostring(p.autoturn_sec),
        "enabled=", tostring(p.enabled),
        "_schedule=", tostring(p._schedule),
        "addToMainMenu=", tostring(p.addToMainMenu),
        "handleEvent=", tostring(p.handleEvent),
        "paging/rolling=", tostring(p.paging), "/", tostring(p.rolling),
        "switch(enable/disable)=", tostring(p.switch_enable), "/", tostring(p.switch_disable),
        "InputDialog=", tostring(p.InputDialog))
    return p
end

-- ---------------------------------------------------------------- UI 封装 ----
-- 页面提示默认 hint_timeout(3) 秒自动关闭；只有需要用户看清的重要提示才显式传更长值。
local function show_info(text, timeout)
    if not (ok_IM and type(InfoMessage) == "table") then return end
    pcall(function()
        UIManager:show(InfoMessage:new{ text = text, timeout = timeout or CFG.hint_timeout })
    end)
end

-- ButtonDialog 的按钮回调不会自动关闭，统一显式 close 后再执行动作。
-- enabled 显式给布尔值，避免 nil 被解释成禁用（button.lua 默认 true）。
local function show_buttons(title, body, rows)
    if not (ok_BD and type(ButtonDialog) == "table") then
        logger.warn("aat: ButtonDialog unavailable")
        return false
    end
    local dlg
    local buttons = {}
    for _, row in ipairs(rows) do
        local brow = {}
        for _, b in ipairs(row) do
            local action = b.fn
            brow[#brow + 1] = {
                text    = b.text,
                enabled = (b.enabled ~= false),
                callback = function()
                    if dlg then pcall(function() UIManager:close(dlg) end) end
                    if action then pcall(action) end
                end,
            }
        end
        buttons[#buttons + 1] = brow
    end
    local ok = pcall(function()
        local text = title
        if body and body ~= "" then text = title .. "\n" .. body end
        dlg = ButtonDialog:new{ title = text, buttons = buttons }
        UIManager:show(dlg)
    end)
    if not ok then logger.warn("aat: show_buttons failed") end
    return ok
end

-- ConfirmBox 的按钮回调会自动 close（confirmbox.lua:135-141）。
-- 用于「采集失败，是否重试」这类二选一确认。
local function show_confirm(text, ok_text, ok_fn, cancel_text, cancel_fn)
    if not (ok_CB and type(ConfirmBox) == "table") then return false end
    return pcall(function()
        UIManager:show(ConfirmBox:new{
            text = text,
            ok_text = ok_text,
            cancel_text = cancel_text or L(CFG.LANG.cancel),
            ok_callback = function() if ok_fn then pcall(ok_fn) end end,
            cancel_callback = function() if cancel_fn then pcall(cancel_fn) end end,
        })
    end) == true
end

-- ---------------------------------------------------------------- Autoturn --
local function is_enabled(inst)
    if S.probe._enabled then
        local ok, v = pcall(inst._enabled, inst)
        if ok then return v and true or false end
    end
    -- 字段级兜底，与 _enabled() 语义一致
    return (inst.enabled == true) and (tonumber(inst.autoturn_sec) or 0) > 0
end

local function call_unschedule(inst)
    if S.probe._unschedule then pcall(inst._unschedule, inst) end
    -- 无论 _unschedule 是否存在，都直接取消已排定任务，避免残留定时翻页。
    if type(inst.task) ~= "nil" then pcall(UIManager.unschedule, UIManager, inst.task) end
end

-- 优先调用探测到的关闭接口；无论成功与否，字段级挂起都兜底执行。
local function suspend_autoturn(inst)
    local used = nil
    local name = S.probe.switch_disable
    if name then
        local ok = pcall(function()
            if name == "setEnabled" then inst:setEnabled(false)
            elseif name == "toggle" then
                -- toggle 只在当前为开时才切，避免误把关闭态打开
                if is_enabled(inst) then inst:toggle() end
            else inst[name](inst) end
        end)
        if ok then used = name end
    end
    S.suspend_snapshot = {
        enabled          = inst.enabled,
        autoturn_sec     = inst.autoturn_sec,
        last_action_time = inst.last_action_time,
        onResume         = inst.onResume, -- 采集期必须摘掉，避免唤醒时原生 _start 重启自动翻页
    }
    inst.enabled = false
    inst.autoturn_sec = CFG.suspend_sec
    inst.onResume = nil
    call_unschedule(inst)
    logger.info("aat: autoturn suspended (switch=", tostring(used), ")")
end

-- 开启：把 AutoTurn 原生菜单 callback 的副作用补齐，再交回原生 _start()
-- 完成调度与待机标志的成对管理。补丁一律不直接写 PluginShare.pause_auto_suspend：
-- 它由 _start()(true) / _unschedule()(false) 成对维护；补丁单边只置 true，
-- 设备会一直无法自动待机，并与电源管理 / 其他插件争用（锁屏唤醒卡死根因）。
local function resume_autoturn(inst, sec)
    sec = math.floor(clamp(sec, CFG.min_sec, CFG.max_sec) + 0.5)

    -- 兼容分支：老版本探测到的开关方法，之后再字段级二次钉死。
    local name = S.probe.switch_enable
    if name then
        pcall(function()
            if name == "setEnabled" then inst:setEnabled(true)
            elseif name == "toggle" then
                if not is_enabled(inst) then inst:toggle() end
            else inst[name](inst) end
        end)
    end
    inst.autoturn_sec = sec
    inst.enabled = true

    -- 补写原生 callback 的持久化副作用：拦截菜单后原 callback 不执行，
    -- 不补这两项，下次开书 init() 读回旧值，自动翻页会静默失效。
    pcall(function()
        if G_reader_settings and type(G_reader_settings.saveSetting) == "function" then
            G_reader_settings:saveSetting("autoturn_timeout_seconds", sec)
        end
        if G_reader_settings and type(G_reader_settings.makeTrue) == "function" then
            G_reader_settings:makeTrue("autoturn_enabled")
        end
        if G_reader_settings and type(G_reader_settings.flush) == "function" then
            G_reader_settings:flush()
        end
    end)
    -- 补挂唤醒回调：原生 callback 里 self.onResume = self._onResume。
    -- 缺了它，锁屏唤醒后 AutoTurn 不会自己 _start() 恢复调度与待机标志。
    pcall(function()
        if type(inst._onResume) == "function" then inst.onResume = inst._onResume end
    end)

    -- 先撤旧调度（_unschedule 内置 pause_auto_suspend=false），再 _start()
    -- （内置把 pause_auto_suspend 置真 + last_action_time + _schedule + 原生提示）。
    call_unschedule(inst)
    if S.probe._start then
        pcall(inst._start, inst)
    else
        -- 老版本没有 _start：字段级兜底重排，绝不碰全局待机标志。
        pcall(function() inst.last_action_time = now_raw() or 0 end)
        if S.probe._schedule then pcall(inst._schedule, inst) end
    end
    logger.info("aat: autoturn enabled via native _start sec=", sec)
end

-- 仅还原挂起前的实例态，不动 G_reader_settings（不改其它模块持久状态）。
local function restore_autoturn(inst)
    if not inst then return end
    local snap = S.suspend_snapshot
    if not snap then return end
    inst.enabled          = snap.enabled
    inst.autoturn_sec     = snap.autoturn_sec
    inst.last_action_time = snap.last_action_time
    inst.onResume         = snap.onResume
    call_unschedule(inst)
    -- 挂起前若本就开启，交回原生 _start() 重建调度与待机标志（保持配对）。
    if is_enabled(inst) and S.probe._start then pcall(inst._start, inst) end
    S.suspend_snapshot = nil
end

-- ---------------------------------------------------------------- 全局值 ----
local function refresh_conf()
    S.conf = read_learned()
    if S.conf == nil then
        logger.info("aat: no valid learned value (treated as empty)")
    else
        logger.info("aat: global learned_sec=", tostring(S.conf.learned_sec),
            "trained=", tostring(S.conf.trained))
    end
end

-- ---------------------------------------------------------------- 前向声明 --
-- 采集流程与弹窗互相引用，统一前向声明后逐个赋值，避免任何全局函数。
local on_page_changed, finish_collection, abort_collection,
      start_collection, begin_collecting, arm_collect_task, show_manual_dialog,
      show_dialog_enable,
      action_use_learned, action_cancel_enable, apply_value

-- 落地：写学习值到 G_reader_settings + 开启 + 提示。持久化失败只记日志，
-- 运行时仍按该值开启。兜底超时固定为 train_timeout_min 分钟。
apply_value = function(sec, trained, msg)
    if not write_learned(sec, trained) then
        logger.warn("aat: value not persisted, runtime value still applied")
    end
    refresh_conf()
    resume_autoturn(S.inst, sec)
    show_info(msg)
end

-- 使用已有数据：直接设 autoturn_sec 并开启，不覆写 conf。
action_use_learned = function()
    local sec = has_learned(S.conf) and S.conf.learned_sec or CFG.default_sec
    resume_autoturn(S.inst, sec)
    show_info(string.format(L("已使用已有数据，自动翻页间隔 %d 秒。"), sec))
    logger.info("aat: use learned sec=", sec)
end

action_cancel_enable = function()
    -- 弹窗 B 的「取消」：不开启，保持关闭。
    if S.inst then
        S.inst.enabled = false
        call_unschedule(S.inst)
    end
    logger.info("aat: enable cancelled, autoturn stays off")
end

-- ---------------------------------------------------------------- 采集 ------
abort_collection = function(msg)
    if S.phase == "collecting" or S.phase == "pending" then
        clear_timers()
        S.phase = "idle"
        S.auto_firing = 0
        restore_autoturn(S.inst)
    else
        clear_timers()  -- 即便 idle 也清，杜绝任何残留句柄
    end
    S.collect_end = nil
    S.hint_end = nil
    S.suspended_phase = nil
    S.suspend_snapshot = nil
    show_info(msg, 6)
end

-- 间隔选择框里选「重新训练」直接进这里。
-- 主结束条件是采够 target_samples，train_timeout_min 仅作兜底超时。
start_collection = function()
    local inst, ui = S.inst, S.ui
    if not inst or not ui then return end

    -- 保底：页面事件探测失败则放弃本次采集，恢复 Autoturn 原状态。
    if not (S.probe.handleEvent and (S.probe.paging or S.probe.rolling)) then
        logger.warn("aat: page-event probe failed, abort collection")
        abort_collection(L("页面事件接口探测失败，已放弃本次采集。"))
        return
    end
    if not S.probe._schedule then
        logger.warn("aat: _schedule missing, cannot mark auto turns reliably")
    end

    -- A1：滚动模式（非分页视图）中止采集并提示。
    local scroll_mode = false
    pcall(function()
        if type(ui.view) == "table" and ui.view.view_mode == "scroll" then
            scroll_mode = true
        end
    end)
    if scroll_mode then
        logger.warn("aat: scroll mode, abort collection")
        abort_collection(L("当前为滚动模式，无法采集翻页间隔，已放弃本次学习。"))
        return
    end

    -- 立即挂起 Autoturn：交互提示 + 页面提示这 3 秒里都不允许自动翻页。
    suspend_autoturn(inst)

    -- 交互提示（弹窗 B）完毕 → 先进入 pending，弹一个默认 3 秒自动关闭的
    -- 页面提示；提示关闭后才正式开始分析采集（begin_collecting）。
    -- 这样刚点完按钮、屏幕还在弹提示时的翻页不会被误计入样本。
    S.phase = "pending"
    S.samples = {}
    S.last_page = nil
    S.last_turn_ts = nil
    S.last_sig_page = nil
    S.last_sig_ts = nil
    S.burst = 0
    S.auto_firing = 0
    S.collect_end = nil
    S.hint_end = (now_s() or 0) + CFG.hint_timeout
    S.suspended_phase = nil

    show_info(string.format(
        L("即将开始采集：采够 %d 个翻页间隔会自动结束（最长 %d 分钟）。本提示 %d 秒后自动关闭，之后开始分析采集；期间自动翻页已关闭，请正常手动翻页。"),
        CFG.target_samples, CFG.train_timeout_min, CFG.hint_timeout))
    logger.info("aat: page hint shown, collecting starts in ", CFG.hint_timeout, "s")

    -- 只用一个任务句柄驱动「提示关闭 → 开始采集」，切书/中止/休眠时可 unschedule。
    clear_timers()
    S.hint_task = function() begin_collecting() end
    pcall(UIManager.scheduleIn, UIManager, CFG.hint_timeout, S.hint_task)
end

-- 排（或重排）兜底超时任务。collect_end 基于 getElapsedTimeSinceBoot（含休眠的
-- 墙上单调时钟）是权威截止；scheduleIn 用纯 CLOCK_MONOTONIC，休眠期间不走，
-- 所以它只是「到点叫醒我复核」的触发器，真正是否到点一律用 collect_end 判定。
-- 这样锁屏再久，唤醒后也能立刻发现已超时并结算，不会把 30 分钟拖成 57 分钟。
arm_collect_task = function()
    if S.phase ~= "collecting" then return end
    if S.collect_task then pcall(UIManager.unschedule, UIManager, S.collect_task) end
    local now = now_s() or 0
    local remain = (S.collect_end or now) - now
    if remain <= 0 then
        finish_collection("timeout")
        return
    end
    S.collect_task = function()
        if S.phase ~= "collecting" then return end
        local n2 = now_s() or 0
        -- 任务被提前触发（KOReader 唤醒平移任务队列）时按剩余重排，不误结算。
        if S.collect_end and n2 < S.collect_end - 0.5 then
            arm_collect_task()
            return
        end
        finish_collection("timeout")
    end
    pcall(UIManager.scheduleIn, UIManager, remain, S.collect_task)
end

-- 页面提示自动关闭后：真正进入 collecting，起兜底超时倒计时开始采样。
-- 主结束条件在 on_page_changed（采够 target_samples）；这里只兜底超时。
-- 若此间被切书 / 中止（phase 已变），这里直接忽略，避免幽灵采集。
begin_collecting = function()
    if S.phase ~= "pending" then return end
    S.hint_task = nil
    S.hint_end = nil
    S.phase = "collecting"
    S.collect_end = (now_s() or 0) + CFG.train_timeout_min * 60
    S.auto_firing = 0
    S.suspended_phase = nil
    logger.info("aat: page hint closed, collection started, target=",
        CFG.target_samples, "timeout_min=", CFG.train_timeout_min)
    arm_collect_task()
end

-- ---------------------------------------------------------------- 弹窗 B ----
-- 唯一触发入口：用户开启自动翻页（Autoturn 由关→开）时由 wrap_menu /
-- wrap_switch_methods 拦截后弹出。开书阶段保持静默，不打扰用户。
-- 「重新训练」直接 start_collection：采够 target_samples 自动结束，
-- train_timeout_min 分钟兜底超时。
show_dialog_enable = function()
    local learned = has_learned(S.conf) and S.conf.learned_sec or nil
    local label = learned
        and string.format(L(CFG.LANG.use_learned) .. "（%d 秒/页）", learned)
        or L(CFG.LANG.use_learned)
    show_buttons(L(CFG.LANG.b_title), L(CFG.LANG.b_body), {
        {
            { text = label, enabled = (learned ~= nil), fn = action_use_learned },
            { text = L(CFG.LANG.retrain), fn = function() start_collection() end },
        },
        {
            { text = L(CFG.LANG.manual),
              enabled = (ok_ID and type(InputDialog) == "table"),
              fn = function() show_manual_dialog(true) end },
            { text = L(CFG.LANG.cancel), fn = action_cancel_enable },
        },
    })
end

-- ---------------------------------------------------------------- 手动设置 --
-- initial_val：非法输入重开时带上一次的输入值；from_enable 表示来自弹窗 B。
show_manual_dialog = function(from_enable, initial_val)
    if not (ok_ID and type(InputDialog) == "table") then
        logger.warn("aat: InputDialog unavailable, manual disabled")
        show_info(L("本设备不支持输入框，无法手动设置。"))
        return
    end
    local default_val = initial_val or (has_learned(S.conf) and S.conf.learned_sec or 30)
    local dlg
    pcall(function()
        dlg = InputDialog:new{
            title       = L("设置翻页间隔（秒）"),
            input       = tostring(default_val),
            input_type  = "number",
            input_hint  = L("3 ~ 120"),
            description = L("请输入 3~120 的整数"),
            buttons = {
                {
                    { text = L(CFG.LANG.cancel), callback = function()
                        if dlg then pcall(function() UIManager:close(dlg) end) end
                        if from_enable then action_cancel_enable() end
                    end },
                    { text = L("确定"), is_enter_default = true, callback = function()
                        local raw = nil
                        if dlg and type(dlg.getInputText) == "function" then
                            local ok_get, txt = pcall(dlg.getInputText, dlg)
                            if ok_get then raw = txt end
                        end
                        if dlg then pcall(function() UIManager:close(dlg) end) end
                        local v = tonumber(raw)
                        if not v or v ~= math.floor(v) or v < CFG.min_sec or v > CFG.max_sec then
                            show_info(L("输入无效，请输入 3~120 的整数。"))
                            -- 短延迟后重开，避免弹窗叠加；带上一次输入便于修改。
                            pcall(UIManager.scheduleIn, UIManager, 0.3, function()
                                show_manual_dialog(from_enable, raw)
                            end)
                            return
                        end
                        apply_value(v, true,
                            string.format(L("自动翻页间隔已设为 %d 秒"), v))
                        logger.info("aat: manual value=", v)
                    end },
                },
            },
        }
        UIManager:show(dlg)
        if type(dlg.onShowKeyboard) == "function" then pcall(dlg.onShowKeyboard, dlg) end
    end)
end

-- ---------------------------------------------------------------- 采样 ------
-- A7：非阅读前台（菜单/设置等）不计时，回到阅读界面后重置 last_turn_ts。
-- 只有明确是别的具名界面才判非前台；弹窗类 widget 通常没有 name，放行。
local function is_reader_foreground()
    if not S.probe.getTopmost then return true end
    local ok, top = pcall(UIManager.getTopmostVisibleWidget, UIManager)
    if not ok or not top then return true end
    if top.name == "ReaderUI" or top.name == nil then return true end
    return false
end

-- A4 重排 / A5 绝对跳转：命中即重置计时，不入样本池。
-- onSuspend / onResume 单独在 on_event_after 里处理（撤销并重建定时任务），
-- 不放在这里；它们需要比「重置计时」更完整的动作。
-- 注意不含 onGotoViewRel（它是正常翻页事件）与 onPosUpdate（位置级事件）。
local RESET_HANDLERS = {
    onSetDimensions = true, onUpdatePos = true, onDocumentRerendered = true,
    onBBoxUpdate = true, onRotationUpdate = true, onChangeScreenMode = true,
    onGotoPage = true, onGotoPercent = true, onGotoPercentage = true,
    onGotoXPointer = true, onGotoPageLink = true, onGoToLink = true,
    onGotoLocation = true, onBookmarkGoTo = true,
}

-- 每次页面变更后统一处理：非采集期只做去重维护；采集期才决定是否把间隔入池。
-- 本补丁只维护运行时采样状态，不产生任何翻页日志。
on_page_changed = function(new_page, ts_mono)
    if type(new_page) ~= "number" then return end

    -- 同一轮翻页若被重复派发（同页 + 极短时窗），只记一次。
    if S.last_sig_page == new_page and S.last_sig_ts and ts_mono
       and (ts_mono - S.last_sig_ts) < 0.25 then
        return
    end
    S.last_sig_page, S.last_sig_ts = new_page, ts_mono

    if S.phase ~= "collecting" then return end

    -- ④ collect_end 权威判据：它与 ts_mono 同为 getElapsedTimeSinceBoot（含休眠
    -- 的墙上单调时钟）。scheduleIn 用纯 CLOCK_MONOTONIC，休眠期间不走；即便它
    -- 被冻结，唤醒后第一次翻页也会在这里按真实截止时刻立即结算，不会把
    -- 30 分钟拖成 57 分钟。到点即结算，且不把这个跨休眠超长间隔计入样本。
    if S.collect_end and ts_mono and ts_mono >= S.collect_end then
        finish_collection("timeout")
        return
    end

    -- A1（采集期动态切换）：滚动模式中止采集。
    local scroll_now = false
    pcall(function()
        if S.ui and type(S.ui.view) == "table" and S.ui.view.view_mode == "scroll" then
            scroll_now = true
        end
    end)
    if scroll_now then
        abort_collection(L("已切换为滚动模式，采集已中止。"))
        return
    end

    -- A7 前台判断：非阅读前台不计时，回到阅读界面后重置 last_turn_ts。
    if not is_reader_foreground() then
        S.last_turn_ts = nil
        return
    end

    -- A2 页码非相邻前进：丢弃并重置 last_turn_ts。
    local prev = S.last_page
    S.last_page = new_page
    if prev == nil then
        S.last_turn_ts = ts_mono
        return
    end
    if (new_page - prev) ~= 1 then
        S.last_turn_ts = nil
        S.burst = 0
        return
    end

    if not ts_mono or not S.last_turn_ts then
        S.last_turn_ts = ts_mono
        return
    end
    local gap = ts_mono - S.last_turn_ts
    S.last_turn_ts = ts_mono

    -- B1 dt < 2：丢弃；连续 burst_count 次判定翻找模式，重置计时。
    if gap < CFG.min_interval then
        S.burst = S.burst + 1
        if S.burst >= CFG.burst_count then
            S.last_turn_ts = nil
            S.burst = 0
            logger.info("aat: burst/scan mode detected, timing reset")
        end
        return
    end
    -- B1.5 特别小的异常间隔（例如 5s 的误触双击）：不入池。
    -- 上面已把 last_turn_ts 更新为本次时刻，这里直接 return，后续间隔仍从
    -- 本次翻页起算，不会因为丢弃这个样本而把后续节奏算歪。
    if gap < CFG.abs_min_keep then
        S.burst = 0
        logger.info("aat: too-small interval dropped ", string.format("%.2f", gap))
        return
    end
    -- B2 dt > 300：丢弃并重置。
    if gap > CFG.max_interval then
        S.last_turn_ts = nil
        S.burst = 0
        return
    end
    -- B3 入池
    S.burst = 0
    S.samples[#S.samples + 1] = { v = gap, t = ts_mono }
    logger.info("aat: sample ", string.format("%.2f", gap),
        " (", #S.samples, "/", CFG.target_samples, ")")
    -- 主结束条件：采够足够数据量即结算；兜底超时由 finish_collection 撤销。
    if #S.samples >= CFG.target_samples then finish_collection("enough") end
end

-- ---------------------------------------------------------------- 结束 ------
finish_collection = function(reason)
    if S.phase ~= "collecting" then return end
    S.phase = "idle"
    -- 无条件撤销两个定时句柄；结算后不留任何幽灵任务（⑥）。
    clear_timers()
    S.collect_end = nil
    S.hint_end = nil
    S.suspended_phase = nil
    S.auto_firing = 0

    local learned, why = compute_learned(S.samples)
    if learned then
        apply_value(learned, true,
            string.format(L("学习完成，自动翻页间隔已设为 %d 秒"), learned))
        logger.info("aat: collection done reason=", tostring(reason),
            "samples=", #S.samples, "learned=", learned)
    else
        -- 采集失败（超时未采够或异常值过多被剔光）：不改全局值，用 default_sec
        -- 开启并提示可重试；重试直接重新采集。
        local fb = CFG.default_sec
        resume_autoturn(S.inst, fb)
        local msg = string.format(
            L("有效样本不足或异常值过多，自动翻页已按默认 %d 秒开启，可重新训练。"), fb)
        if not show_confirm(msg, L(CFG.LANG.retrain),
                            function() start_collection() end,
                            L(CFG.LANG.cancel), nil) then
            show_info(msg, 6)
        end
        logger.warn("aat: collection failed reason=", tostring(reason),
            "why=", tostring(why), "samples=", #S.samples, "fallback=", fb)
    end
    S.suspend_snapshot = nil
end

-- ---------------------------------------------------------------- Hook ------
-- 主 hook：包裹 ReaderUI 实例的 handleEvent。先跑原逻辑（事件要传播给子模块），
-- 再按真实 handler 名分流：ReaderReady / 页面事件 / 重置事件 / 关闭文档。
local function on_event_after(this, handler, args)
    if handler == "onReaderReady" then
        if S.ready_fired then return end
        -- 双保险：只在真正的 ReaderUI 实例上生效，避免文件管理器等界面误入。
        if type(this) ~= "table" or type(this.document) ~= "table" then return end
        S.ready_fired = true
        -- 开新书：无条件撤销任何残留定时句柄、清空全部采集状态（⑥）。
        clear_timers()
        S.phase = "idle"
        S.auto_firing = 0
        S.collect_end = nil
        S.hint_end = nil
        S.suspended_phase = nil
        S.samples = {}
        S.last_page = nil
        S.last_turn_ts = nil
        S.last_sig_page = nil
        S.last_sig_ts = nil
        S.burst = 0
        refresh_conf()
        -- 触发点 = 「用户开启自动翻页」：开书阶段保持静默，只挂好 hook。
        -- 真正的介入点在 wrap_menu / wrap_switch_methods 拦截「关→开」时。
        logger.info("aat: ReaderReady fired, patch armed; trigger = enabling autoturn")
        return
    end

    if handler == "onCloseDocument" then
        -- ⑥ 书籍关闭：无条件撤销两个定时句柄并清空状态，无论当前 phase，
        -- 避免残留任务 / 标志串到下一本书。暂停电源标志由 AutoTurn 原生
        -- onCloseDocument→_unschedule 负责，本补丁不插手。
        clear_timers()
        if S.phase == "collecting" or S.phase == "pending" then
            S.phase = "idle"
            S.auto_firing = 0
            restore_autoturn(S.inst)
        end
        S.collect_end = nil
        S.hint_end = nil
        S.suspended_phase = nil
        S.suspend_snapshot = nil
        S.ready_fired = false
        return
    end

    -- ③ 休眠：撤销补丁自己的两个定时任务，避免它们在锁屏期间冻结、唤醒后
    -- 与 AutoTurn 原生 _start() 重排的 task 叠加。phase / collect_end / hint_end
    -- 全部保留，交给 onResume 按剩余时长重建（或直接判定到点结算）。
    if handler == "onSuspend" then
        if S.phase == "collecting" or S.phase == "pending" then
            S.suspended_phase = S.phase
            clear_timers()
            S.last_turn_ts = nil   -- 跨休眠的间隔不是有效阅读节奏
            S.burst = 0
            logger.info("aat: suspend, timers cleared phase=", S.phase)
        end
        return
    end

    -- ③ 唤醒：按 collect_end / hint_end 的剩余时长重建定时任务。
    -- 剩余由「含休眠的墙上单调时钟」算出，锁屏多久都会如实扣减，到点即结算。
    if handler == "onResume" then
        if S.suspended_phase == "collecting" and S.phase == "collecting" then
            arm_collect_task()   -- 内部按 collect_end 复核；到点直接 finish("timeout")
            logger.info("aat: resume, collect timer rebuilt")
        elseif S.suspended_phase == "pending" and S.phase == "pending" then
            local now = now_s() or 0
            local remain = (S.hint_end or now) - now
            if remain <= 0 then
                begin_collecting()
            else
                clear_timers()
                S.hint_task = function() begin_collecting() end
                pcall(UIManager.scheduleIn, UIManager, remain, S.hint_task)
            end
            logger.info("aat: resume, hint timer rebuilt remain=", remain)
        end
        S.suspended_phase = nil
        S.last_turn_ts = nil
        S.burst = 0
        return
    end

    if RESET_HANDLERS[handler] then
        if S.phase == "collecting" then
            S.last_turn_ts = nil
            S.burst = 0
        end
        return
    end

    if handler == "onPageUpdate" and type(args) == "table" then
        local new_page = args[1]
        -- A3：自动翻页产生的 PageUpdate 由 wrap_schedule 的 auto_firing 计数识别，
        -- 不入样本池；并防自激（用户若训练期手动开了 Autoturn，重新挂起）。
        if S.auto_firing > 0 then
            if S.phase == "collecting" and S.inst and is_enabled(S.inst) then
                logger.warn("aat: autoturn re-enabled during collection, suspending again")
                S.inst.enabled = false
                S.inst.autoturn_sec = CFG.suspend_sec
                call_unschedule(S.inst)
            end
            return
        end
        on_page_changed(new_page, now_s())
        return
    end
    -- 不处理 onPosUpdate：它是位置级事件（同页滚动也会发），拿来计页会重复计数；
    -- ReaderPaging 与 ReaderRolling 在真实翻页时都已派发 PageUpdate，足够用。
end

-- 辅 hook：包裹 AutoTurn._schedule，在它发出 GotoViewRel 的窗口内置
-- auto_firing，用于把自动翻页与手动翻页区分开（A3）。
-- 用计数而非布尔：_schedule 内部会同步 handleEvent(GotoViewRel)，期间可能
-- 再次重入 _schedule（菜单打断、嵌套调度）。布尔会被内层提前清掉，导致外层
-- 后半段的自动翻页被误判成手动翻页；计数保证整个嵌套窗口都被识别。
local function wrap_schedule(inst)
    if not S.probe._schedule then return end
    S.had_own_schedule = (rawget(inst, "_schedule") ~= nil)
    S.orig_schedule = inst._schedule
    inst._schedule = function(this, ...)
        S.auto_firing = S.auto_firing + 1
        local ok, r1, r2, r3 = pcall(S.orig_schedule, this, ...)
        S.auto_firing = S.auto_firing - 1
        if S.auto_firing < 0 then S.auto_firing = 0 end
        if not ok then
            logger.warn("aat: wrapped _schedule error:", tostring(r1))
            return nil
        end
        return r1, r2, r3
    end
end

-- 弹窗 B 的真实挂载点：AutoTurn.addToMainMenu 每次构建菜单都会重新生成
-- menu_items.autoturn.callback。包一层，在「当前为关」且回调即将开启时
-- 拦下并弹窗 B；「当前为开」则放行原逻辑（对应「开→关直接放行」）。
local function wrap_menu(inst)
    if not S.probe.addToMainMenu then
        logger.warn("aat: addToMainMenu missing -> 弹窗 B 拦截放弃")
        return false
    end
    S.had_own_addToMainMenu = (rawget(inst, "addToMainMenu") ~= nil)
    S.orig_addToMainMenu = inst.addToMainMenu
    inst.addToMainMenu = function(this, menu_items)
        local ok = pcall(S.orig_addToMainMenu, this, menu_items)
        if not ok then return end
        pcall(function()
            local item = menu_items and menu_items.autoturn
            if type(item) ~= "table" or type(item.callback) ~= "function" then return end
            local orig_cb = item.callback
            item.callback = function(menu)
                if is_enabled(this) then
                    -- 已开启 → 用户可能要改时长/关闭，直接放行原逻辑
                    return orig_cb(menu)
                end
                -- pending / collecting 期间不重复弹窗 B。
                if S.phase == "pending" or S.phase == "collecting" then
                    return orig_cb(menu)
                end
                -- 关→开：拦下，改为弹窗 B（由补丁自己决定间隔方式）
                logger.info("aat: intercepted autoturn enable -> dialog B")
                show_dialog_enable()
                return true
            end
            -- 采集期在菜单标题上显示样本数增长，用 text_func 追加，
            -- 不额外弹窗打扰阅读。真实 addToMainMenu 用 text_func 生成标题。
            if type(item.text_func) == "function" then
                local orig_tf = item.text_func
                item.text_func = function()
                    local base = orig_tf()
                    if S.phase == "collecting" then
                        return string.format("%s（采集中 %d/%d）",
                            tostring(base), #S.samples, CFG.target_samples)
                    elseif S.phase == "pending" then
                        return string.format("%s（准备开始采集）", tostring(base))
                    end
                    return base
                end
            end
        end)
    end
    return true
end

-- 候选开关方法路径：仅当真实探测到这些方法时才包一层。
-- 官方源码无此方法，此分支为兼容分支/老版本保留。
local function wrap_switch_methods(inst)
    local name = S.probe.switch_enable
    if not name then return false end
    local orig = inst[name]
    if type(orig) ~= "function" then return false end
    S.switch_name = name
    S.had_own_switch = (rawget(inst, name) ~= nil)
    S.orig_switch = orig
    inst[name] = function(this, ...)
        -- pending（页面提示中）/ collecting（采集中）都不重复弹窗 B。
        if not is_enabled(this) and S.phase ~= "collecting" and S.phase ~= "pending" then
            logger.info("aat: intercepted switch ", name, " -> dialog B")
            show_dialog_enable()
            return true
        end
        return orig(this, ...)
    end
    return true
end

local function detach_hooks()
    local inst, ui = S.inst, S.ui
    -- ⑥ 换书 detach 时无条件撤销两个定时句柄并复位采集态，杜绝幽灵任务。
    clear_timers()
    S.collect_end = nil
    S.hint_end = nil
    S.suspended_phase = nil
    S.auto_firing = 0
    S.phase = "idle"
    if ui and S.orig_handleEvent then
        if S.had_own_handleEvent then ui.handleEvent = S.orig_handleEvent
        else ui.handleEvent = nil end
    end
    if inst then
        if S.orig_schedule then
            if S.had_own_schedule then inst._schedule = S.orig_schedule
            else inst._schedule = nil end
        end
        if S.orig_addToMainMenu then
            if S.had_own_addToMainMenu then inst.addToMainMenu = S.orig_addToMainMenu
            else inst.addToMainMenu = nil end
        end
        if S.orig_switch and S.switch_name then
            if S.had_own_switch then inst[S.switch_name] = S.orig_switch
            else inst[S.switch_name] = nil end
        end
    end
    S.orig_handleEvent, S.orig_schedule = nil, nil
    S.orig_addToMainMenu, S.orig_switch, S.switch_name = nil, nil, nil
    S.hooks_on = false
    logger.info("aat: hooks detached")
end

local function ensure_hooks(inst, ui)
    if S.hooks_on then return end
    if not (S.probe.handleEvent and S.probe.autoturn_sec) then
        logger.warn("aat: essential interface missing, skip patch")
        return
    end
    S.had_own_handleEvent = (rawget(ui, "handleEvent") ~= nil)
    S.orig_handleEvent = ui.handleEvent
    ui.handleEvent = function(this, event, ...)
        local r1, r2, r3 = S.orig_handleEvent(this, event, ...)
        -- 原逻辑优先；补丁观察逻辑出错绝不影响主流程。
        pcall(function()
            if type(event) == "table" then
                on_event_after(this, event.handler, event.args)
            end
        end)
        return r1, r2, r3
    end
    wrap_schedule(inst)
    -- 弹窗 B：优先探测到的开关方法，否则用真实菜单回调；都失败才放弃。
    local via = nil
    if wrap_switch_methods(inst) then via = "switch" end
    if not via and wrap_menu(inst) then via = "menu" end
    if not via then logger.warn("aat: no enable hook -> 弹窗 B disabled") end
    S.hooks_on = true
    logger.info("aat: hooks installed, dialog-B via=", tostring(via))
end

-- ---------------------------------------------------------------- 入口 ------
local function on_autoturn_plugin(plugin)
    -- userpatch.registerPatchPluginFunc 的回调参数是插件「类表」，不是实例；
    -- 实例要经 PluginLoader:getPluginInstance 取（pluginloader.lua:573）。
    local inst = nil
    if ok_pl and type(PluginLoader) == "table"
       and type(PluginLoader.getPluginInstance) == "function" then
        pcall(function() inst = PluginLoader:getPluginInstance("autoturn") end)
    end
    if type(inst) ~= "table" and type(plugin) == "table" then
        -- 某些版本 createPluginInstance 把实例挂在类表字段上，做一次兜底。
        if type(plugin.autoturn_sec) ~= "nil" then inst = plugin end
    end
    if type(inst) ~= "table" then
        logger.warn("aat: autoturn instance unavailable, skip")
        return
    end
    local ui = inst.ui
    if type(ui) ~= "table" or type(ui.document) ~= "table" then
        logger.warn("aat: ReaderUI/document unavailable, skip")
        return
    end
    -- 换书会新建 ReaderUI / AutoTurn 实例，必须把旧 hook 还原再重挂。
    if S.hooks_on and (S.inst ~= inst or S.ui ~= ui) then
        detach_hooks()
        S.ready_fired = false
    end
    S.inst, S.ui = inst, ui
    probe_all(inst, ui)
    if not S.probe.autoturn_sec then
        logger.warn("aat: autoturn_sec field missing, skip patch")
        return
    end
    refresh_conf()
    ensure_hooks(inst, ui)
end

local function apply()
    logger.info("aat: adaptive-autoturn patch loading")

    -- 首选：官方 userpatch 提供的插件级回调（回调发生在实例创建成功之后）。
    if ok_up and type(userpatch) == "table"
       and type(userpatch.registerPatchPluginFunc) == "function" then
        local ok, err = pcall(userpatch.registerPatchPluginFunc, "autoturn", on_autoturn_plugin)
        if ok then
            logger.info("aat: registered via registerPatchPluginFunc")
            return
        end
        logger.warn("aat: registerPatchPluginFunc failed:", tostring(err))
    end

    -- 兜底：老版本没有 registerPatchPluginFunc，自行包裹 createPluginInstance。
    if ok_pl and type(PluginLoader) == "table"
       and type(PluginLoader.createPluginInstance) == "function" then
        local orig = PluginLoader.createPluginInstance
        PluginLoader.createPluginInstance = function(this, plugin, attr)
            local ok, instance = orig(this, plugin, attr)
            if ok and type(plugin) == "table" and plugin.name == "autoturn" then
                pcall(on_autoturn_plugin, plugin)
            end
            return ok, instance
        end
        logger.info("aat: registered via createPluginInstance fallback")
        return
    end

    logger.warn("aat: no plugin hook mechanism, patch skipped")
end

-- 最外层 pcall：补丁自身任何异常都只写日志，不冒泡到框架弹错、不中断启动。
-- 注意：Lua 语法错误无法被本 pcall 拦截，交付前已单独用 luac -p 校验。
local ok, err = pcall(apply)
if not ok then
    logger.warn("aat: patch skipped:", tostring(err))
end
