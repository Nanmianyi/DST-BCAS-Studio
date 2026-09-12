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
def height(qx,qz,t,g):
    wx=vnoise(qx*f32(0.30)+f32(1.3)+t*f32(0.10),qz*f32(0.30)+f32(5.1))
    wz=vnoise(qx*f32(0.30)+f32(7.7),qz*f32(0.30)+f32(2.9)-t*f32(0.08))
    wxm=(wx-f32(0.5))*f32(2.6); wzm=(wz-f32(0.5))*f32(2.6)
    rip=vnoise(qx*f32(3.0)+wxm+f32(0.9)*t*f32(0.6),qz*f32(1.4)+wzm+f32(0.5)*t*f32(0.6))
    sw=vnoise(qx*f32(0.33)+wxm*f32(0.4)+f32(0.6)*t*f32(0.15),qz*f32(0.33)+wzm*f32(0.4)+f32(0.4)*t*f32(0.15))
    amp=f32(0.35)+f32(0.65)*g
    return rip*f32(0.50)*amp + sw*f32(0.30)
t=f32(2.0); grain=f32(1.0); density=f32(0.93); energy=f32(0.55)
W=900; extent=30.0
xs=np.linspace(0.5,0.5+extent,W,dtype=np.float32); zs=np.linspace(0.5,0.5+extent,W,dtype=np.float32)
X,Z=np.meshgrid(xs,zs)
gust=np.clip(vnoise(X*f32(0.045)-t*f32(0.021),Z*f32(0.045)-t*f32(0.013))*f32(1.5)-f32(0.25),0,1)
qx=X*grain; qz=Z*grain; e=f32(0.14)
h0=height(qx,qz,t,gust); hx=height(qx+e,qz,t,gust); hz=height(qx,qz+e,t,gust)
nx=-(hx-h0)/e*grain; nz=-(hz-h0)/e*grain
dist=np.sqrt(X**2+Z**2)
nx=nx*np.maximum(f32(0.40),1/(1+dist*f32(0.10))); nz=nz*np.maximum(f32(0.40),1/(1+dist*f32(0.10)))
ln=np.sqrt(nx*nx+nz*nz+1); nx/=ln; nz/=ln; ny=1/ln
D=math.radians
L=np.array([math.cos(D(45))*math.sin(D(20)),math.sin(D(45)),math.cos(D(45))*math.cos(D(20))],dtype=np.float32)
ndl=np.clip(nx*L[0]+ny*L[1]+nz*L[2],0,1)
dn=float(np.clip((density-0.80)/0.198,0,1)); sharp=6.0*(6.667**dn)
glint=np.clip(np.power(ndl,sharp,dtype=np.float32)*2.0,0,1)
glint=glint*(f32(0.25)+f32(0.75)*gust)
sy=f32(0.7071); lowSun=1-float(sy)
warm=np.array([1.0,0.96+(0.74-0.96)*lowSun,0.86+(0.44-0.86)*lowSun],dtype=np.float32)
sheen=np.clip((1-ny)*f32(2.2),0,1)*f32(0.10)*(f32(0.4)+f32(0.6)*gust)
sky=np.array([0.34+(1.0-0.34)*lowSun*0.6,0.54+(0.74-0.54)*lowSun*0.6,0.84+(0.44-0.84)*lowSun*0.6],dtype=np.float32)
rgb=(warm[None,None,:]*(glint*2.0)[...,None]+sky[None,None,:]*sheen[...,None])*energy
alpha=np.clip((glint*f32(1.6)+sheen)*energy,0,1)
# composite over a dark teal water body
base=np.array([0.06,0.20,0.22],dtype=np.float32)
out=rgb+base*(1-alpha[...,None])
out=np.clip(out,0,1)
Image.fromarray((out*255).astype(np.uint8)).save('work/sim_final_preview.png')
print('glint>0.3 frac',round(float((glint>0.3).mean()),4),'alpha mean',round(float(alpha.mean()),4))
print('done')
