import numpy as np
from PIL import Image
f32=np.float32
M = np.array([[-2,3,1],[-1,-2,2],[2,1,2]],dtype=np.float32)  # columns c0,c1,c2 -> rows here: row0=(-2,3,1)? 
# careful: m*v with c0=(-2,-1,2),c1=(3,-2,1),c2=(1,2,2)
# m*v = ( -2vx+3vy+1vz, -1vx-2vy+2vz, 2vx+1vy+2vz )
M = np.array([[-2,3,1],[-1,-2,2],[2,1,2]],dtype=np.float32)  # row i = coefficients for output i
def fn(vx,vy,vz,scale):
    ms=M*scale
    nx=ms[0,0]*vx+ms[0,1]*vy+ms[0,2]*vz
    ny=ms[1,0]*vx+ms[1,1]*vy+ms[1,2]*vz
    nz=ms[2,0]*vx+ms[2,1]*vy+ms[2,2]*vz
    return nx,ny,nz, np.sqrt((0.5-(nx-np.floor(nx)))**2+(0.5-(ny-np.floor(ny)))**2+(0.5-(nz-np.floor(nz)))**2)
def caustics(px,pz,t):
    vx,vy,vz=px,pz,np.full_like(px,f32(t*0.16))
    vx,vy,vz,a1=fn(vx,vy,vz,f32(0.5))
    vx,vy,vz,a2=fn(vx,vy,vz,f32(0.4))
    vx,vy,vz,a3=fn(vx,vy,vz,f32(0.3))
    return np.minimum(np.minimum(a1,a2),a3)
t=f32(4.0); W=800; extent=18.0
xs=np.linspace(0.3,0.3+extent,W,dtype=np.float32); zs=np.linspace(0.3,0.3+extent,W,dtype=np.float32)
X,Z=np.meshgrid(xs,zs)
def save(n,a): Image.fromarray((np.clip(a,0,1)*255).astype(np.uint8)).save(n)
for label,(sx,sz) in [('old',(0.24,0.30)),('mid',(0.45,0.55)),('fine',(0.70,0.85))]:
    a=caustics(X*sx,Z*sz,t)
    save(f'work/caus_{label}_raw.png', a/0.71)
    print(label,'a range',float(a.min()),float(a.max()),'mean',float(a.mean()))
# extraction sweep on mid
a=caustics(X*f32(0.45),Z*f32(0.55),t)
for thr,band in [(0.50,0.09),(0.52,0.05),(0.54,0.03)]:
    web=np.clip((a-thr)/band,0,1); web=web*web*(3-2*web)
    save(f'work/caus_mid_t{int(thr*100)}_b{int(band*100)}.png', web)
    print(f'thr{thr} band{band} web>0.3 {float((web>0.3).mean()):.3f}')
print('done')
