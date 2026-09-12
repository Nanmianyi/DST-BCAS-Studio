"""离线 GLSL 编译校验：用游戏自带的 ANGLE(libEGL/libGLESv2) 编译 .ksh 里的源码。

为什么需要：引擎按 ksh 条目表和 vs_refs/ps_refs 逐槽绑定 uniform，
"声明了但没被真正使用"的 uniform 会被编译器优化掉 → 引擎按表取 location
得到 0xFFFFFFFF → ANGLE 原生断言（ProgramBinary.cpp mSamplersPS[].active）
→ 游戏硬闪退（2026-09 实际踩过）。这个脚本在离线环境下完成
编译 + 链接 + 逐 uniform 查询 location，把这个问题挡在上机之前。

用法:
    python tools/glsl_check.py                 # 检查 BCAS-Studio/shaders/*.ksh
    python tools/glsl_check.py <某个.ksh>
"""
import ctypes
import glob
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ksh_parse

DST_BIN = r"J:/SteamLibrary/steamapps/common/Don't Starve Together/bin64"

# ---- EGL / GLES2 常量 ----
EGL_DEFAULT_DISPLAY = 0
EGL_NO_CONTEXT = 0
EGL_NO_SURFACE = 0
EGL_SURFACE_TYPE = 0x3033
EGL_PBUFFER_BIT = 0x0001
EGL_RENDERABLE_TYPE = 0x3040
EGL_OPENGL_ES2_BIT = 0x0004
EGL_RED_SIZE, EGL_GREEN_SIZE, EGL_BLUE_SIZE, EGL_ALPHA_SIZE = 0x3024, 0x3023, 0x3022, 0x3021
EGL_DEPTH_SIZE = 0x3025
EGL_WIDTH, EGL_HEIGHT = 0x3057, 0x3056
EGL_CONTEXT_CLIENT_VERSION = 0x3098
EGL_NONE = 0x3038
GL_VERTEX_SHADER, GL_FRAGMENT_SHADER = 0x8B31, 0x8B30
GL_COMPILE_STATUS, GL_LINK_STATUS = 0x8B81, 0x8B82
GL_INFO_LOG_LENGTH = 0x8B84
GL_ACTIVE_UNIFORMS = 0x8B86
GL_FALSE = 0


