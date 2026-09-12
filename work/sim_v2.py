import numpy as np
from PIL import Image
f32=np.float32
def fract(x): return x-np.floor(x)
def vhash(px,pz):
    a=fract(px*f32(0.1031)); b=fract(pz*f32(0.1031)); c=a
    d=a*(b+f32(33.33))+b*(c+f32(33.33))+c*(a+f32(33.33))
    return fract(((a+d)+(b+d))*(c+d))
def vnoise(px,pz):
    ix=np.floor(px); iz=np.floor(pz); fx=px-ix; fz=pz-iz
    ux=fx*fx*(f32(3)-f32(2)*fx); uz=fz*fz*(f32(3)-f32(2)*fz)
    a=vhash(ix,iz); b=vhash(ix+f32(1),iz); c=vhash(ix,iz+f32(1)); d=vhash(ix+f32(1),iz+f32(1))
    ab=a+(b-a)*ux; cd=c+(d-c)*ux; return ab+(cd-ab)*uz
def mod289(x): return x-np.floor(x*f32(1/289))*f32(289)
def permute(x): return mod289(((x*f32(34))+f32(1))*x)
def snoise(vx,vz):
    Cx,Cz,Cy,Cw=f32(0.211324865405187),f32(0.366025403784439),f32(-0.577350269189626),f32(0.024390243902439)
    d=vx*Cz+vz*Cz; ix=np.floor(vx+d); iz=np.floor(vz+d); dx=vx-ix; dz=vz-iz; dd=ix*Cx+iz*Cx
    x0x=dx+dd; x0y=dz+dd; cond=x0x>x0y
    i1x=np.where(cond,f32(1),f32(0)); i1y=np.where(cond,f32(0),f32(1))
    x12x=x0x+Cx-i1x; x12y=x0y+Cx-i1y; x12z=x0x+Cy; x12w=x0y+Cy
    imx=mod289(ix); imz=mod289(iz)
    p0=permute(permute(imz)+imx); p1=permute(permute(imz+i1y)+imx+i1x); p2=permute(permute(imz+f32(1))+imx+f32(1))
    m0=np.maximum(f32(0.5)-(x0x*x0x+x0y*x0y),0); m1=np.maximum(f32(0.5)-(x12x*x12x+x12y*x12y),0); m2=np.maximum(f32(0.5)-(x12z*x12z+x12w*x12w),0)
    m0=m0*m0; m0=m0*m0; m1=m1*m1; m1=m1*m1; m2=m2*m2; m2=m2*m2
    X0=2*fract(p0*Cw)-1; X1=2*fract(p1*Cw)-1; X2=2*fract(p2*Cw)-1
    H0=np.abs(X0)-f32(0.5); H1=np.abs(X1)-f32(0.5); H2=np.abs(X2)-f32(0.5)
    A0=X0-np.floor(X0+f32(0.5)); A1=X1-np.floor(X1+f32(0.5)); A2=X2-np.floor(X2+f32(0.5))
    S=f32(1.79284291400159)-f32(0.85373472095314)
    m0=m0*(S*(A0*A0+H0*H0)); m1=m1*(S*(A1*A1+H1*H1)); m2=m2*(S*(A2*A2+H2*H2))
    return 130*(m0*(A0*x0x+H0*x0y)+m1*(A1*x12x+H1*x12y)+m2*(A2*x12z+H2*x12w))
def fbm(ux,uz):
    gain=f32(0.6); lac=f32(2.0); freq=f32(0.1); amp=gain
    ux=ux*f32(5); uz=uz*f32(5); total=snoise(ux,uz)
    for i in range(5):
        total=total+snoise(ux*freq,uz*freq)*amp; freq=freq*lac; amp=amp*gain
    return (total+f32(2))/f32(4)
def pattern(px,pz):
    a=fbm(px,pz); return fbm(px+a,pz+a)
M=np.array([[-2,3,1],[-1,-2,2],[2,1,2]],dtype=np.float32)
def fn(vx,vy,vz,scale):
    nx=(vx*M[0,0]+vy*M[1,0]+vz*M[2,0])*scale
    ny=(vx*M[0,1]+vy*M[1,1]+vz*M[2,1])*scale
    nz=(vx*M[0,2]+vy*M[1,2]+vz*M[2,2])*scale
    return nx,ny,nz,np.sqrt((0.5-fract(nx))**2+(0.5-fract(ny))**2+(0.5-fract(nz))**2)
