# BCAS Studio - SVG 预览图/图标渲染（SVG 为唯一设计源，2026-09 起）
# 用 Edge 无头模式（Chromium 渲染器）把 素材/modicon.svg 光栅化为 PNG。
# 旧 tools/draw_icon.ps1（System.Drawing 手写镜像）已废弃：用户直接改 SVG，
# 镜像脚本必然漂移，一律走本脚本真渲染。
# 输出: %TEMP%/bcas_modicon_render.png (1024)，后续由 python 生成各尺寸产物。
param(
    [int]$Size = 1024
)
$ErrorActionPreference = 'Stop'
$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
if (-not (Test-Path $edge)) {
    $edge = 'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
}
if (-not (Test-Path $edge)) { throw '未找到 Edge/Chrome，无法渲染 SVG' }

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$svg = Join-Path $root '素材\modicon.svg'
if (-not (Test-Path $svg)) { throw ('SVG 源不存在: ' + $svg) }
$tmpPng = Join-Path $env:TEMP 'bcas_modicon_render.png'
$profile = Join-Path $env:TEMP 'bcas_edge_profile'

# 独立 user-data-dir：不影响用户正在开的 Edge 实例
& $edge --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 `
    --user-data-dir=$profile `
    --window-size="$Size,$Size" `
    --screenshot="$tmpPng" `
    ("file:///" + ($svg -replace '\\', '/'))

# Edge 退出后截图异步落盘，轮询等待最多 15 秒
$waited = 0
while (-not (Test-Path $tmpPng) -and $waited -lt 15) {
    Start-Sleep -Milliseconds 500
    $waited++
}
if (-not (Test-Path $tmpPng)) { throw 'Edge 渲染未产出 PNG' }
Write-Output ('rendered: ' + $tmpPng)
