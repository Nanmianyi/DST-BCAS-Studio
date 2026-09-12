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
    wx = vnoise(qx*f32(0.30)+f32(1.3)+t*f32(0.10), qz*f32(0.30)+f32(5.1))
    wz = vnoise(qx*f32(0.30)+f32(7.7), qz*f32(0.30)+f32(2.9)-t*f32(0.08))
    wxm = (wx-f32(0.5))*f32(2.6); wzm=(wz-f32(0.5))*f32(2.6)
    r1 = vnoise(qx*f32(2.6)+wxm+f32(0.9)*t*f32(0.6), qz*f32(1.2)+wzm+f32(0.5)*t*f32(0.6))
    r2 = vnoise(qx*f32(4.9)-wxm*f32(1.4)-f32(0.5)*t*f32(0.9), qz*f32(2.3)+wzm*f32(1.4)+f32(0.9)*t*f32(0.9))
    sw = vnoise(qx*f32(0.33)+wxm*f32(0.4)+f32(0.6)*t*f32(0.15), qz*f32(0.33)+wzm*f32(0.4)+f32(0.4)*t*f32(0.15))
    amp = f32(0.35)+f32(0.65)*g
    return r1*f32(0.16)*amp + r2*f32(0.09)*amp + sw*f32(0.30)

t=f32(5.0); g=f32(0.75)
tilt=0.0
def normals(px,pz,grain=1.0):
    global tilt
    qx=px*grain; qz=pz*grain
    e=f32(0.16)
    h0=wave(qx,qz,t,g); hx=wave(qx+e,qz,t,g); hz=wave(qx,qz+e,t,g)
    nx=-(hx-h0)/e*grain; nz=-(hz-h0)/e*grain
    ln=np.sqrt(nx*nx+nz*nz+1)
    return nx/ln,nz/ln,1/ln

W=768; extent=22.0
xs=np.linspace(0.3,0.3+extent,W,dtype=np.float32); zs=np.linspace(0.3,0.3+extent,W,dtype=np.float32)
X,Z=np.meshgrid(xs,zs)
nx,nz,ny=normals(X,Z)
print('tilt max', round(float(np.degrees(np.arctan(np.sqrt(nx**2+nz**2).max()))),1))
print('tilt mean', round(float(np.degrees(np.arctan(np.sqrt(nx**2+nz**2).mean()))),1))
Image.fromarray((np.clip(np.stack([nx*2+0.5,ny*2,nz*2+0.5],-1),0,1)*255).astype(np.uint8)).save('work/sim4_normal.png')

# fake sun + view, glitter
sy=f32(0.72); sh=math.sqrt(1-0.72*0.72)
L=np.array([0.62,0.72,0.31],dtype=np.float32); L/=np.linalg.norm(L)
# view: camera above, looking toward +z-ish (toward sun side)
Vh=np.array([0.0,0.65,-0.76],dtype=np.float32); Vh/=np.linalg.norm(Vh)
H=L+Vh; H/=np.linalg.norm(H)
ndh=np.clip(nx*H[0]+ny*H[1]+nz*H[2],0,1)
shin=8.0*(40.0**((0.93-0.80)/0.198))
spec=np.clip(np.power(ndh,shin,dtype=np.float32)*10.0,0,1)
ndv=np.clip(nx*Vh[0]+ny*Vh[1]+nz*Vh[2],0,1)
Fs=f32(0.08)+f32(0.92)*np.power(1-ndv,5,dtype=np.float32)
glit=np.clip(spec*Fs,0,1)*f32(0.2+0.8*0.75)
# distance fade like shader
dist=np.sqrt(X**2+Z**2)
det=1.0/(1.0+dist*0.12)
# (approx: fade already in normals? no) just show
Image.fromarray((np.clip(glit,0,1)*255).astype(np.uint8)).save('work/sim4_spec.png')
print('glitter>0.3 frac', round(float((glit>0.3).mean()),4))
print('done')
