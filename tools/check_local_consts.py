# -*- coding: utf-8 -*-
"""
静态检查：本模组自己的全大写常量（SHADOW_*/SYMBOL_*/OCEAN_*/GLINT_*/CLONE_* 等
以本地 `local` 声明的那些）有没有"用了但没声明"或"声明在使用之后"的。

为什么需要：游戏开了 strict.lua（data/scripts/strict.lua），读一个没声明的
全局变量会直接 error("variable 'X' is not declared")，而这条 error 会从
bcas_sun_emitter.lua 抛到 player_common.lua 的 ActivateHUD 里 —— 玩家一出生
就炸整条生成链，看起来就像"游戏炸了"。

这个坑已经踩过两次（CUT、SHADOW_MODE_VISIBLE）：都是块替换时把 `local X = ...`
那一行一起吃掉了。所以放一个构建期检查在这儿。

判定规则：
  * 去掉注释和字符串后，找出**裸用**的全大写标识符（前面不是 . : _ 字母数字）。
  * 该名字如果在本文件里出现过 `local NAME` 声明，但首次裸用早于声明行 -> 报错。
  * 该名字如果在本文件里从没声明过，但**文件里存在同前缀的其它已声明常量**
    （例如本文件声明了 SHADOW_MODE_WRITE，却裸用没声明的 SHADOW_MODE_VISIBLE）
    -> 报错。前缀取自已声明常量名去尾段（SHADOW_MODE_WRITE -> SHADOW_MODE_）。
    GLOBAL.X / _G.X / t.X 这种带点的访问不算裸用，不受影响。

用法: python tools/check_local_consts.py            # 检查模组全部 lua
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
TARGETS = [
    os.path.join(ROOT, "BCAS-Studio", "modmain.lua"),
] + [
    os.path.join(ROOT, "BCAS-Studio", "scripts", f)
    for f in sorted(os.listdir(os.path.join(ROOT, "BCAS-Studio", "scripts")))
    if f.endswith(".lua")
]

IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
CAPS = re.compile(r"^[A-Z][A-Z0-9_]*$")


def strip_code(text):
    """把注释与字符串换成等长空格，行号保持不变。"""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "-" and text.startswith("--", i):
            if text.startswith("--[[", i) or text.startswith("--[=", i):
                m = re.match(r"--\[(=*)\[", text[i:])
                close = "]" + m.group(1) + "]"
                j = text.find(close, i + len(m.group(0)))
                j = n if j < 0 else j + len(close)
                out.append(re.sub(r"[^\n]", " ", text[i:j]))
                i = j
            else:
                j = text.find("\n", i)
                j = n if j < 0 else j
                out.append(" " * (j - i))
                i = j
        elif c in "\"'":
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == c or text[j] == "\n":
                    break
                j += 1
            j = min(j + 1, n)
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        elif c == "[" and re.match(r"\[(=*)\[", text[i:]):
            m = re.match(r"\[(=*)\[", text[i:])
            close = "]" + m.group(1) + "]"
            j = text.find(close, i + len(m.group(0)))
            j = n if j < 0 else j + len(close)
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def declarations(code):
    """返回 {名字: 首次声明行}（行号从 1 开始）。"""
    decl = {}
    for ln, line in enumerate(code.split("\n"), 1):
        for m in re.finditer(r"\blocal\s+(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)", line):
            decl.setdefault(m.group(1), ln)
        # 多名字声明：local a, b, c  /  local a, b = f()
        m = re.match(r"\s*local\s+([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)+)", line)
        if m:
            for nm in m.group(1).split(","):
                decl.setdefault(nm.strip(), ln)
        # 循环变量：for i = 1, n  /  for k, v in pairs(t)
        m = re.search(r"\bfor\s+([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*(?:=|\bin\b)", line)
        if m:
            for nm in m.group(1).split(","):
                decl.setdefault(nm.strip(), ln)
    return decl


def prefix_of(name):
    """SHADOW_MODE_WRITE -> SHADOW_MODE_  （取到最后一个下划线）。"""
    return name[: name.rfind("_") + 1] if "_" in name else ""


def bare_uses(code):
    """返回 [(行号, 名字, 列)]，只看裸用（前面不是 . : 字母数字下划线）。

    表构造里的 key（行首 `NAME = ...`）不算裸用：那是 C.GRID_DOT 这类字段的
    定义，访问时带点，strict.lua 不会管。
    """
    uses = []
    for ln, line in enumerate(code.split("\n"), 1):
        for m in re.finditer(r"(?<![.:\w])([A-Za-z_][A-Za-z0-9_]*)", line):
            name = m.group(1)
            if not (CAPS.match(name) and len(name) >= 4):
                continue
            if not line[: m.start(1)].strip() and re.match(
                re.escape(name) + r"\s*=", line[m.start(1):]
            ):
                continue  # 行首（允许缩进）的 key 定义，例如表构造里的 GRID_DOT = {...}
            uses.append((ln, name, m.start(1)))
    return uses


def main():
    problems = 0
    for path in TARGETS:
        with open(path, encoding="utf-8") as f:
            raw = f.read()
        code = strip_code(raw)
        decl = declarations(code)
        declared_prefixes = {prefix_of(n) for n in decl if CAPS.match(n) and "_" in n}
        seen = set()
        for ln, name, col in bare_uses(code):
            if name in decl:
                if ln < decl[name] and (path, name) not in seen:
                    seen.add((path, name))
                    print("%s:%d: '%s' 在声明(第%d行)之前就被使用"
                          % (os.path.relpath(path, ROOT), ln, name, decl[name]))
                    problems += 1
            elif prefix_of(name) in declared_prefixes and (path, name) not in seen:
                seen.add((path, name))
                print("%s:%d: '%s' 裸用但整个文件没有声明（同前缀常量是本文件本地声明的，"
                      "这个八成也是被块替换吃掉了）"
                      % (os.path.relpath(path, ROOT), ln, name))
                problems += 1
    print("裸用未声明/声明过晚的常量: %d 个" % problems)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
