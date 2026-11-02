"""Reference vectors for image_preprocess_quad modes 0..6. Stdlib only."""
from pathlib import Path
import argparse, random
p=argparse.ArgumentParser()
p.add_argument('--width',type=int,default=8)
p.add_argument('--height',type=int,default=4)
p.add_argument('--frames',type=int,default=5)
p.add_argument('--threshold',type=int,default=128)
p.add_argument('--smooth-shift',type=int,default=2)
p.add_argument('--out',default='vectors_quad')
a=p.parse_args(); w,h,th=a.width,a.height,a.threshold
out=Path(a.out); out.mkdir(parents=True,exist_ok=True)
rng=random.Random(415)
names=['rgb','gray','blur','he','he_gray','median','sobel']
files={n:(out/f'{n}.hex').open('w') for n in names}
lut=list(range(256)); gray_lut=list(range(256))

def at(data, x, y):
    return data[min(h-1,max(0,y))*w+min(w-1,max(0,x))]

for f in range(a.frames):
    rgb=[]; gray=[]
    for y in range(h):
        for x in range(w):
            if f==0: r,g,b=(255,0,0) if x==0 else (0,255,0) if x==w-1 else (x*17%256,y*41%256,(x+y)*13%256)
            elif f==1: r=g=b=73
            elif f==2: r=g=b=255 if (x==w//2 and y==h//2) else 0
            elif f==3: r=g=b=255
            else: r,g,b=[rng.randrange(256) for _ in range(3)]
            rgb.append((r<<16)|(g<<8)|b)
            gray.append((77*r+150*g+29*b+128)//256)
    blur=[]
    for y in range(h):
        for x in range(w):
            s=0
            for dy,ky in [(-1,1),(0,2),(1,1)]:
                for dx,kx in [(-1,1),(0,2),(1,1)]:
                    s+=at(gray,x+dx,y+dy)*kx*ky
            blur.append((s+8)//16)
    # previous-frame global equalization (identity LUT on the first frame)
    he=[lut[v] for v in blur]
    he_gray=[gray_lut[v] for v in gray]
    gray_hist=[0]*256
    for v in gray: gray_hist[v]+=1
    cdf=0
    for i,n in enumerate(gray_hist): cdf+=n; gray_lut[i]=(((1<<a.smooth_shift)-1)*gray_lut[i]+255*cdf//(w*h))>>a.smooth_shift
    hist=[0]*256
    for v in blur: hist[v]+=1
    cdf=0
    for i,n in enumerate(hist): cdf+=n; lut[i]=(((1<<a.smooth_shift)-1)*lut[i]+255*cdf//(w*h))>>a.smooth_shift
    med=[]
    for y in range(h):
        for x in range(w):
            med.append(sorted(at(gray,x+dx,y+dy) for dy in (-1,0,1) for dx in (-1,0,1))[4])
    edge=[]
    for y in range(h):
        for x in range(w):
            gx=(at(gray,x+1,y-1)+2*at(gray,x+1,y)+at(gray,x+1,y+1))-(at(gray,x-1,y-1)+2*at(gray,x-1,y)+at(gray,x-1,y+1))
            gy=(at(gray,x-1,y+1)+2*at(gray,x,y+1)+at(gray,x+1,y+1))-(at(gray,x-1,y-1)+2*at(gray,x,y-1)+at(gray,x+1,y-1))
            edge.append(255 if abs(gx)+abs(gy)>th else 0)
    data={'rgb':rgb,'gray':gray,'blur':blur,'he':he,'he_gray':he_gray,'median':med,'sobel':edge}
    bits={'rgb':32,'gray':8,'blur':8,'he':8,'he_gray':8,'median':8,'sobel':8}
    for n in names:
        b=bits[n]
        for i in range(0,len(data[n]),4):
            word=sum(data[n][i+k]<<(k*b) for k in range(4))
            files[n].write(f'{word:0{b}x}\n')
for fh in files.values(): fh.close()
print(f'Generated {a.frames} frames of {w}x{h} quad reference (th={th}) in {out}')
