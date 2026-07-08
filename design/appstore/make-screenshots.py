from PIL import Image, ImageDraw, ImageFont
import math, os

OUT = "/Users/kevinnadjarian/GitHub/Throttle/design/appstore/screenshots"
os.makedirs(OUT, exist_ok=True)
W, H = 1320, 2868

BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
REG  = "/System/Library/Fonts/Helvetica.ttc"
MONO = "/System/Library/Fonts/SFNSMono.ttf"
def f(path, sz): return ImageFont.truetype(path, sz)

ACC=(0,113,227); WARN=(255,159,10); CRIT=(255,59,48); OK=(52,199,89)
INK=(29,29,31); SEC=(110,110,115); TER=(161,161,166); HAIR=(0,0,0,28)
PANEL=(251,251,253)

def bg(d):
    for y in range(H):
        t=y/H
        c=(int(26+t*4),int(30+t*6),int(42+t*10))   # #1a1e2a → deep
        d.line([(0,y),(W,y)],fill=c)

def caption(d, l1, l2):
    fb=f(BOLD,96)
    for i,line in enumerate([l1,l2]):
        w=d.textlength(line,font=fb)
        d.text(((W-w)/2, 150+i*118), line, font=fb, fill=(255,255,255))

def phone(im):
    x0,y0,x1,y1=150,560,1170,2760
    d=ImageDraw.Draw(im)
    d.rounded_rectangle([x0-4,y0-4,x1+4,y1+4], radius=104, fill=(0,0,0))
    d.rounded_rectangle([x0,y0,x1,y1], radius=100, fill=PANEL)
    # dynamic island
    d.rounded_rectangle([W/2-70,y0+30,W/2+70,y0+78], radius=24, fill=(0,0,0))
    return d,(x0,y0,x1,y1)

def col(c): return c

def meter(d, cx, cy, R, Wd, pct, color):
    bb=[cx-R,cy-R,cx+R,cy+R]
    d.arc(bb,0,360,fill=(230,230,233),width=Wd)
    end=-90+pct/100*360
    d.arc(bb,-90,end,fill=color,width=Wd)
    for a in (-90,end):
        x=cx+R*math.cos(math.radians(a)); y=cy+R*math.sin(math.radians(a)); r=Wd/2
        d.ellipse([x-r,y-r,x+r,y+r],fill=color)

def bar(d, x, y, w, pct, color, label):
    d.text((x,y), label, font=f(REG,34), fill=INK)
    pl=f(MONO,34); pw=d.textlength(f"{pct}%",font=pl)
    d.text((x+w-pw,y), f"{pct}%", font=pl, fill=color)
    ty=y+52
    d.rounded_rectangle([x,ty,x+w,ty+14], radius=7, fill=(228,228,232))
    d.rounded_rectangle([x,ty,x+int(w*pct/100),ty+14], radius=7, fill=color)

def cell(d, x, y, w, v, t):
    d.rounded_rectangle([x,y,x+w,y+150], radius=22, outline=(206,206,212), width=2)
    vf=f(MONO,44); vw=d.textlength(v,font=vf)
    d.text((x+(w-vw)/2, y+34), v, font=vf, fill=INK)
    tf=f(REG,28); tw=d.textlength(t,font=tf)
    d.text((x+(w-tw)/2, y+96), t, font=tf, fill=SEC)

# ---------- Screen 1: hero ----------
def hero():
    im=Image.new("RGB",(W,H)); d=ImageDraw.Draw(im); bg(d)
    caption(d,"Your Claude limits,","at a single glance.")
    d,(x0,y0,x1,y1)=phone(im); d=ImageDraw.Draw(im)
    d.text((x0+60,y0+120),"Throttle",font=f(BOLD,52),fill=INK)
    cx=(x0+x1)//2
    meter(d,cx,y0+520,300,64,58,ACC)
    d.text((cx-d.textlength("58",font=f(MONO,150))/2, y0+430),"58",font=f(MONO,150),fill=ACC)
    d.text((cx-d.textlength("USED",font=f(BOLD,32))/2, y0+610),"USED",font=f(BOLD,32),fill=SEC)
    d.text((cx-d.textlength("resets in 2h 14m",font=f(REG,30))/2, y0+680),"resets in 2h 14m",font=f(REG,30),fill=TER)
    bx=x0+80; bw=x1-x0-160
    bar(d,bx,y0+980,bw,58,ACC,"5-hour session")
    bar(d,bx,y0+1140,bw,83,WARN,"7-day")
    cw=(bw-60)//3
    cell(d,bx,y0+1340,cw,"€12.34","Cost 7d")
    cell(d,bx+cw+30,y0+1340,cw,"1.2M","Tokens 7d")
    cell(d,bx+2*(cw+30),y0+1340,cw,"89k","Saved")
    im.save(f"{OUT}/01-usage.png"); print("01")

