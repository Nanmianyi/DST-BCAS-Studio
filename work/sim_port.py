import numpy as np
from PIL import Image
f32=np.float32
def fract(x): return x-np.floor(x)
def mod289(x): return x-np.floor(x*(f32(1)/f32(289)))*f32(289)
def permute(x): return mod289(((x*f32(34))+f32(1))*x)
def snoise(vx,vz):
    Cx,Cz,Cy,Cw=f32(0.211324865405187),f32(0.366025403784439),f32(-0.577350269189626),f32(0.024390243902439)
    d=vx*Cz+vz*Cz
    ix=np.floor(vx+d); iz=np.floor(vz+d)
    dx=vx-ix; dz=vz-iz
    dd=ix*Cx+iz*Cx
    x0x=dx+dd; x0y=dz+dd
    cond=x0x>x0y
    i1x=np.where(cond,f32(1),f32(0)); i1y=np.where(cond,f32(0),f32(1))
    x12x=x0x+Cx-i1x; x12y=x0y+Cx-i1y
    x12z=x0x+Cy; x12w=x0y+Cy
    imx=mod289(ix); imz=mod289(iz)
    p0=permute(permute(imz+f32(0))+imx+f32(0))
    p1=permute(permute(imz+i1y)+imx+i1x)
    p2=permute(permute(imz+f32(1))+imx+f32(1))
    m0=np.maximum(f32(0.5)-(x0x*x0x+x0y*x0y),0)
    m1=np.maximum(f32(0.5)-(x12x*x12x+x12y*x12y),0)
    m2=np.maximum(f32(0.5)-(x12z*x12z+x12w*x12w),0)
    m0=m0*m0; m0=m0*m0; m1=m1*m1; m1=m1*m1; m2=m2*m2; m2=m2*m2
    X0=2*fract(p0*Cw)-1; X1=2*fract(p1*Cw)-1; X2=2*fract(p2*Cw)-1
    H0=np.abs(X0)-f32(0.5); H1=np.abs(X1)-f32(0.5); H2=np.abs(X2)-f32(0.5)
    A0=X0-np.floor(X0+f32(0.5)); A1=X1-np.floor(X1+f32(0.5)); A2=X2-np.floor(X2+f32(0.5))
    S=f32(1.79284291400159)-f32(0.85373472095314)
    m0=m0*(S*(A0*A0+H0*H0)); m1=m1*(S*(A1*A1+H1*H1)); m2=m2*(S*(A2*A2+H2*H2))
    g0=A0*x0x+H0*x0y
    g1=A1*x12x+H1*x12y
    g2=A2*x12z+H2*x12w
    return 130*(m0*g0+m1*g1+m2*g2)
def fbm(ux,uz):
    gain=f32(0.6); lac=f32(2.0); total=np.zeros_like(ux); freq=f32(0.1); amp=gain
    ux=ux*f32(5); uz=uz*f32(5)
    total=snoise(ux,uz)
    for i in range(5):
        total=total+snoise(ux*freq,uz*freq)*amp
        freq=freq*lac; amp=amp*gain
    return (total+f32(2))/f32(4)
def pattern(px,pz):
    a=fbm(px,pz)
    b=fbm(px+a,pz+a)
    return fbm(px+b,pz+b)
M=np.array([[-2,3,1],[-1,-2,2],[2,1,2]],dtype=np.float32)
def fn(vx,vy,vz,scale):
    ms=M*scale
    nx=ms[0,0]*vx+ms[0,1]*vy+ms[0,2]*vz
    ny=ms[1,0]*vx+ms[1,1]*vy+ms[1,2]*vz
    nz=ms[2,0]*vx+ms[2,1]*vy+ms[2,2]*vz
    return nx,ny,nz,np.sqrt((0.5-fract(nx))**2+(0.5-fract(ny))**2+(0.5-fract(nz))**2)
def caustic(px,pz,t,grain):
    vx,vy,vz=px*f32(0.32)*grain, pz*f32(0.40)*grain, np.full_like(px,t*f32(0.16))
    vx,vy,vz,a1=fn(vx,vy,vz,f32(0.5)); vx,vy,vz,a2=fn(vx,vy,vz,f32(0.4)); vx,vy,vz,a3=fn(vx,vy,vz,f32(0.3))
    a=np.minimum(np.minimum(a1,a2),a3)
    return np.power(a,f32(7.0),dtype=np.float32)*f32(10.0)
t=f32(6.0); grain=f32(1.0); strength=f32(0.55)
W=900; extent=30.0
xs=np.linspace(0.5,0.5+extent,W,dtype=np.float32); zs=np.linspace(0.5,0.5+extent,W,dtype=np.float32)
X,Z=np.meshgrid(xs,zs)
bx=X*f32(0.008); bz=Z*f32(0.010)
f=pattern(bx/f32(10.0),bz/f32(10.0)); f=f*f32(1.5)+f32(0.3)
col=np.stack([f*f32(1.2),f*f32(0.8),f*f32(0.4)],-1)*f32(0.8); col=np.sqrt(col)
c=caustic(X,Z,t,grain)
col=col+np.stack([c,c,c],-1)
base=np.array([0.06,0.22,0.20],dtype=np.float32)
amt=strength
out=np.clip(col*amt+base*(1-amt),0,1)
Image.fromarray((out*255).astype(np.uint8)).save('work/port_preview.png')
Image.fromarray((np.clip(col,0,1)*255).astype(np.uint8)).save('work/port_col.png')
print('f range',round(float(f.min()),2),round(float(f.max()),2),'caustic max',round(float(c.max()),2),'c>0.5 frac',round(float((c>0.5).mean()),4))
print('done')
