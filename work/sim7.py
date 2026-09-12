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
def wave(qx,qz,t,g):
    wx=vnoise(qx*f32(0.30)+f32(1.3)+t*f32(0.10),qz*f32(0.30)+f32(5.1))
    wz=vnoise(qx*f32(0.30)+f32(7.7),qz*f32(0.30)+f32(2.9)-t*f32(0.08))
    wxm=(wx-f32(0.5))*f32(2.6); wzm=(wz-f32(0.5))*f32(2.6)
    r1=vnoise(qx*f32(3.0)+wxm+f32(0.9)*t*f32(0.6),qz*f32(1.4)+wzm+f32(0.5)*t*f32(0.6))
    sw=vnoise(qx*f32(0.33)+wxm*f32(0.4)+f32(0.6)*t*f32(0.15),qz*f32(0.33)+wzm*f32(0.4)+f32(0.4)*t*f32(0.15))
    amp=f32(0.35)+f32(0.65)*g
    return r1*f32(0.26)*amp*f32(1.9) + sw*f32(0.30)
t=f32(5.0); g=f32(0.75)
W=768; extent=22.0
xs=np.linspace(0.3,0.3+extent,W,dtype=np.float32); zs=np.linspace(0.3,0.3+extent,W,dtype=np.float32)
X,Z=np.meshgrid(xs,zs)
e=f32(0.14)
h0=wave(X,Z,t,g); hx=wave(X+e,Z,t,g); hz=wave(X,Z+e,t,g)
nx=-(hx-h0)/e; nz=-(hz-h0)/e; ln=np.sqrt(nx*nx+nz*nz+1)
nx/=ln; nz/=ln; ny=1/ln
print('tilt max',round(float(np.degrees(np.arctan(np.sqrt(nx**2+nz**2).max()))),1),'mean',round(float(np.degrees(np.arctan(np.sqrt(nx**2+nz**2).mean()))),1))
Image.fromarray((np.clip(np.stack([nx*2+0.5,ny*2,nz*2+0.5],-1),0,1)*255).astype(np.uint8)).save('work/sim7_normal.png')
D=math.radians
L=np.array([math.cos(D(45))*math.sin(D(20)),math.sin(D(45)),math.cos(D(45))*math.cos(D(20))],dtype=np.float32)
ndl=np.clip(nx*L[0]+ny*L[1]+nz*L[2],0,1)
for k in (8,11,15):
    gl=np.clip(np.power(ndl,k,dtype=np.float32)*2.0,0,1)
    print(f'k={k} frac>0.3={float((gl>0.3).mean()):.4f} mean={float(gl.mean()):.4f}')
    Image.fromarray((np.clip(gl,0,1)*255).astype(np.uint8)).save(f'work/sim7_g_{k}.png')
print('done')
