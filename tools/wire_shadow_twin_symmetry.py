# -*- coding: utf-8 -*-
"""把影子所有"符号级"AnimState 调用改成同时下发到可见层与写深度孪生体。

原因（2026-09-12 实测）：孪生体是"每像素只留最近一层"的关键，它必须与可见层
【几何完全一致】。此前只镜像了 bank/build/skin/动画/帧/镜像，符号显隐
（Show/Hide/HideSymbol/ShowSymbol）、符号覆盖（OverrideSymbol/OverrideSkinSymbol/
ClearOverrideSymbol）、override build 全都只落在可见层 —— 于是一戴帽/全盔
（可见层 Hide("face")/Hide("HAIR")、Hide("swap_body")），孪生体照样画着头发和脸，
在那些像素上写下更近的深度，把可见层整块拒掉：影子缺一大块（脸）+ 边缘狂闪。

替换规则（唯一入口 BothAS(sa, "方法名", ...)，定义见 bcas_sun_emitter.lua）：
    pcall(sa.METHOD, sa, ARGS)  ->  BothAS(sa, "METHOD", ARGS)
    sa:METHOD(ARGS)             ->  BothAS(sa, "METHOD", ARGS)

只动白名单里的方法；逐条计数打印；替换后残留的白名单调用会报出来并让脚本失败。
用法: python tools/wire_shadow_twin_symmetry.py
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PATH = os.path.join(ROOT, "BCAS-Studio", "scripts", "bcas_sun_emitter.lua")

# 只动这些"符号级"方法：它们决定【画哪些几何】。图层/深度/着色器/动画那些
# 两边本就不同（或另有 MirrorTwin 负责），不在这里动。
METHODS = [
    "Show", "Hide", "ShowSymbol", "HideSymbol",
    "OverrideSymbol", "OverrideSkinSymbol", "ClearOverrideSymbol",
    "AddOverrideBuild", "ClearOverrideBuild", "UseHeadHatExchange",
]
METHOD_SET = set(METHODS)
ALT = "|".join(METHODS)

RE_PCALL = re.compile(r"pcall\(sa\.(" + ALT + r"), sa, ")
RE_METHOD = re.compile(r"sa:(" + ALT + r")\(")


def split_args(text, open_idx):
    """从 text[open_idx] == '(' 开始，返回 (args_str, close_idx)。"""
    assert text[open_idx] == "("
    depth = 0
    i = open_idx
    while i < len(text):
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return text[open_idx + 1:i], i
        elif c == '"' or c == "'":
            q = c
            i += 1
            while i < len(text) and text[i] != q:
                if text[i] == "\\":
                    i += 1
                i += 1
        i += 1
    raise SystemExit("括号不配对：" + text)


def convert_line(line):
    """返回 (新行, {方法: 次数})。只处理单行调用。"""
    counts = {}
    out = ""
    pos = 0
    while True:
        m1 = RE_PCALL.search(line, pos)
        m2 = RE_METHOD.search(line, pos)
        m = None
        if m1 and m2:
            m = m1 if m1.start() <= m2.start() else m2
        else:
            m = m1 or m2
        if m is None:
            out += line[pos:]
            return out, counts
        method = m.group(1)
        if m is m1:
            # pcall(sa.METHOD, sa, ARGS) 整段就是 pcall 的实参表
            open_idx = m.start() + len("pcall")
            args, close = split_args(line, open_idx)
            # args = "sa.METHOD, sa, ARGS" -> 去掉前两项
            parts = args.split(",", 2)
            if len(parts) < 3 or not parts[1].strip() == "sa":
                raise SystemExit("pcall 形式参数异常：" + line)
            args = parts[2].lstrip()
        else:
            open_idx = m.end() - 1
            args, close = split_args(line, open_idx)
        out += line[pos:m.start()] + 'BothAS(sa, "%s"%s)' % (
            method, (", " + args) if args else "")
        counts[method] = counts.get(method, 0) + 1
        pos = close + 1


def main():
    with open(PATH, encoding="utf-8") as f:
        src = f.read()
    lines = src.split("\n")
    total = {}
    changed = 0
    for i, line in enumerate(lines):
        new, counts = convert_line(line)
        if new != line:
            if "--" in line:
                raise SystemExit("拒绝改动带注释的行（需人工确认）第 %d 行：%s" % (i + 1, line))
            lines[i] = new
            changed += 1
            for k, v in counts.items():
                total[k] = total.get(k, 0) + v
    out = "\n".join(lines)
    # 残留检查：白名单方法不应再有直接的 sa 调用
    leftovers = []
    for i, line in enumerate(lines, 1):
        if "BothAS(sa," in line:
            continue
        if RE_PCALL.search(line) or RE_METHOD.search(line):
            leftovers.append("%d: %s" % (i, line.strip()))
    with open(PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write(out)
    print("改了 %d 行；按方法统计：" % changed)
    for k in METHODS:
        if total.get(k):
            print("   %-20s x%d" % (k, total[k]))
    print("合计 %d 处" % sum(total.values()))
    if leftovers:
        print("!! 仍有未改的白名单调用：")
        for l in leftovers:
            print("   " + l)
        return 1
    print("残留检查：0 处")
    return 0


if __name__ == "__main__":
    sys.exit(main())
