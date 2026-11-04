-- 中英混输自动空格（盘古之白）
--
-- 规则只有一条：上屏瞬间，前一个字符和本次上屏的首字符，一个是汉字、
-- 另一个是 ASCII 英文字母，就补一个半角空格。
-- 数字、符号、标点、同类相邻，一律不动。
-- 判断全部推迟到上屏那一刻，所以英文接英文、中文接中文都不会多出空格。
--
-- 三个上屏点：
--   1. 回车把输入码原样上屏
--   2. 空格键选候选
--   3. 数字键直选候选（候选只有一页时）
--
-- 前文状态存在 context 的自定义 option 里，而不是处理器自己的 env。
-- env 跟着引擎走，跨窗口不重置；context 是 per-session 的，换窗口后
-- 状态自动回到"未知"，不会把上一个窗口的汉字带到新窗口里补空格。
--
-- 只消费 commit 流，不改候选文本，因此不会把带空格的词学进用户词典。
-- 边界：Rime 读不到光标前的真实字符，前文靠本会话的 commit 记录推断。
-- 同一窗口内换输入框不会重建 session，那种情况仍可能误判。

local M = {}

local RESULT_ACCEPTED = 1
local RESULT_NOOP = 2

local OPTION_PREV_CJK = "_cn_en_space_prev_cjk"
local OPTION_PREV_ALPHA = "_cn_en_space_prev_alpha"
local OPTION_BOUND = "_cn_en_space_bound"

-- 静默超过这个秒数，就当人换了地方（切窗口、切标签、离开去干别的）
local IDLE_RESET_SECONDS = 10

-- 没有输入时，这些键会被原样交给应用：空格插进去、退格删字符、方向键挪光标。
-- 它们会改变光标前的真实内容，而 Rime 看不到结果，记账必须作废。
local PASSTHROUGH_KEYS = {
  space = true,
  Tab = true,
  BackSpace = true,
  Delete = true,
  Left = true,
  Right = true,
  Up = true,
  Down = true,
  Home = true,
  End = true,
  Page_Up = true,
  Page_Down = true,
}

local function is_cjk(codepoint)
  if codepoint == nil then
    return false
  end
  return (codepoint >= 0x3400 and codepoint <= 0x4DBF) -- 扩展 A
      or (codepoint >= 0x4E00 and codepoint <= 0x9FFF) -- 基本区
      or (codepoint >= 0xF900 and codepoint <= 0xFAFF) -- 兼容汉字
      or (codepoint >= 0x20000 and codepoint <= 0x2FA1F) -- 扩展 B 至 F
end

local function is_ascii_alpha(codepoint)
  if codepoint == nil then
    return false
  end
  return (codepoint >= 0x41 and codepoint <= 0x5A)
      or (codepoint >= 0x61 and codepoint <= 0x7A)
end

-- 光标前一个字符。空白也要记：它意味着两边已经隔开，不必再补
local function get_last_codepoint(text)
  local last = nil
  for _, codepoint in utf8.codes(text) do
    last = codepoint
  end
  return last
end

local function get_first_codepoint(text)
  if text == nil or text == "" then
    return nil
  end
  return utf8.codepoint(text, 1)
end

-- 只有汉字与英文字母成对时才配空格；其间夹了数字或标点都不动
local function is_separator_needed(ctx, next_codepoint)
  if next_codepoint == nil then
    return false
  end
  if ctx:get_option(OPTION_PREV_CJK) then
    return is_ascii_alpha(next_codepoint)
  end
  if ctx:get_option(OPTION_PREV_ALPHA) then
    return is_cjk(next_codepoint)
  end
  -- 前一个字符未知、是空白，或是数字、标点：都不补
  return false
end

-- 上屏后立刻记账，供下一次上屏判断
local function remember(ctx, text)
  local last = text and get_last_codepoint(text)
  if last == nil then
    return
  end
  ctx:set_option(OPTION_PREV_CJK, is_cjk(last))
  ctx:set_option(OPTION_PREV_ALPHA, is_ascii_alpha(last))
end

-- 换行意味着新段落，前文作废，否则空格会跑到下一段开头
local function forget(ctx)
  ctx:set_option(OPTION_PREV_CJK, false)
  ctx:set_option(OPTION_PREV_ALPHA, false)
end

local function emit_text(ctx, env, text)
  remember(ctx, text)
  env.engine:commit_text(text)
end

-- 换 session 会换一个 context，靠 option 标记把监听补到新 context 上
local function bind_commit_tracking(ctx)
  if ctx:get_option(OPTION_BOUND) then
    return
  end
  ctx:set_option(OPTION_BOUND, true)
  ctx.commit_notifier:connect(function(inner_ctx, text)
    remember(inner_ctx, text or inner_ctx:get_commit_text())
  end)
end

local function get_commit_candidate(ctx, env, repr)
  if repr == "space" then
    return ctx:get_selected_candidate()
  end
  local menu = ctx.menu
  if menu == nil then
    return nil
  end
  local page_size = env.engine.schema.config:get_int("menu/page_size")
  -- 翻过页后数字键的下标要加页码偏移，Menu 没暴露页码，多页时放弃处理
  if page_size == nil or page_size <= 0 or menu:candidate_count() > page_size then
    return nil
  end
  local position = tonumber(repr)
  if position == 0 then
    position = 10
  end
  return menu:get_candidate_at(position - 1)
end

-- 汉字后面跟英文候选时，空格必须赶在候选上屏之前发出去
local function pad_before_candidate(ctx, env, repr)
  local candidate = get_commit_candidate(ctx, env, repr)
  if candidate == nil then
    return
  end
  if not is_separator_needed(ctx, get_first_codepoint(candidate.text)) then
    return
  end
  emit_text(ctx, env, " ")
end

-- 回车把输入码原样上屏，这是"英文要贴上来"唯一能确定的时刻
local function emit_raw_input(ctx, env)
  if not ctx:is_composing() then
    forget(ctx)
    return RESULT_NOOP
  end
  local raw_input = ctx.input
  if raw_input == nil or raw_input == "" then
    return RESULT_NOOP
  end
  local prefix = is_separator_needed(ctx, get_first_codepoint(raw_input)) and " " or ""
  ctx:clear()
  emit_text(ctx, env, prefix .. raw_input)
  return RESULT_ACCEPTED
end

function M.init(env)
  env.last_activity_at = nil
  bind_commit_tracking(env.engine.context)
end

function M.fini(env) end

function M.func(key, env)
  if key:release() then
    return RESULT_NOOP
  end

  local ctx = env.engine.context
  bind_commit_tracking(ctx)

  local now = os.time()
  -- 停了一段时间再动键，前文很可能已经换了，优先保证不多补空格
  if env.last_activity_at ~= nil and now - env.last_activity_at >= IDLE_RESET_SECONDS then
    forget(ctx)
  end
  env.last_activity_at = now

  local repr = key:repr()
  if repr == "Return" then
    return emit_raw_input(ctx, env)
  end

  if not ctx:is_composing() and PASSTHROUGH_KEYS[repr] then
    forget(ctx)
    return RESULT_NOOP
  end

  if ctx:has_menu() and (repr == "space" or repr:match("^%d$")) then
    pad_before_candidate(ctx, env, repr)
  end

  return RESULT_NOOP
end

return M
