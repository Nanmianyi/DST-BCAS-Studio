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
AMP=1.6
def wave(qx,qz,t,g):
    wx=vnoise(qx*f32(0.30)+f32(1.3)+t*f32(0.10),qz*f32(0.30)+f32(5.1))
    wz=vnoise(qx*f32(0.30)+f32(7.7),qz*f32(0.30)+f32(2.9)-t*f32(0.08))
    wxm=(wx-f32(0.5))*f32(2.6); wzm=(wz-f32(0.5))*f32(2.6)
    r1=vnoise(qx*f32(2.6)+wxm+f32(0.9)*t*f32(0.6),qz*f32(1.2)+wzm+f32(0.5)*t*f32(0.6))
    r2=vnoise(qx*f32(4.9)-wxm*f32(1.4)-f32(0.5)*t*f32(0.9),qz*f32(2.3)+wzm*f32(1.4)+f32(0.9)*t*f32(0.9))
    sw=vnoise(qx*f32(0.33)+wxm*f32(0.4)+f32(0.6)*t*f32(0.15),qz*f32(0.33)+wzm*f32(0.4)+f32(0.4)*t*f32(0.15))
    amp=f32(0.35)+f32(0.65)*g
    return (r1*f32(0.16)*amp+r2*f32(0.09)*amp)*f32(AMP)+sw*f32(0.30)

t=f32(5.0); g=f32(0.75)
W=768; extent=22.0
xs=np.linspace(0.3,0.3+extent,W,dtype=np.float32); zs=np.linspace(0.3,0.3+extent,W,dtype=np.float32)
X,Z=np.meshgrid(xs,zs)
e=f32(0.16)
h0=wave(X,Z,t,g); hx=wave(X+e,Z,t,g); hz=wave(X,Z+e,t,g)
nx=-(hx-h0)/e; nz=-(hz-h0)/e; ln=np.sqrt(nx*nx+nz*nz+1)
nx/=ln; nz/=ln; ny=1/ln
print('tilt max',round(float(np.degrees(np.arctan(np.sqrt(nx**2+nz**2).max()))),1),
      'mean',round(float(np.degrees(np.arctan(np.sqrt(nx**2+nz**2).mean()))),1))
Image.fromarray((np.clip(np.stack([nx*2+0.5,ny*2,nz*2+0.5],-1),0,1)*255).astype(np.uint8)).save('work/sim5_normal.png')

# realistic-ish: sun elevation ~45deg az 20deg; camera looks toward sun (az 20), elevation 40
def draw(az_sun,elev_sun,az_cam,elev_cam,sh,fn):
    L=np.array([math.cos(elev_sun)*math.sin(az_sun),math.sin(elev_sun),math.cos(elev_sun)*math.cos(az_sun)],dtype=np.float32)
    V=np.array([math.cos(elev_cam)*math.sin(az_cam),math.sin(elev_cam),math.cos(elev_cam)*math.cos(az_cam)],dtype=np.float32)
    H=L+V; H/=np.linalg.norm(H)
    ndh=np.clip(nx*H[0]+ny*H[1]+nz*H[2],0,1)
    ndv=np.clip(nx*V[0]+ny*V[1]+nz*V[2],0,1)
    spec=np.clip(np.power(ndh,sh,dtype=np.float32)*10.0,0,1)
    Fs=f32(0.10)+f32(0.90)*np.power(1-ndv,5,dtype=np.float32)
    glit=np.clip(spec*Fs,0,1)*f32(0.2+0.8*0.75)
    frac=float((glit>0.3).mean()); meanb=float(glit.mean())
    print(f'  sun(e{elev_sun:.2f}) cam(e{elev_cam:.2f}) sh={sh:.0f} glit>0.3={frac:.4f} mean={meanb:.4f}')
    Image.fromarray((np.clip(glit,0,1)*255).astype(np.uint8)).save(fn)
D=math.radians
print('looking toward sun:')
for sh in (30,48,70,100):
    draw(D(20),D(45),D(20),D(40),sh,f'work/sim5_g_{sh}.png')
print('looking away:')
for sh in (48,):
    draw(D(20),D(45),D(200),D(40),sh,f'work/sim5_away_{sh}.png')
print('done')
