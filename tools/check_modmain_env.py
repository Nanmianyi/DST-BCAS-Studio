# -*- coding: utf-8 -*-
"""检查 modmain 里"裸用"了 mod 沙箱环境里不存在的 Lua 基础函数。

为什么需要这个检查器（2026-09-15 实测事故）：
modmain 由 `ModWrangler:CreateEnvironment`（scripts/mods.lua:297）用**白名单**建环境，
白名单里只有：
    pairs ipairs print math table type string tostring require Class
    TUNING LEVELCATEGORY GROUND WORLD_TILES LOCKS KEYS LEVELTYPE
    GLOBAL modname MODROOT env modimport modassert moderror
以及 InsertPostInitFunctions 补进来的那些 mod API（Asset / AddPrefabPostInit /
AddModShadersInit / GetModConfigData ...）。

**没有 pcall / xpcall / rawset / getmetatable / error / assert / tonumber / next / select /
unpack / os / io / debug**。裸用它们的后果不是抛错可救，而是
    MOD ERROR: ... attempt to call global 'pcall' (a nil value)
→ 整个 mod 加载失败 → 客户端在进世界重载 mod 时直接 DoLuaFile Error，连接被断开
（用户看到的就是"游戏炸了"）。

注意环境差异：`require` 进来的 scripts/*.lua 跑在**游戏环境**里，pcall 之类的都在，
所以只有 modmain.lua（以及 modimport 的文件）需要这条检查。

用法: python tools/check_modmain_env.py [file ...]
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEFAULT = [os.path.join(ROOT, "BCAS-Studio", "modmain.lua")]

# mod 沙箱里【不存在】的 Lua 基础名字，以及建议的替代写法
DENIED = {
    "pcall": "GLOBAL.pcall",
    "xpcall": "GLOBAL.xpcall",
    "rawget": "GLOBAL.rawget",
    "rawset": "GLOBAL.rawset",
    "setmetatable": "GLOBAL.setmetatable",
    "getmetatable": "GLOBAL.getmetatable",
    "error": "moderror（或 GLOBAL.error）",
    "assert": "modassert（或 GLOBAL.assert）",
    "tonumber": "GLOBAL.tonumber",
    "next": "GLOBAL.next",
    "select": "GLOBAL.select",
    "unpack": "GLOBAL.unpack",
    "load": "GLOBAL.load",
    "loadstring": "GLOBAL.loadstring",
    "loadfile": "GLOBAL.loadfile",
    "dofile": "GLOBAL.dofile",
    "collectgarbage": "GLOBAL.collectgarbage",
    "coroutine": "GLOBAL.coroutine",
    "os": "GLOBAL.os",
    "io": "GLOBAL.io",
    "debug": "GLOBAL.debug",
    "module": "GLOBAL.module",
    "newproxy": "GLOBAL.newproxy",
    "gcinfo": "GLOBAL.gcinfo",
}

# 我们自己已经取过真身的名字（文件顶部 `local x = GLOBAL.x` / `local x = <允许的名字>`）：
# 这些名字在文件里合法，不再报。
ASSIGN = re.compile(r"^\s*local\s+([A-Za-z_][A-Za-z0-9_]*)\s*=", re.M)


def strip_noise(src):
    """去掉长注释/行注释/字符串，避免在注释和字符串里误报。"""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("--[[", i) or src.startswith("--[==[", i):
            j = src.find("]]", i + 3)
            j = n if j < 0 else j + 2
            out.append("\n" * src.count("\n", i, j))
            i = j
        elif src.startswith("--", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif c in "\"'":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append(c + " " * max(0, j - i - 1) + c)
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def check(path):
    src = strip_noise(io.open(path, encoding="utf-8").read())
    declared = set(ASSIGN.findall(src))
    bad = []
    for name, fix in sorted(DENIED.items()):
        if name in declared:
            continue
        # 裸用：前面不是 `.`（排除 GLOBAL.pcall）也不是声明/字段访问
        for m in re.finditer(r"(?<![\w.])" + name + r"\s*[({\[]", src):
            line = src.count("\n", 0, m.start()) + 1
            bad.append((line, name, fix))
    return sorted(bad)


def main():
    files = sys.argv[1:] or DEFAULT
    total = 0
    for f in files:
        if not os.path.exists(f):
            print("missing", f)
            continue
        bad = check(f)
        total += len(bad)
        print("%-42s 问题 %d" % (os.path.relpath(f, ROOT), len(bad)))
        for line, name, fix in bad:
            print("   %5d 行  裸用 `%s`  → 改用 %s" % (line, name, fix))
    print("检查 %d 个文件，问题 %d 个" % (len(files), total))
    return 1 if total else 0


if __name__ == "__main__":
    raise SystemExit(main())