def caustics(px,pz,t,grain,gain):
    wx=vnoise(px*f32(0.075), pz*f32(0.075)+t*f32(0.05))
    wz=vnoise(px*f32(0.075)+f32(11.3), pz*f32(0.075)-t*f32(0.04))
    qx=(px+(wx-f32(0.5))*f32(4.0))*f32(0.32)*grain
    qz=(pz+(wz-f32(0.5))*f32(4.0))*f32(0.40)*grain
    vx,vy,vz=qx,qz,np.full_like(px,t*f32(0.16))
    vx,vy,vz,a1=fn(vx,vy,vz,f32(0.5)); vx,vy,vz,a2=fn(vx,vy,vz,f32(0.4)); vx,vy,vz,a3=fn(vx,vy,vz,f32(0.3))
    a=np.minimum(np.minimum(a1,a2),a3)
    cav=np.power(a,f32(7.0),dtype=np.float32)*gain
    gate=vnoise(px*f32(0.04)+f32(5.7), pz*f32(0.04)+f32(2.1))
    g=np.clip((gate-f32(0.10))/f32(0.50),0,1); g=g*g*(3-2*g)
    return cav*g
def waves(px,pz,t):
    dx,dz=f32(0.86),f32(0.51); pdx,pdz=-dz,dx
    alo=(px*dx+pz*dz)*f32(0.35)+t*f32(0.55)
    acr=(px*pdx+pz*pdz)*f32(1.9)
    n=vnoise(acr,alo)+f32(0.5)*vnoise(acr*f32(2.1)+f32(3.0),alo*f32(1.7))
    n=n/f32(1.5)
    return np.power(np.clip(n,0,1),f32(2.5))*f32(1.8)
t=f32(6.0); grain=f32(1.0); density=f32(0.93); strength=f32(0.55); soft=f32(0.45)
W=1000; H=520; extent=26.0
xs=np.linspace(0.5,0.5+extent,W,dtype=np.float32); zs=np.linspace(0.5,0.5+extent*H/W,H,dtype=np.float32)
X,Z=np.meshgrid(xs,zs)
# fake ocean: depth grows with x; rgb darkens with depth (mimic tile colours)
u=np.clip(X/extent,0,1)
dr=u  # depth ramp
ocean_rgb=np.stack([f32(0.95)-dr*f32(0.75), f32(1.0)-dr*f32(0.55), f32(1.0)-dr*f32(0.35)],-1)
ocean_a=np.ones_like(X)
lum=ocean_rgb[...,0]*f32(0.299)+ocean_rgb[...,1]*f32(0.587)+ocean_rgb[...,2]*f32(0.114)
depth=np.clip((1-lum)*f32(1.7),0,1)
depth=np.clip(depth+(vnoise(X*f32(0.03),Z*f32(0.03))-f32(0.5))*f32(0.35),0,1)
deep=depth*f32(5); deep=np.clip((deep-f32(0.18))/f32(0.54),0,1); deep=deep*deep*(3-2*deep)
f=pattern(X*f32(0.008)/f32(10),Z*f32(0.010)/f32(10)); f=f*f32(1.5)+f32(0.3)
seabed=np.sqrt(np.stack([f*f32(1.2),f*f32(0.8),f*f32(0.4)],-1)*f32(0.8))
gain=f32(10)+ (density-f32(0.93))*f32(50)
cau=caustics(X,Z,t,grain,gain)
wav=waves(X,Z,t)*gain*f32(0.10)
glit=cau*(1-deep)+wav*deep
glitcol=np.stack([f32(1.0)*(1-deep)+f32(0.78)*deep, f32(0.96)*(1-deep)+f32(0.94)*deep, f32(0.84)*(1-deep)+f32(1.0)*deep],-1)
gs=np.clip((depth-f32(0.10))/f32(0.50),0,1); gs=gs*gs*(3-2*gs)
goldAmt=1-gs
col=seabed*goldAmt[...,None]+glitcol*glit[...,None]
oceanDeep=np.maximum(ocean_rgb,f32(0.10))
mixf=soft*f32(0.5)+deep*f32(0.35)
col=col*(1-mixf[...,None])+col*oceanDeep*mixf[...,None]
amt=strength*(1-deep*f32(0.70))*f32(0.95)
base=np.array([0.10,0.30,0.32],dtype=np.float32)  # look through to water
out=np.clip(col*amt[...,None]+base*(1-amt[...,None]),0,1)
Image.fromarray((out*255).astype(np.uint8)).save('work/v2_preview.png')
print('deep range',round(float(deep.min()),2),round(float(deep.max()),2),'glit max',round(float(glit.max()),2))
print('done')
