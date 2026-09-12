import numpy as np
from PIL import Image
import math

f32 = np.float32

def fract(x):
    return x - np.floor(x)

def bcas_hash(px, pz):
    # vec3 p3 = fract(vec3(p.xyx) * 0.1031);  p = (px,pz) -> a=fract(px*s), b=fract(pz*s), c=fract(px*s)
    a = fract(f32(px) * f32(0.1031))
    b = fract(f32(pz) * f32(0.1031))
    c = a
    d = a * (b + f32(33.33)) + b * (c + f32(33.33)) + c * (a + f32(33.33))
    a2 = a + d; b2 = b + d; c2 = c + d
    return fract((a2 + b2) * c2)

def bcas_noise(px, pz):
    ix = np.floor(px); iz = np.floor(pz)
    fx = px - ix; fz = pz - iz
    ux = fx * fx * (f32(3.0) - f32(2.0) * fx)
    uz = fz * fz * (f32(3.0) - f32(2.0) * fz)
    a = bcas_hash(ix, iz)
    b = bcas_hash(ix + f32(1.0), iz)
    c = bcas_hash(ix, iz + f32(1.0))
    d = bcas_hash(ix + f32(1.0), iz + f32(1.0))
    ab = a + (b - a) * ux
    cd = c + (d - c) * ux
    return ab + (cd - ab) * uz

def bcas_height(px, pz, t, gust):
    rip = bcas_noise(px * f32(1.70) + f32(0.86) * t * f32(0.55),
                     pz * f32(1.70) + f32(0.51) * t * f32(0.55))
    sw = bcas_noise(px * f32(0.20) + f32(-0.34) * t * f32(0.16),
                    pz * f32(0.20) + f32(0.94) * t * f32(0.16))
    return rip * f32(0.22) * (f32(0.30) + f32(0.70) * gust) + sw * f32(0.30)

t = f32(3.0)
gust = f32(0.8)
W = 512
# 12 world units across the image
extent = 12.0
xs = np.linspace(0.3, 0.3 + extent, W, dtype=np.float32)
zs = np.linspace(0.3, 0.3 + extent, W, dtype=np.float32)
X, Z = np.meshgrid(xs, zs)

h0 = bcas_height(X, Z, t, gust)
e = f32(0.25)
hx = bcas_height(X + e, Z, t, gust)
hz = bcas_height(X, Z + e, t, gust)
nx = -(hx - h0) / e
nz = -(hz - h0) / e
ln = np.sqrt(nx*nx + nz*nz + f32(1.0))
nx = nx/ln; nz = nz/ln

# fake view/sun
sy = f32(0.75); sh = math.sqrt(1-0.75*0.75)
sx, sz = f32(0.6), f32(0.2)
L = np.array([sx, sy, sz], dtype=np.float32); L/=np.linalg.norm(L)
# camera roughly above -z looking +z
Vh = np.array([0.0, 0.7, -0.7], dtype=np.float32)
H = L + Vh; H/=np.linalg.norm(H)
ndh = np.clip(nx*H[0] + (f32(1.0)/ln)*H[1] + nz*H[2], 0, 1)
shin = 8.0 * (40.0 ** ((0.93-0.80)/0.198))
spec = np.power(ndh, shin, dtype=np.float32)*10.0

def save(name, arr):
    a = np.clip(arr, 0, 1)
    Image.fromarray((a*255).astype(np.uint8)).save(name)

save('work/sim_height.png', h0*3.0)
save('work/sim_normal.png', np.stack([nx*2+0.5, (1/ln)*2, nz*2+0.5], -1))
save('work/sim_spec.png', np.clip(spec,0,1))
print('shininess', shin)
print('ndh max', float(ndh.max()), 'spec>0.3 count', int((spec>0.3).sum()))
print('normal tilt deg max', float(np.degrees(np.arctan(np.sqrt(nx**2+nz**2).max()))))
print('saved')
