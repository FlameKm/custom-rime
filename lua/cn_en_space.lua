-- 中英混输自动空格（盘古之白）
--
-- 规则只有一条：上屏瞬间，前一个字符和本次上屏的首字符分属"汉字"与
-- "ASCII 字母数字"两个阵营时补一个半角空格；同类相邻不补。
-- 判断全部推迟到上屏那一刻，所以英文接英文、中文接中文都不会多出空格。
--
-- 三个上屏点：
--   1. 回车把输入码原样上屏
--   2. 空格键选候选
--   3. 数字键直选候选（候选只有一页时）
--
-- 只消费 commit 流，不改候选文本，因此不会把带空格的词学进用户词典。
-- 边界：Rime 读不到光标前的真实字符，前文靠本会话的 commit 记录推断。
-- 刚启动、刚切换窗口时前一个字符未知，此时不加前导空格（宁缺勿滥）。

local M = {}

local RESULT_ACCEPTED = 1
local RESULT_NOOP = 2

-- 换行后光标落在新行行首，前文记录必须作废，否则空格会带到下一段开头
local LINE_BREAK = 0x0A

local function is_cjk(codepoint)
  if codepoint == nil then
    return false
  end
  return (codepoint >= 0x3400 and codepoint <= 0x4DBF) -- 扩展 A
      or (codepoint >= 0x4E00 and codepoint <= 0x9FFF) -- 基本区
      or (codepoint >= 0xF900 and codepoint <= 0xFAFF) -- 兼容汉字
      or (codepoint >= 0x20000 and codepoint <= 0x2FA1F) -- 扩展 B 至 F
end

local function is_ascii_alnum(codepoint)
  if codepoint == nil then
    return false
  end
  return (codepoint >= 0x30 and codepoint <= 0x39)
      or (codepoint >= 0x41 and codepoint <= 0x5A)
      or (codepoint >= 0x61 and codepoint <= 0x7A)
end

local function is_blank(codepoint)
  return codepoint == 0x20 or codepoint == 0x09
      or codepoint == 0x0A or codepoint == 0x0D
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

-- 汉字与 ASCII 字母数字相邻才配空格；汉字和标点、字母和标点之间不动
local function is_separator_needed(prev_codepoint, next_codepoint)
  if prev_codepoint == nil or next_codepoint == nil or is_blank(prev_codepoint) then
    return false
  end
  if is_cjk(prev_codepoint) == is_cjk(next_codepoint) then
    return false
  end
  return is_ascii_alnum(prev_codepoint) or is_ascii_alnum(next_codepoint)
end

local function track_commit(env, text)
  local last = text and get_last_codepoint(text)
  if last ~= nil then
    env.last_char = last
  end
end

local function emit_text(env, text)
  track_commit(env, text)
  env.engine:commit_text(text)
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
  if not is_separator_needed(env.last_char, get_first_codepoint(candidate.text)) then
    return
  end
  emit_text(env, " ")
end

-- 回车把输入码原样上屏，这是"英文要贴上来"唯一能确定的时刻
local function emit_raw_input(ctx, env)
  if not ctx:is_composing() then
    env.last_char = LINE_BREAK
    return RESULT_NOOP
  end
  local raw_input = ctx.input
  if raw_input == nil or raw_input == "" then
    return RESULT_NOOP
  end
  local prefix = is_separator_needed(env.last_char, get_first_codepoint(raw_input)) and " " or ""
  ctx:clear()
  emit_text(env, prefix .. raw_input)
  return RESULT_ACCEPTED
end

function M.init(env)
  env.last_char = nil
  env.commit_conn = env.engine.context.commit_notifier:connect(function(ctx, text)
    track_commit(env, text or ctx:get_commit_text())
  end)
end

function M.fini(env)
  if env.commit_conn then
    env.commit_conn:disconnect()
    env.commit_conn = nil
  end
end

function M.func(key, env)
  if key:release() then
    return RESULT_NOOP
  end

  local ctx = env.engine.context
  local repr = key:repr()

  if repr == "Return" then
    return emit_raw_input(ctx, env)
  end

  if ctx:has_menu() and (repr == "space" or repr:match("^%d$")) then
    pad_before_candidate(ctx, env, repr)
  end

  return RESULT_NOOP
end

return M
