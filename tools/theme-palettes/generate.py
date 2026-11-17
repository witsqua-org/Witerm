"""Theme palettes for Witerm (Round 29).

Usage: python3 generate.py themes.json out.json

themes.json chooses each theme's chrome (canvas, surface, ink, secondary,
accent, actionLabel) for light and dark, the six ANSI hues in OKLCH degrees,
their chroma, and a gray hue. For every ANSI color this finds the lightness
nearest the canvas that reaches its contrast target on it (light: 4.9 normal,
5.9 bright; dark: 6.2 and 9.5), with as much chroma as sRGB allows there.
It also checks the chrome: ink 13:1, secondary and accent 4.5:1 on canvas and
surface, the button label 4.5:1 on the accent, and Warning, Positive and the
ten machine identity hues 4.5:1 on canvas and surface. Graphite's terminal
keeps its hand-tuned Round 16 palette in AppTheme.swift.
"""
import math, json, sys

def lin(c): c/=255; return c/12.92 if c<=0.04045 else ((c+0.055)/1.055)**2.4
def lum(h): r,g,b=(h>>16)&255,(h>>8)&255,h&255; return 0.2126*lin(r)+0.7152*lin(g)+0.0722*lin(b)
def cr(a,b): x,y=lum(a),lum(b); return (max(x,y)+0.05)/(min(x,y)+0.05)

def oklch_to_hex(L,C,H):
    a=C*math.cos(math.radians(H)); b=C*math.sin(math.radians(H))
    l_=L+0.3963377774*a+0.2158037573*b; m_=L-0.1055613458*a-0.0638541728*b; s_=L-0.0894841775*a-1.2914855480*b
    l,m,s=l_**3,m_**3,s_**3
    r=4.0767416621*l-3.3077115913*m+0.2309699292*s
    g=-1.2684380046*l+2.6097574011*m-0.3413193965*s
    bb=-0.0041960863*l-0.7034186147*m+1.7076147010*s
    def enc(x):
        if x<-1e-4 or x>1+1e-4: return None
        x=min(max(x,0),1); v=12.92*x if x<=0.0031308 else 1.055*x**(1/2.4)-0.055
        return round(v*255)
    out=[enc(r),enc(g),enc(bb)]
    if None in out: return None
    return (out[0]<<16)|(out[1]<<8)|out[2]

def fit(H,C,bg,target,lighter):
    """The color nearest the background's lightness, of hue H, with as much
    chroma (up to C) as sRGB allows there, whose contrast reaches target."""
    Ls=[i/1000 for i in range(1001)]
    Ls = Ls if lighter else Ls[::-1]
    for L in Ls:
        h=None
        for k in range(40,-1,-1):
            h=oklch_to_hex(L,C*k/40,H)
            if h is not None: break
        if h is None: continue
        if (lum(h)>lum(bg))==lighter and cr(h,bg)>=target: return h
    raise SystemExit(f"no fit {H} {C} {hex(bg)} {target}")

HUES=dict(red=0,green=1,yellow=2,blue=3,magenta=4,cyan=5)
def terminal(bg,fg,hues,C,dark,dim,gray,bright_white):
    order=['red','green','yellow','blue','magenta','cyan']
    if dark:
        normal=[fit(hues[k],C,bg,6.2,True) for k in order]
        bright=[fit(hues[k],C*0.85,bg,9.5,True) for k in order]
        return [dim]+normal+[fit(gray[0],gray[1],bg,10,True)]+[gray_dark8(bg,gray)]+bright+[bright_white]
    normal=[fit(hues[k],C,bg,4.9,False) for k in order]
    bright=[fit(hues[k],C*1.05,bg,5.9,False) for k in order]
    seven=fit(gray[0],gray[1],bg,2.6,False)
    fifteen=fit(gray[0],gray[1],bg,2.1,False)
    return [fg]+normal+[seven]+[fit(gray[0],gray[1],bg,5.2,False)]+bright+[fifteen]

def gray_dark8(bg,gray): return fit(gray[0],gray[1],bg,3.6,True)

T = json.load(open(sys.argv[1]))
res={}
fail=[]
WARN={'light':0xA04D00,'dark':0xFFB340}; POS={'light':0x157043,'dark':0x5BD68A}
ID_LIGHT=[0xC2264F,0x0B7A57,0x8F6100,0x2F55D4,0x426B0A,0xA8288F,0x0B6FA8,0xB8441A,0x7A3FD6,0x7A6630]
ID_DARK=[0xFF6B8B,0x4FE3B0,0xFFC24B,0x7AA2FF,0xB7F05A,0xF37BE0,0x5CC8FF,0xFF8A5B,0xB58CFF,0xD9C38F]
for name,t in T.items():
    out={}
    for mode in ['light','dark']:
        c={k:int(v,16) for k,v in t[mode].items()}
        dark=mode=='dark'
        for s in ['canvas','surface']:
            for k,mn in [('ink',13),('secondary',4.5),('accent',4.5)]:
                if cr(c[k],c[s])<mn: fail.append(f"{name} {mode} {k} on {s} {cr(c[k],c[s]):.2f}")
            for k,v in [('warning',WARN[mode]),('positive',POS[mode])]:
                if cr(v,c[s])<4.5: fail.append(f"{name} {mode} {k} on {s} {cr(v,c[s]):.2f}")
            for i,v in enumerate(ID_DARK if dark else ID_LIGHT):
                if cr(v,c[s])<4.5: fail.append(f"{name} {mode} hue{i} on {s} {cr(v,c[s]):.2f}")
        if cr(c['actionLabel'],c['accent'])<4.5: fail.append(f"{name} {mode} label {cr(c['actionLabel'],c['accent']):.2f}")
        tbg=c.get('termBackground',c['canvas']); tfg=c['ink']
        ansi = terminal(tbg,tfg,t['hues'],t['chroma'],dark,c.get('dim',0),t['gray'],c.get('white',0xFFFFFF)) if 'ansi' not in t.get(mode+'_fixed',{}) else None
        if dark: ansi[0]=fit(t['gray'][0],t['gray'][1],tbg,2.2,True)
        out[mode]=dict(chrome={k:f"{v:06X}" for k,v in c.items()},bg=f"{tbg:06X}",fg=f"{tfg:06X}",ansi=[f"{a:06X}" for a in ansi])
    res[name]=out
print("\n".join(fail) or "all contrast checks pass")
json.dump(res,open(sys.argv[2],'w'),indent=1)
