import numpy as np
from PIL import Image
import math
f32 = np.float32

def fract(x): return x - np.floor(x)

def hash21(px, pz):
    a = fract(f32(px)*f32(0.1031)); b = fract(f32(pz)*f32(0.1031)); c = a
    d = a*(b+f32(33.33)) + b*(c+f32(33.33)) + c*(a+f32(33.33))
    return fract(((a+d)+(b+d))* (c+d))

def vnoise(px, pz):
    ix=np.floor(px); iz=np.floor(pz); fx=px-ix; fz=pz-iz
    ux=fx*fx*(f32(3)-f32(2)*fx); uz=fz*fz*(f32(3)-f32(2)*fz)
    a=hash21(ix,iz); b=hash21(ix+f32(1),iz); c=hash21(ix,iz+f32(1)); d=hash21(ix+f32(1),iz+f32(1))
    ab=a+(b-a)*ux; cd=c+(d-c)*ux
    return ab+(cd-ab)*uz

def fbm(px,pz,oct=4):
    amp=f32(0.5); f=f32(1.0); s=np.zeros_like(px)
    for i in range(oct):
        # rotate each octave to break the grid
        ang=f32(i*1.7)
        rx = px*np.cos(ang)-pz*np.sin(ang)
        rz = px*np.sin(ang)+pz*np.cos(ang)
        s = s + vnoise(rx*f, rz*f)*amp
        amp*=f32(0.5); f*=f32(2.03)
    return s

def fbm5(px,pz):
    return fbm(px,pz,5)

t=f32(3.0)
W=512; extent=12.0
xs=np.linspace(0.3,0.3+extent,W,dtype=np.float32)
zs=np.linspace(0.3,0.3+extent,W,dtype=np.float32)
X,Z=np.meshgrid(xs,zs)

def normals(hfun):
    e=f32(0.08)
    h0=hfun(X,Z); hx=hfun(X+e,Z); hz=hfun(X,Z+e)
    nx=-(hx-h0)/e; nz=-(hz-h0)/e
    ln=np.sqrt(nx*nx+nz*nz+1)
    return nx/ln, nz/ln, 1/ln

# Candidate A: sum of directional sines + fbm (noise adds irregularity)
def hA(px,pz):
    k1,k2,k3=f32(2.6),f32(3.7),f32(5.1)
    h = f32(0.55)*np.sin(px*k1*f32(0.86)+pz*k1*f32(0.51)+t*f32(1.1))
    h+= f32(0.40)*np.sin(px*k2*f32(-0.42)+pz*k2*f32(0.91)+t*f32(1.6))
    h+= f32(0.30)*np.sin(px*k3*f32(0.95)+pz*k3*f32(-0.31)+t*f32(2.2))
    h+= f32(0.55)*fbm(px*f32(0.9)+t*f32(0.4), pz*f32(0.9), 3)
    return h

# Candidate B: pure fbm 5 octaves
def hB(px,pz):
    return fbm(px*f32(1.2)+t*f32(0.4), pz*f32(1.2), 5)

# Candidate C: sines only, no noise
def hC(px,pz):
    k1,k2,k3=f32(2.6),f32(3.7),f32(5.1)
    h = f32(0.55)*np.sin(px*k1*f32(0.86)+pz*k1*f32(0.51)+t*f32(1.1))
    h+= f32(0.40)*np.sin(px*k2*f32(-0.42)+pz*k2*f32(0.91)+t*f32(1.6))
    h+= f32(0.30)*np.sin(px*k3*f32(0.95)+pz*k3*f32(-0.31)+t*f32(2.2))
    return h

def save(name,arr):
    a=np.clip(arr,0,1); Image.fromarray((a*255).astype(np.uint8)).save(name)

for nm,hf in [('A_sines_fbm',hA),('B_fbm5',hB),('C_sines',hC)]:
    nx,nz,ny=normals(hf)
    save(f'work/sim2_{nm}.png', np.stack([nx*2+0.5, ny*2, nz*2+0.5],-1))
    print(nm,'max tilt', float(np.degrees(np.arctan(np.sqrt(nx**2+nz**2).max()))))
print('done')
