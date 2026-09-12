import numpy as np
from PIL import Image
import math
f32=np.float32
def fract(x): return x-np.floor(x)
def hash21(px,pz):
    a=fract(f32(px)*f32(0.1031)); b=fract(f32(pz)*f32(0.1031)); c=a
    d=a*(b+f32(33.33))+b*(c+f32(33.33))+c*(a+f32(33.33))
    return fract(((a+d)+(b+d))*(c+d))
def vnoise(px,pz):
    ix=np.floor(px); iz=np.floor(pz); fx=px-ix; fz=pz-iz
    ux=fx*fx*(f32(3)-f32(2)*fx); uz=fz*fz*(f32(3)-f32(2)*fz)
    a=hash21(ix,iz); b=hash21(ix+f32(1),iz); c=hash21(ix,iz+f32(1)); d=hash21(ix+f32(1),iz+f32(1))
    ab=a+(b-a)*ux; cd=c+(d-c)*ux
    return ab+(cd-ab)*uz
def fbm(px,pz,oct,freq=1.0):
    amp=f32(0.5); f=f32(freq); s=np.zeros_like(px)
    for i in range(oct):
        ang=f32(i*2.1)
        rx=px*np.cos(ang)-pz*np.sin(ang); rz=px*np.sin(ang)+pz*np.cos(ang)
        s=s+vnoise(rx*f,rz*f)*amp; amp*=f32(0.5); f*=f32(2.17)
    return s
t=f32(3.0)
W=512; extent=10.0
xs=np.linspace(0.3,0.3+extent,W,dtype=np.float32); zs=np.linspace(0.3,0.3+extent,W,dtype=np.float32)
X,Z=np.meshgrid(xs,zs)
def normals(hf,e=0.06):
    h0=hf(X,Z); hx=hf(X+e,Z); hz=hf(X,Z+e)
    nx=-(hx-h0)/e; nz=-(hz-h0)/e; ln=np.sqrt(nx*nx+nz*nz+1)
    return nx/ln,nz/ln,1/ln
def save(n,a): Image.fromarray((np.clip(a,0,1)*255).astype(np.uint8)).save(n)

def hD(px,pz):
    # domain warp
    wx = vnoise(px*f32(0.35)+t*f32(0.12), pz*f32(0.35))*f32(2.2)-f32(1.1)
    wz = vnoise(px*f32(0.35)+f32(7.3), pz*f32(0.35)+t*f32(0.10))*f32(2.2)-f32(1.1)
    ax = px*f32(2.3); az = pz*f32(1.0)
    rip = fbm(ax+wx+t*f32(0.5), az+wz, 2, 1.0)
    sw  = vnoise(px*f32(0.35)+t*f32(0.12), pz*f32(0.45))
    return rip*f32(0.55)+sw*f32(0.5)

def hE(px,pz):
    # anisotropic stretched ripples, 2 octaves, warp
    wx = vnoise(px*f32(0.3)+t*f32(0.1), pz*f32(0.3))*f32(2.0)-f32(1.0)
    wz = vnoise(px*f32(0.3)+f32(5.1), pz*f32(0.3))*f32(2.0)-f32(1.0)
    rip = vnoise(px*f32(3.1)+wx+t*f32(0.7), pz*f32(1.1)+wz)*f32(0.7)
    rip+= vnoise(px*f32(6.3)-wx-t*f32(0.9), pz*f32(2.2)+wz)*f32(0.35)
    return rip

def hF(px,pz):
    # warped, 3 octave, moderate stretch
    wx = vnoise(px*f32(0.3)+t*f32(0.1), pz*f32(0.3))*f32(2.4)-f32(1.2)
    wz = vnoise(px*f32(0.3)+f32(5.1), pz*f32(0.3))*f32(2.4)-f32(1.2)
    return vnoise(px*f32(2.0)+wx+t*f32(0.6), pz*f32(1.2)+wz)*f32(0.8) \
         + vnoise(px*f32(4.0)+wx*1.5-t*f32(0.8), pz*f32(2.4)+wz)*f32(0.4)

for nm,hf in [('D_warp',hD),('E_aniso2',hE),('F_warp3',hF)]:
    nx,nz,ny=normals(hf)
    save(f'work/sim3_{nm}.png', np.stack([nx*2+0.5,ny*2,nz*2+0.5],-1))
    print(nm,'tilt',round(float(np.degrees(np.arctan(np.sqrt(nx**2+nz**2).max()))),1))
print('done')