class Angle:
    def __init__(self):
        self.egl = ctypes.WinDLL(os.path.join(DST_BIN, 'libEGL.dll'))
        self.gl = ctypes.WinDLL(os.path.join(DST_BIN, 'libGLESv2.dll'))
        egl = self.egl
        egl.eglGetDisplay.restype = ctypes.c_void_p
        egl.eglGetDisplay.argtypes = [ctypes.c_void_p]
        egl.eglInitialize.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int),
                                      ctypes.POINTER(ctypes.c_int)]
        egl.eglChooseConfig.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int),
                                        ctypes.POINTER(ctypes.c_void_p), ctypes.c_int,
                                        ctypes.POINTER(ctypes.c_int)]
        egl.eglCreatePbufferSurface.restype = ctypes.c_void_p
        egl.eglCreatePbufferSurface.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                                ctypes.POINTER(ctypes.c_int)]
        egl.eglCreateContext.restype = ctypes.c_void_p
        egl.eglCreateContext.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                                         ctypes.POINTER(ctypes.c_int)]
        egl.eglMakeCurrent.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                                       ctypes.c_void_p]
        self.dpy = egl.eglGetDisplay(EGL_DEFAULT_DISPLAY)
        if not self.dpy:
            raise RuntimeError('eglGetDisplay 失败')
        maj, mnr = ctypes.c_int(), ctypes.c_int()
        if not egl.eglInitialize(self.dpy, ctypes.byref(maj), ctypes.byref(mnr)):
            raise RuntimeError('eglInitialize 失败（ANGLE 无法初始化 D3D11 后端）')
        cfg_attr = (ctypes.c_int * 13)(
            EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
            EGL_NONE)
        cfg = ctypes.c_void_p()
        n = ctypes.c_int()
        if not egl.eglChooseConfig(self.dpy, cfg_attr, ctypes.byref(cfg), 1, ctypes.byref(n)) or n.value < 1:
            raise RuntimeError('eglChooseConfig 失败')
        surf_attr = (ctypes.c_int * 5)(EGL_WIDTH, 4, EGL_HEIGHT, 4, EGL_NONE)
        self.surf = egl.eglCreatePbufferSurface(self.dpy, cfg, surf_attr)
        ctx_attr = (ctypes.c_int * 3)(EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE)
        self.ctx = egl.eglCreateContext(self.dpy, cfg, None, ctx_attr)
        if not egl.eglMakeCurrent(self.dpy, self.surf, self.surf, self.ctx):
            raise RuntimeError('eglMakeCurrent 失败')

    def _src(self, text):
        buf = ctypes.c_char_p(text.encode('ascii'))
        return buf

    def compile(self, kind, text):
        gl = self.gl
        gl.glCreateShader.restype = ctypes.c_uint
        gl.glCreateShader.argtypes = [ctypes.c_uint]
        sh = gl.glCreateShader(kind)
        src = ctypes.c_char_p(text.encode('ascii'))
        arr = (ctypes.c_char_p * 1)(src)
        gl.glShaderSource(ctypes.c_uint(sh), ctypes.c_int(1), arr, None)
        gl.glCompileShader(ctypes.c_uint(sh))
        ok = ctypes.c_int()
        gl.glGetShaderiv(ctypes.c_uint(sh), GL_COMPILE_STATUS, ctypes.byref(ok))
        log_len = ctypes.c_int()
        gl.glGetShaderiv(ctypes.c_uint(sh), GL_INFO_LOG_LENGTH, ctypes.byref(log_len))
        log = ''
        if log_len.value > 1:
            buf = ctypes.create_string_buffer(log_len.value)
            gl.glGetShaderInfoLog(ctypes.c_uint(sh), log_len, None, buf)
            log = buf.value.decode('latin1')
        return sh, bool(ok.value), log

    def link(self, vs_text, ps_text):
        gl = self.gl
        vs, ok1, log1 = self.compile(GL_VERTEX_SHADER, vs_text)
        ps, ok2, log2 = self.compile(GL_FRAGMENT_SHADER, ps_text)
        if not (ok1 and ok2):
            return None, f'VS:{"OK" if ok1 else log1}\nPS:{"OK" if ok2 else log2}'
        gl.glCreateProgram.restype = ctypes.c_uint
        prog = gl.glCreateProgram()
        gl.glAttachShader(ctypes.c_uint(prog), ctypes.c_uint(vs))
        gl.glAttachShader(ctypes.c_uint(prog), ctypes.c_uint(ps))
        gl.glLinkProgram(ctypes.c_uint(prog))
        ok = ctypes.c_int()
        gl.glGetProgramiv(ctypes.c_uint(prog), GL_LINK_STATUS, ctypes.byref(ok))
        log = ''
        if not ok.value:
            log_len = ctypes.c_int()
            gl.glGetProgramiv(ctypes.c_uint(prog), GL_INFO_LOG_LENGTH, ctypes.byref(log_len))
            if log_len.value > 1:
                buf = ctypes.create_string_buffer(log_len.value)
                gl.glGetProgramInfoLog(ctypes.c_uint(prog), log_len, None, buf)
                log = buf.value.decode('latin1')
            return None, 'link failed: ' + log
        return prog, ''

    def location(self, prog, name):
        gl = self.gl
        gl.glGetUniformLocation.restype = ctypes.c_int
        gl.glGetUniformLocation.argtypes = [ctypes.c_uint, ctypes.c_char_p]
        return gl.glGetUniformLocation(ctypes.c_uint(prog), name.encode('ascii'))


def check(path, angle, verbose=True):
    r = ksh_parse.parse(path)
    vs = r['vs_src'].rstrip(b'\x00').decode('ascii', 'replace')
    ps = r['ps_src'].rstrip(b'\x00').decode('ascii', 'replace')
    prog, err = angle.link(vs, ps)
    name = os.path.basename(path)
    if prog is None:
        print(f'[编译失败] {name}\n{err}')
        return False
    ok = True
    bad = []
    for e in r['entries']:
        loc = angle.location(prog, e['name'])
        slots = {e['name']: loc}
        # 数组采样器：查 SAMPLER[0]
        if e['type'] == ksh_parse.TYPE_SAMPLER2D:
            loc = angle.location(prog, e['name'] + '[0]')
        if loc < 0:
            bad.append(e['name'])
            ok = False
    if verbose:
        if ok:
            print(f'[OK] {name}: 编译链接通过，{r["entry_count"]} 个条目全部有活动 location')
        else:
            print(f'[危险] {name}: 以下 uniform 被编译器优化掉（引擎按表绑定会触发 ANGLE 断言闪退）: '
                  + ', '.join(bad))
    return ok


def main():
    args = [a for a in sys.argv[1:]]
    files = args or sorted(glob.glob('BCAS-Studio/shaders/*.ksh'))
    try:
        angle = Angle()
    except Exception as exc:
        print(f'[跳过] ANGLE 初始化失败（{exc}）—— 本机离线编译校验不可用')
        return 0
    bad = 0
    for f in files:
        try:
            if not check(f, angle):
                bad += 1
        except Exception as exc:
            print(f'[错误] {f}: {exc}')
            bad += 1
    print(f'\n检查 {len(files)} 个 ksh，问题 {bad} 个')
    return 1 if bad else 0


if __name__ == '__main__':
    raise SystemExit(main())
