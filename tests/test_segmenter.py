#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tts_cn 断句算法的 Python 参考实现 + 单元测试。
在沙箱没有 Lua 运行时时，先验证分段逻辑，再逐行翻译成 segmenter.lua。

规则（中文为主，英文作为纯英文书支持）：
  1. 保护 URL / 邮箱，避免其中的 . / ? 触发断句。
  2. 强句末：。！？!?  -> 断句（保留标点）。
  3. 软句末：；;      -> 断句（保留标点）。
  4. 句内停顿（不强制断）：……  —— ，、：: 及空格；仅当句长超 max_len 时
     才在上一个句内停顿处软断，避免一次性读过长。
  5. CJK 引号/括号配对：句末标点若落在未闭合的引号/括号内，暂不切，
     待配对闭合且上一字符是句末标点时再补断（避免拦腰截断引语）。
  6. 英文缩写/缩略语保护：Mr. Dr. e.g. i.e. etc. fig. 以及 U.S. J.K. 等
     首字母缩写后不误断。
  7. 小数保护：数字.数字 不误断。
  8. 仅把 CJK 引号当作引号配对；ASCII " ' 当作普通字符（避免 don't 误判）。
"""

import re

STRONG = set("。！？!?")
SOFT_TERMINAL = set("；;")
WEAK = set("，,、：:—… ")
# 仅 CJK 引号 + 括号参与配对；ASCII 引号不作为引号，避免破坏英文缩写/所有格
OPEN = {'“': '”', '‘': '’', '「': '」', '『': '』',
        '（': '）', '(': ')', '[': ']', '【': '】', '《': '》'}
CLOSE = set(OPEN.values())
ABBR = {'mr', 'mrs', 'ms', 'dr', 'prof', 'sr', 'jr', 'vs', 'etc',
        'e.g', 'i.e', 'no', 'st', 'co', 'inc', 'ltd', 'fig', 'al',
        'de', 'von', 'van', 'u.s', 'u.k', 'ph.d', 'eq'}


def _protect(text):
    placeholders = {}

    def _repl(m):
        key = "\x00%d\x00" % len(placeholders)
        placeholders[key] = m.group(0)
        return key

    text = re.sub(r'https?://[^\s\x00]+', _repl, text)
    text = re.sub(r'[\w.+-]+@[\w-]+\.[\w.-]+', _repl, text)
    return text, placeholders


def _last_word_raw(buf):
    s = ''
    i = len(buf) - 1
    while i >= 0:
        c = buf[i]
        if c.isalnum() or c in "'.":
            s = c + s
            i -= 1
        else:
            break
    return s


def _next_alpha_and_following(cps, idx):
    """返回 (句点后的首个字母, 该字母紧邻的下一字符)。用于判断 e.g. / U.S. 型缩写。"""
    j = idx + 1
    n = len(cps)
    while j < n and cps[j] == ' ':
        j += 1
    if j >= n or not cps[j].isalpha():
        return (None, None)
    nxt = cps[j]
    k = j + 1
    after = cps[k] if k < n else None
    return (nxt, after)


def split_sentences(text, max_len=80):
    text, placeholders = _protect(text)
    cps = list(text)
    n = len(cps)
    sentences = []
    buf = []
    quote_stack = []

    def finalize():
        s = ''.join(buf).strip()
        if s:
            sentences.append(s)
        del buf[:]

    for i in range(n):
        ch = cps[i]
        if ch in OPEN:
            quote_stack.append(OPEN[ch])
            buf.append(ch)
            continue
        if ch in CLOSE:
            if quote_stack and quote_stack[-1] == ch:
                quote_stack.pop()
            buf.append(ch)
            # 配对闭合且上一字符是句末标点 -> 补断
            if (not quote_stack) and len(buf) >= 2 and \
               (buf[-2] in STRONG or buf[-2] in SOFT_TERMINAL):
                finalize()
            continue

        is_term = False
        if ch in STRONG or ch in SOFT_TERMINAL or ch == '\n':
            is_term = True
        elif ch == '.':
            w = _last_word_raw(buf)
            wl = w.lower()
            if wl in ABBR:
                is_term = False
            elif len(w) == 1 and w.isalpha():
                nxt, after = _next_alpha_and_following(cps, i)
                if nxt is not None and (after == '.' or (nxt.isupper() and len(nxt) == 1)):
                    is_term = False
                else:
                    before = cps[i - 1] if i > 0 else ''
                    after_d = cps[i + 1] if i + 1 < n else ''
                    is_term = not (before.isdigit() and after_d.isdigit())
            else:
                before = cps[i - 1] if i > 0 else ''
                after_d = cps[i + 1] if i + 1 < n else ''
                is_term = not (before.isdigit() and after_d.isdigit())

        if is_term:
            buf.append(ch)
            if quote_stack:
                continue  # 引号/括号内，暂不切
            finalize()
            continue

        buf.append(ch)
        if ch in WEAK and len(buf) >= max_len:
            finalize()

    if buf:
        s = ''.join(buf).strip()
        if s:
            sentences.append(s)

    out = []
    for s in sentences:
        for k, v in placeholders.items():
            s = s.replace(k, v)
        out.append(s)
    return out


# ----------------------------- 测试 -----------------------------
def _check(name, text, expect_count=None, must_contain=None):
    res = split_sentences(text)
    ok = True
    msg = []
    if expect_count is not None and len(res) != expect_count:
        ok = False
        msg.append("期望 %d 句，实际 %d 句" % (expect_count, len(res)))
    if must_contain:
        for m in must_contain:
            if not any(m in s for s in res):
                ok = False
                msg.append("缺少应包含片段: %r" % m)
    print("[%s] %s" % ("PASS" if ok else "FAIL", name))
    for j, s in enumerate(res):
        print("    %d. %s" % (j + 1, s))
    for m in msg:
        print("    !! %s" % m)
    print()
    return ok


def main():
    all_ok = True

    all_ok &= _check(
        "中文基本断句",
        "她说：“今天天气真好。”他回答：“是啊，我们去散步吧！”然后他们出发了。",
        expect_count=3,
    )

    all_ok &= _check(
        "引号内句末不误断",
        "孔子曰：“学而时习之，不亦说乎？”这句话流传很广。",
        expect_count=2,
        must_contain=["学而时习之，不亦说乎？", "这句话流传很广。"],
    )

    all_ok &= _check(
        "省略号与破折号（句内停顿，不强制断）",
        "他犹豫了很久……最后还是点了头。事情就是这样——没什么好说的。",
        expect_count=2,
    )

    all_ok &= _check(
        "英文缩写/缩略语不误断",
        "Mr. Smith went to the U.S. with Dr. Lee. They read e.g. a book. See fig. 3 for details.",
        expect_count=3,
        must_contain=["Mr. Smith went to the U.S. with Dr. Lee.",
                      "They read e.g. a book.",
                      "See fig. 3 for details."],
    )

    all_ok &= _check(
        "小数不误断",
        "圆周率约等于3.14159。体温是36.5度。价格是12.99元。",
        expect_count=3,
    )

    all_ok &= _check(
        "URL 与邮箱保护（整句仅一处句末）",
        "详见 https://example.com/a/b?x=1&y=2 的说明，或发邮件给 a.b@example.com 咨询。",
        expect_count=1,
        must_contain=["https://example.com/a/b?x=1&y=2", "a.b@example.com"],
    )

    all_ok &= _check(
        "英文纯英文书（含引号句）",
        'It was the best of times. It was the worst of times! "Hello," she said. The end.',
        expect_count=4,
    )

    all_ok &= _check(
        "超长中文软断（逗号处）",
        "第一，我们要明确目标，第二，我们要制定计划，第三，我们要分配资源，"
        "第四，我们要执行任务，第五，我们要检查结果，第六，我们要持续改进，"
        "第七，我们要总结复盘，第八，我们要形成闭环，第九，我们要沉淀方法论，"
        "第十，我们要推广复制，这样体系才能运转。",
        expect_count=None,
        must_contain=["我们要明确目标，", "这样体系才能运转。"],
    )

    all_ok &= _check(
        "括号配对",
        "函数 f(x) 用于计算（注意：x 必须大于零）。结果保存在变量里。",
        expect_count=2,
        must_contain=["函数 f(x) 用于计算（注意：x 必须大于零）。", "结果保存在变量里。"],
    )

    all_ok &= _check(
        "英文所有格 don't 不误判引号",
        "Don't worry, it's fine. She said hello. We're ready.",
        expect_count=3,
    )

    print("=" * 40)
    print("ALL PASS" if all_ok else "SOME FAILED")
    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
