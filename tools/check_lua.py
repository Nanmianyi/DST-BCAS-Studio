"""Lua 语法检查：解析 BCAS-Studio 下所有 .lua，报告失败文件与行号。

用法: python tools/check_lua.py [文件或目录...]
默认检查 BCAS-Studio/。

两项检查：
  1) 短字符串字面量里有没有裸换行 —— 游戏里的 Lua 5.1 会直接报
     "unfinished string"，而 luaparser 对这种写法是宽松的（能过）。
     踩过一次：modinfo 的 hover 文案被写成两行，整只 mod 加载失败
     （客户端日志：Error loading mod: BCAS-Studio! ... unfinished string）。
  2) luaparser 的完整语法解析。
"""
import re
import sys
import pathlib

from luaparser import ast

NL = chr(10)
QUOTES = ("'", '"')


def scan_raw_newline_in_string(text: str) -> str | None:
    """找"短字符串字面量里夹了裸换行"（Lua 会报 unfinished string）。

    字符串必须写在一行里，或者用 \\n 转义、[[]] 长字符串。这里手写扫描：
    跳过注释与长字符串，跟踪双/单引号的开合，一旦短字符串跨行就报行号。
    """
    i, n = 0, len(text)
    line = 1
    while i < n:
        c = text[i]
        if c == NL:
            line += 1
            i += 1
            continue
        # 注释（含 --[[ ]] 块注释）
        if text.startswith("--", i):
            m = re.match(r"--\[(=*)\[", text[i:])
            if m:
                close = "]" + m.group(1) + "]"
                j = text.find(close, i + len(m.group(0)))
                j = n if j < 0 else j + len(close)
            else:
                j = text.find(NL, i)
                j = n if j < 0 else j
            line += text.count(NL, i, j)
            i = j
            continue
        # 长字符串 [[ ]] / [=[ ]=]
        m = re.match(r"\[(=*)\[", text[i:])
        if m:
            close = "]" + m.group(1) + "]"
            j = text.find(close, i + len(m.group(0)))
            j = n if j < 0 else j + len(close)
            line += text.count(NL, i, j)
            i = j
            continue
        # 短字符串
        if c in QUOTES:
            q = c
            start_line = line
            i += 1
            while i < n:
                ch = text[i]
                if ch == "\\":
                    i += 2
                    continue
                if ch == q:
                    i += 1
                    break
                if ch == NL:
                    return ("第 %d 行的字符串没有闭合（字符串里出现裸换行），"
                            "游戏里的 Lua 会报 unfinished string" % start_line)
                i += 1
            else:
                return ("第 %d 行的字符串没有闭合（直到文件结尾），"
                        "游戏里的 Lua 会报 unfinished string" % start_line)
            continue
        i += 1
    return None


def check(path: pathlib.Path) -> str | None:
    try:
        src = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        src = path.read_text(encoding="gbk", errors="replace")
    bad = scan_raw_newline_in_string(src)
    if bad:
        return bad
    try:
        ast.parse(src)
        return None
    except Exception as exc:  # luaparser 抛 SyntaxException 等
        return f"{type(exc).__name__}: {exc}"


def main() -> int:
    targets = sys.argv[1:] or ["BCAS-Studio"]
    files: list[pathlib.Path] = []
    for t in targets:
        p = pathlib.Path(t)
        if p.is_dir():
            files.extend(sorted(p.rglob("*.lua")))
        elif p.is_file():
            files.append(p)

    bad = 0
    for f in files:
        err = check(f)
        if err:
            bad += 1
            print(f"[FAIL] {f}")
            print(f"       {err}")
    print(f"\n检查 {len(files)} 个文件，失败 {bad} 个")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
