"""把 gen-image 生成的 3x3 绿幕关键帧图合成为 96px 透明 GIF（与 heartbeat.gif 同尺寸、同静止位置）。
用法：python3 scripts/build_heart_gifs.py <sheet_flutter.png> <sheet_broken.png> <输出目录>
依赖：Pillow、numpy、scipy。Prompt 见 docs/affection-heart-animations.md。
"""
import sys
from PIL import Image
import numpy as np
from scipy import ndimage
C=96; SS=4  # render at 4x then downsample

def cells(name):
    a=np.asarray(Image.open(SHEETS[name]).convert('RGB')).astype(np.float32)
    H,W,_=a.shape; out=[]
    for k in range(9):
        y0,x0=(k//3)*H//3,(k%3)*W//3
        c=a[y0:y0+H//3,x0:x0+W//3].copy()
        r,g,b=c[...,0],c[...,1],c[...,2]
        m=((r-g>55)&(r>120)&(b>g-8))|((r>215)&(g>215)&(b>215))   # pink/rose or white only; drops green bg + glow
        m=ndimage.binary_opening(m,iterations=1)
        lab,n=ndimage.label(m); sz=ndimage.sum(m,lab,range(1,n+1))
        keep=np.zeros_like(m)
        for i,s in enumerate(sz):
            if s>=40: keep|=lab==i+1
        c[...,1]=np.minimum(g,np.maximum(r,b))  # despill
        out.append((c,keep))
    return out

def comps(mask,minsize=2000):
    lab,n=ndimage.label(mask); sz=ndimage.sum(mask,lab,range(1,n+1))
    return lab,[i+1 for i,s in enumerate(sz) if s>=minsize],[i+1 for i,s in enumerate(sz) if s<minsize]

def render(c,mask,scale,dx,dy,pull=None):
    """place source pixels (mask) scaled by `scale`; source point (0,0) maps to (dx,dy) in 96px canvas.
    pull=(cx,cy,f): move small components toward (cx,cy) source point by factor f."""
    h,w=mask.shape
    canvas=np.zeros((C*SS,C*SS,4),np.float32)
    lab,big,small=comps(mask)
    groups=[(lab==i,0,0) for i in big]
    for i in small:
        m=lab==i
        if pull:
            ys,xs=np.where(m); cy,cx=ys.mean(),xs.mean()
            hx,hy,hw,hh,f=pull; ux,uy=(cx-hx)/hw,(cy-hy)/hh; rho=max(1e-3,(ux*ux+uy*uy)**.5)
            k=(1+max(0,rho-1)*f)/rho if rho>1 else 1
            ox=hx+(cx-hx)*k-cx; oy=hy+(cy-hy)*k-cy
        else: ox=oy=0
        groups.append((m,ox,oy))
    for m,ox,oy in groups:
        rgba=np.dstack([c,m*255.0]).astype(np.uint8)
        im=Image.fromarray(rgba,'RGBA')
        ys,xs=np.where(m); bb=(xs.min(),ys.min(),xs.max()+1,ys.max()+1)
        im=im.crop(bb)
        k=scale*SS
        tw,th=max(1,round(im.width*k)),max(1,round(im.height*k))
        # premultiply for clean resize
        arr=np.asarray(im).astype(np.float32); arr[...,:3]*=arr[...,3:]/255
        pim=Image.fromarray(arr.astype(np.uint8),'RGBA').resize((tw,th),Image.LANCZOS)
        p=np.asarray(pim).astype(np.float32)
        x=round((dx+(bb[0]+ox)*scale)*SS); y=round((dy+(bb[1]+oy)*scale)*SS)
        x0,y0=max(0,x),max(0,y); x1,y1=min(C*SS,x+tw),min(C*SS,y+th)
        if x1<=x0 or y1<=y0: continue
        sp=p[y0-y:y1-y,x0-x:x1-x]; a=sp[...,3:]/255
        canvas[y0:y1,x0:x1,:3]=sp[...,:3]+canvas[y0:y1,x0:x1,:3]*(1-a)
        canvas[y0:y1,x0:x1,3:]=sp[...,3:]+canvas[y0:y1,x0:x1,3:]*(1-a)
    # downsample premultiplied, then hard alpha for GIF
    img=Image.fromarray(np.clip(canvas,0,255).astype(np.uint8),'RGBA').resize((C,C),Image.BOX)
    q=np.asarray(img).astype(np.float32); a=q[...,3:]
    rgb=np.where(a>0,q[...,:3]*255/np.maximum(a,1),0)
    alpha=(a>=110)*255
    return Image.fromarray(np.dstack([np.clip(rgb,0,255),alpha]).astype(np.uint8),'RGBA')

def bigbox(mask):
    lab,big,_=comps(mask); m=np.isin(lab,big); ys,xs=np.where(m)
    return xs.min(),ys.min(),xs.max()+1,ys.max()+1

HEART_W=56; CX,CY=48,48.5   # matches heartbeat.gif (bbox 20..76 x 24..73)

def flutter():
    cs=cells('flutter'); base=bigbox(cs[0][1]); s=HEART_W/(base[2]-base[0])
    frames=[]
    target={4:56,5:59,6:56,7:56}
    for k,(c,m) in enumerate(cs):
        x0,y0,x1,y1=bigbox(m); hx,hy=(x0+x1)/2,(y0+y1)/2
        s=target[k]/(x1-x0) if k in target else HEART_W/(base[2]-base[0])
        frames.append(render(c,m,s,CX-hx*s,CY-hy*s,pull=(hx,hy,(x1-x0)/2,(y1-y0)/2,0.4)))
    seq=[(0,70),(1,70),(2,70),(3,140),(4,70),(5,70),(6,140),(7,140),(0,770)]
    return frames,seq

def broken():
    cs=cells('broken'); base=bigbox(cs[0][1]); bw=base[2]-base[0]; bh=base[3]-base[1]
    s=HEART_W/bw; top0=CY-bh*s/2
    drop=[0,0,0,0,0,1,4,8,10]
    frames=[]
    for k,(c,m) in enumerate(cs):
        x0,y0,x1,y1=bigbox(m)
        sk=HEART_W/(x1-x0) if k<4 else s     # frames 1-4: intact heart, normalise size
        if k<4: dy=CY-(y0+y1)/2*sk
        else: dy=top0+drop[k]-y0*sk
        frames.append(render(c,m,sk,CX-(x0+x1)/2*sk,dy))
    # shake frame 2 horizontally
    def shift(im,d):
        o=Image.new('RGBA',im.size,(0,0,0,0)); o.paste(im,(d,0)); return o
    frames+= [shift(frames[1],-2),shift(frames[1],2)]
    seq=[(0,140),(9,70),(10,70),(1,70),(2,140),(3,140),(4,70),(5,70),(6,70),(7,140),(8,1200)]
    return frames,seq

def save(frames,seq,path):
    imgs=[];durs=[]
    for i,d in seq:
        imgs.append(frames[i]); durs.append(d)
    imgs[0].save(path,save_all=True,append_images=imgs[1:],duration=durs,loop=0,disposal=2,transparency=0,optimize=False)
    sheet=Image.new('RGBA',(C*3*len(imgs),C*3),(200,200,200,255))
    for j,im in enumerate(imgs): sheet.alpha_composite(im.resize((C*3,C*3),Image.NEAREST),(j*C*3,0))
    sheet.save(path.replace('.gif','_preview.png'))

if __name__=='__main__':
    SHEETS={'flutter':sys.argv[1],'broken':sys.argv[2]}; out=sys.argv[3].rstrip('/')
    save(*flutter(),f'{out}/heartflutter.gif')
    save(*broken(),f'{out}/heartbreak.gif')