# ---------- Screen 2: sessions ----------
def sessions():
    im=Image.new("RGB",(W,H)); d=ImageDraw.Draw(im); bg(d)
    caption(d,"Every session,","mirrored — read-only.")
    d,(x0,y0,x1,y1)=phone(im); d=ImageDraw.Draw(im)
    d.text((x0+60,y0+120),"Sessions",font=f(BOLD,72),fill=INK)
    rows=[("Throttle","opus · working",OK,"€1.12","5.0k",False),
          ("Lumen Cam","sonnet · waiting",WARN,"€0.21","900",True),
          ("Éclair","opus · idle",TER,"€3.40","18k",False),
          ("404","rate-limited · 14:00",CRIT,"€0.88","4.1k",False),
          ("Inkwell","hibernated · 0 tok",(200,200,205),"—","—",False)]
    y=y0+260
    for name,meta,c,eur,tok,wait in rows:
        d.line([(x0+50,y),(x1-50,y)],fill=(228,228,232))
        d.ellipse([x0+64,y+52,x0+92,y+80],fill=c)
        d.text((x0+130,y+34),name,font=f(REG,42),fill=INK)
        d.text((x0+130,y+90),meta,font=f(REG,30),fill=SEC)
        ef=f(MONO,40); ew=d.textlength(eur,font=ef)
        d.text((x1-70-ew,y+40),eur,font=ef,fill=INK)
        tf=f(MONO,30); tw=d.textlength(tok,font=tf)
        d.text((x1-70-tw,y+92),tok,font=tf,fill=SEC)
        if wait: d.ellipse([x1-56,y+58,x1-40,y+74],fill=WARN)
        y+=190
    im.save(f"{OUT}/02-sessions.png"); print("02")

# ---------- Screen 3: history ----------
def history():
    im=Image.new("RGB",(W,H)); d=ImageDraw.Draw(im); bg(d)
    caption(d,"Trends that work","even Mac-off.")
    d,(x0,y0,x1,y1)=phone(im); d=ImageDraw.Draw(im)
    d.text((x0+60,y0+120),"History",font=f(BOLD,72),fill=INK)
    # segmented
    sx=x0+60; sw=x1-x0-120
    d.rounded_rectangle([sx,y0+240,sx+sw,y0+312], radius=16, fill=(232,232,236))
    seg=sw/3
    d.rounded_rectangle([sx+4,y0+244,sx+seg-4,y0+308], radius=13, fill=(255,255,255))
    for i,t in enumerate(["24h","7d","30d"]):
        tw=d.textlength(t,font=f(BOLD,34))
        d.text((sx+seg*i+(seg-tw)/2, y0+258), t, font=f(BOLD,34), fill=INK if i==0 else SEC)
    # chart 1
    def chart(cy, pts, color, title, sub):
        d.text((x0+60,cy),title,font=f(BOLD,40),fill=INK)
        d.text((x0+60,cy+52),sub,font=f(MONO,30),fill=SEC)
        gx=x0+60; gw=x1-x0-120; gy=cy+120; gh=380
        for gg in (0,0.5,1):
            d.line([(gx,gy+gh*gg),(gx+gw,gy+gh*gg)],fill=(228,228,232))
        px=[(gx+gw*i/(len(pts)-1), gy+gh*(1-v)) for i,v in enumerate(pts)]
        d.line(px,fill=color,width=6,joint="curve")
    chart(y0+380,[.2,.3,.28,.6,.5,.78,.66,.86,.7,.82],ACC,"Binding utilization","peak 91% · avg 54%")
    chart(y0+980,[.3,.42,.38,.55,.5,.66,.6,.78,.72],OK,"Cost","€12.34 this week · +8%")
    im.save(f"{OUT}/03-history.png"); print("03")

hero(); sessions(); history()
print("done ->", OUT)
