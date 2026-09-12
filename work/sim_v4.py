import numpy as np
from PIL import Image
f32=np.float32
def fract(x): return x-np.floor(x)
def vhash(px,pz):
    a=fract(px*f32(0.1031)); b=fract(pz*f32(0.1031)); c=a
    d=a*(b+f32(33.33))+b*(c+f32(33.33))+c*(a+f32(33.33)); return fract(((a+d)+(b+d))*(c+d))
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
def caustics(px,pz,t,grain,gain,deep):
    wx=vnoise(px*f32(0.075), pz*f32(0.075)+t*f32(0.05))
    wz=vnoise(px*f32(0.075)+f32(11.3), pz*f32(0.075)-t*f32(0.04))
    wxp=px+(wx-f32(0.5))*f32(2.8); wzp=pz+(wz-f32(0.5))*f32(2.8)
    dx,dz=f32(0.86),f32(0.51); pdx,pdz=-dz,dx
    u=wxp*dx+wzp*dz; v=wxp*pdx+wzp*pdz
    qx=u*f32(0.32)*(1-f32(0.30)*deep)*grain; qz=v*f32(0.40)*(1+f32(2.0)*deep)*grain
    vx,vy,vz=qx,qz,np.full_like(px,t*f32(0.16))
    vx,vy,vz,a1=fn(vx,vy,vz,f32(0.5)); vx,vy,vz,a2=fn(vx,vy,vz,f32(0.4)); vx,vy,vz,a3=fn(vx,vy,vz,f32(0.3))
    a=np.minimum(np.minimum(a1,a2),a3); cav=np.power(a,f32(7.0),dtype=np.float32)*gain
    gate=vnoise(px*f32(0.04)+f32(5.7), pz*f32(0.04)+f32(2.1))
    g=np.clip((gate-f32(0.15))/f32(0.55),0,1); g=g*g*(3-2*g)
    return cav*(f32(0.45)+f32(0.55)*g)*(1-deep*f32(0.62))
def sand(px,pz,t):
    m=f32(0.5)+f32(0.5)*(snoise(px*f32(0.17),pz*f32(0.17))*f32(0.55)+snoise(px*f32(0.40)+f32(5.1),pz*f32(0.40)+f32(2.3))*f32(0.30)+snoise(px*f32(0.90)+f32(9.0),pz*f32(0.90)+f32(1.7))*f32(0.15))
    lo=np.array([0.66,0.73,0.52],dtype=np.float32); hi=np.array([0.83,0.85,0.66],dtype=np.float32)
    col=lo[None,None,:]+(hi-lo)[None,None,:]*np.clip(m,0,1)[...,None]
    det=f32(1)/(f32(1)+np.sqrt(px*px+pz*pz)*f32(0.05))
    cl=vnoise(px*f32(0.55)+f32(3.0),pz*f32(0.55)+f32(7.0))
    sp=vnoise(px*f32(3.0),pz*f32(3.0)+t*f32(0.02))
    a=np.clip((cl-f32(0.50))/f32(0.45),0,1); a=a*a*(3-2*a)
    b=np.clip((sp-f32(0.55))/f32(0.35),0,1); b=b*b*(3-2*b)
    col=col*(1-f32(0.12)*(a*b*det))[...,None]
    return col
t=f32(4.0); strength=f32(0.55); soft=f32(0.45)
W=900; H=480; extent=24.0
xs=np.linspace(0.5,0.5+extent,W,dtype=np.float32); zs=np.linspace(0.5,0.5+extent*H/W,H,dtype=np.float32)
X,Z=np.meshgrid(xs,zs)
# vanilla ocean base: greenish (user's OceanOn palette) for shallow
base=np.array([0.20,0.34,0.22],dtype=np.float32)
oceanDeep=base
sd=sand(X,Z,t)
cau=caustics(X,Z,t,f32(1.0),f32(10.0),f32(0.0))
glit=np.stack([f32(1.0),f32(0.97),f32(0.88)],-1)*cau[...,None]
col=sd+glit
col=col*(1-f32(0.18))+col*oceanDeep[None,None,:]*f32(0.18)
amt=strength*f32(1.00)
out=np.clip(col*amt+base[None,None,:]*(1-amt),0,1)
Image.fromarray((out*255).astype(np.uint8)).save('work/v4_shallow.png')
print('sand mean rgb',[round(float(sd[...,i].mean()),2) for i in range(3)])
print('done')
