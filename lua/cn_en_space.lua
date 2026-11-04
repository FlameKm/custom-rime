-- 中英混输自动空格（盘古之白）
--
-- 覆盖三条上屏路径：
--   1. 回车把输入码原样上屏：前一个上屏字符是汉字时补前导空格
--   2. 英文/数字上屏后开始新的输入：补一个空格，正好落在下一个词前面
--   3. 汉字后直接选英文候选（空格键；候选只有一页时的数字键）：上屏前补前导空格
--
-- 只消费 commit 流，不改候选文本，因此不会把带空格的词学进用户词典。
-- 边界：Rime 读不到光标前的真实字符，前文靠本会话的 commit 记录推断。
-- 刚启动、刚切换窗口时前一个字符未知，此时不加前导空格（宁缺勿滥）。

local M = {}

local RESULT_ACCEPTED = 1
local RESULT_NOOP = 2

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

-- 末尾空白不参与判断：'Apple ' 的可见末字符仍是 'e'
local function get_last_visible_codepoint(text)
  local last = nil
  for _, codepoint in utf8.codes(text) do
    if not is_blank(codepoint) then
      last = codepoint
    end
  end
  return last
end

local function starts_with_ascii(text)
  if text == nil or text == "" then
    return false
  end
  return is_ascii_alnum(utf8.codepoint(text, 1))
end

local function is_letter_key(key)
  local repr = key:repr()
  return #repr == 1 and repr:match("%a") ~= nil
end

-- 每次上屏后同步推断：末尾是 ASCII 字母数字，说明下一词前需要空格
local function track_commit(env, text)
  if text == nil or text == "" then
    return
  end
  local last = get_last_visible_codepoint(text)
  if last == nil then
    -- 纯空白上屏，说明上一个英文已经收尾，别再补
    env.is_space_needed = false
    return
  end
  env.last_char = last
  env.is_space_needed = is_ascii_alnum(last)
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
local function pad_before_ascii_candidate(ctx, env, repr)
  if not is_cjk(env.last_char) then
    return
  end
  local candidate = get_commit_candidate(ctx, env, repr)
  if candidate == nil or not starts_with_ascii(candidate.text) then
    return
  end
  emit_text(env, " ")
end

-- 回车把输入码原样上屏；只有这一刻才知道"英文要贴上来"，前导空格在这里补
local function emit_raw_input(ctx, env)
  if not ctx:is_composing() then
    -- 空输入的回车是换行，段落结束，别把空格带到下一段
    env.is_space_needed = false
    return RESULT_NOOP
  end
  local raw_input = ctx.input
  if raw_input == nil or raw_input == "" then
    return RESULT_NOOP
  end
  local needs_leading_space = env.is_space_needed or is_cjk(env.last_char)
  ctx:clear()
  emit_text(env, needs_leading_space and (" " .. raw_input) or raw_input)
  return RESULT_ACCEPTED
end

function M.init(env)
  env.last_char = nil
  env.is_space_needed = false
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

  if repr == "Escape" then
    env.is_space_needed = false
    return RESULT_NOOP
  end

  if ctx:has_menu() and (repr == "space" or repr:match("^%d$")) then
    pad_before_ascii_candidate(ctx, env, repr)
    return RESULT_NOOP
  end

  -- 英文上屏后用户接着打字，空格在这里落地，正好落在下一个词前面
  if env.is_space_needed and not ctx:is_composing() and is_letter_key(key) then
    emit_text(env, " ")
  end

  return RESULT_NOOP
end

return M
