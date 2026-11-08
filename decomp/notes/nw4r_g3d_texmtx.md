# NW4R g3d — texture matrices, env maps, light channels (main.dol, HAFE v7)

Functional decomp of the library paths that set up the earth.brres material state.
All addresses are main.dol. "m2c" = machine pseudo-C; formulas below were checked against raw asm
where m2c failed (cr1 compares in fn_800A5040).

## Address map

| addr | guessed name | notes |
|---|---|---|
| fn_800A88E4 | `g3d::Draw1Mat1ShpDirectly(ResMat, ResShp, viewPos*, viewNrm*, u32 ctrl, Swap*, DrawCtx*)` | per material/shape draw: loads all material DL parts, then chan, texsrt, shape |
| fn_800A7388 | `LoadResTexSrt` (texture-matrix loader) | 8 slots → GXLoadTexMtxImm(m, GX_PTTEXMTX0+3i, GX_MTX3x4) |
| fn_800AAD34 | `CalcTexMtx(MTX34* m, bool set, TexSrt*, u32 srtFlag, TexMatrixMode)` | dispatches on mode |
| fn_800AEE14 / fn_800AF9B0 / fn_800B0610 | CalcTexMtx_Maya / _XSI / _3dsMax | each has a 7-entry table [set] and [concat] by `(srtFlag>>1)&7` |
| fn_800A85E8 | static ctor of G3DState (`lbl_80291020`) | registers the texmap-effect handler table at `lbl_80291020+0x240` = `lbl_80291260` |
| fn_800A5040 | `CalcEnvMtx` (env camera / env light) | handler for mapMode 1 **and** 3 |
| fn_800A5424 | `CalcProjMtx` | handler for mapMode 2 |
| fn_800A5550 | `CalcEnvSpecMtx` | handler for mapMode 4 (half-angle; unused by earth) |
| fn_800A599C | identity handler (tail-calls PSMTXIdentity) | mapMode 0 and 5..255 |
| fn_800A77D8 | `DrawResShp` matrix setup | pos/nrm mtx + **pre**-texmatrix per texgen + CP/XF matrix index regs |
| fn_800A4E1C | load 3x3 normal mtx as 3x4 (t=0) into GX_TEXMTXn | |
| fn_800A4D44 / fn_800A4DA0 | write CP 0x30/0x40 + XF 0x1018/0x1019 matrix indices (all identity / per-texgen) | |
| fn_800A6BCC | `SetupResChan(ResChan, lightMask0c,0a,1c,1a, ambColor, disableLighting)` | XF 0x100A..0x1010 |
| fn_800A7E18 → fn_800A5B5C | `G3DState::GetLightSet(idx, &mask×4, &amb)` | LightSet → GX light masks + ambient |
| fn_800A5A68 | `G3DState::SetLightSetting(LightSetting&)` | copy + view transform |
| fn_800B5A24 | `LightSetting::ApplyViewMtx(MTX34 view, n)` | lights to **view space** |
| fn_800A7E74 | `G3DState::SetCameraProjMtx(Camera, idx, bool makeCurrent)` | fills camera block |
| fn_800ADC0C | `Camera::GetEnvironmentTexMtx(MTX34*)` | |
| fn_800AD504 | `Camera::Init(...)` | env/proj tex defaults 0.5 |
| fn_800A7DE8 | `G3DState::GetLightObj(idx)` | `&lbl_80292074[idx*0x44 + 0x2C]` |
| fn_80101A7C | `GXLoadTexMtxImm(mtx, id, type)` | id<0x40 → XF id*4; else 0x500+(id-64)*4 |
| fn_800F86E0 | PSMTXIdentity | |
| fn_800F870C | PSMTXCopy(src, dst) | |
| fn_800F8740 | PSMTXConcat(a, b, ab)  → ab = a·b | |
| fn_800F89A4 | PSMTXInverse(src, dst) | (reads translation → full inverse, not InvXpose) |
| fn_800D80E4 | `VEC3TransformNormal(dst, m, src)` | 3x3 part only |
| fn_800D7DB8 | `MTX34InvTranspose → MTX33` (returns 0 on singular) | |
| fn_800F94EC / fn_800F9594 / fn_800F95D0 | VECNormalize / VECCrossProduct(a,b,axb) / VECHalfAngle | |
| fn_800D7B58 | `math::SinCosFIdx(f32* s, f32* c, f32 fidx)` | 256 units per turn (deg × 0.7111111 = 256/360) |
| fn_800FDE7C / EA8 / E8C / EC4 | GXInitLightPos / GXInitLightDir(stores −n) / GXGetLightPos / GXGetLightDir(returns −stored) | GXLightObj: pos @0x28, dir @0x34 |
| fn_800FDC04 / fn_800FDC14 / fn_800FDEEC | GXInitLightAttnA / GXInitLightAttnK / GXInitSpecularDir | |
| __GXInitRevisionBits | writes XF 0x1012 (dualTex) = 1 | **dual-tex is permanently on** |

## Data layouts

ResMat offsets used (material start = ResMat):
- `+0x1C` ResGenMode-ish bytes: `[0]` alpha flag, `[1]` **lightSetIdx (s8)**, `[2]` fogIdx (s8). Earth: `01 FF 00` → lightSet = −1.
- `+0x1A4` **ResTexSrtData**:
  - `+0x00 u32 flag` — 4 bits per texture i at `flag >> 4i`: bit0 = srt present/enable, bit1 = scale==1, bit2 = rot==0, bit3 = trans==0. Nibble 0xF = identity.
  - `+0x04 u32 texMtxMode` (0 Maya, 1 XSI, 2 3dsMax)
  - `+0x08 + 0x14*i` TexSrt `{f32 Sx, Sy, Rdeg, Tx, Ty}`
  - `+0xA8 + 0x34*i` TexMtxEffect `{s8 camRef, s8 lightRef, u8 mapMode, u8 flag(bit0 = effectMtx is identity), MTX34 effectMtx}`
- `+0x3EC` **ResChanData**: chan0 `{u32 flag, GXColor mat, GXColor amb, u32 xfColorCtrl, u32 xfAlphaCtrl}`, chan1 follows (+0x14).
  flag bits: 0x1 matColor(rgb) 0x2 matColor(a) 0x4 amb(rgb) 0x8 amb(a) 0x10 colorCtrl 0x20 alphaCtrl. (Any of 1|2 writes full RGBA; same for 4|8.)

G3DState (`lbl_80291020`, ctor fn_800A85E8):
- `+0x210` (= `lbl_80291230`) `u32 texGenKind[8]` set by LoadResTexSrt: 0 none, 1 env (modes 1,3,4), 2 projection (mode 2)
- `+0x230` (= `lbl_80291250`) `{MTX34* posArr; MTX33* nrmArr; MTX34* texArr}` (fn_800A7B20; also GXSetArray 0x15/0x16/0x17)
- `+0x240` (= `lbl_80291260`) handler table `struct {void (*fn)(MTX34*, s8 camRef, s8 lightRef); u32 kind;}[256]`:
  `[0]={ident,0} [1]={CalcEnvMtx,1} [2]={CalcProjMtx,2} [3]={CalcEnvMtx,1} [4]={CalcEnvSpecMtx,1} [5..255]={ident,0}`

Camera block (`lbl_80294AA0`, init fn_800A5F54):
- `+0x0 u16 flags` (bit0: cached inverse valid), `+0x2 u16 curCam`
- `+0x4 MTX34 invView` = PSMTXInverse(view[curCam]) (lazy, flag bit0)
- `+0x34 + 0x30*i` view (camera) mtx[32]; `+0x634 + 0x40*i` proj Mtx44[32]; `+0xE34 + 0x30*i` projectionTexMtx[32]; `+0x1434 + 0x30*i` environmentTexMtx[32]

Light array (`lbl_80292074`): LightObj[128], stride 0x44, `+0x2C u32 flag` then `+0x30 GXLightObj` (0x40).
LightObj flag: 0x4 = enabled; 0x1 set (and 0x2 cleared) by InitLightDir / InitLightAttnA / InitLightAttnK (spot-style light);
0x2 cleared by InitLightPos; 0x8 = specular (ApplyViewMtx uses GXInitSpecularDir).
**Stored in view space** of the current camera (fn_800B5A24: `dir = R·dir`, `pos = V·pos` incl. translation).

## Pseudo-C

### LoadResTexSrt — fn_800A7388 (called with ResTexSrtData = mat+0x1A4)
```c
static u32 s_identLoaded;            // lbl_803310D8
for (i = 0; i < 8; i++) {
  if (!(texSrt->flag & (1 << 4*i))) { texGenKind[i] = 0; continue; }   // bit0 of nibble
  TexMtxEffect* e = &texSrt->effect[i];
  MTX34 m; PSMTXIdentity(m); bool isIdent = true;
  if (e->mapMode != 0) {
    u8 mode = e->mapMode < 0x100 ? e->mapMode : 0;
    s8 cam = e->camRef < 0x20 ? e->camRef : -1;
    s8 lt  = e->lightRef < 0x80 ? e->lightRef : -1;   // (raw u8 0xFF → -1)
    s_tbl[mode].fn(m, cam, lt);
    texGenKind[i] = s_tbl[mode].kind;
    isIdent = false;
  } else texGenKind[i] = 0;

  u32 nib = (texSrt->flag >> 4*i) & 0xF;
  if (!(nib == 0xF && (e->flag & 1))) {               // not (SRT identity && effect identity)
    if (isIdent) { if (!(e->flag & 1)) { PSMTXCopy(e->effectMtx, m); isIdent = false; } }
    else           PSMTXConcat(e->effectMtx, m, m);   // m = Effect · Env
    if (e->mapMode == 0)
      CalcTexMtx(m, isIdent, &texSrt->srt[i], nib, texSrt->texMtxMode);   // set or pre-multiply
    else {
      MTX34 s; CalcTexMtx(s, true, &texSrt->srt[i], nib, texSrt->texMtxMode);
      swap(s[0][2], s[0][3]); swap(s[1][2], s[1][3]);  // move translation to the q column
      PSMTXConcat(s, m, m);                            // m = SRT' · Effect · Env
    }
    isIdent = false;
  }
  if (isIdent) { if (!(s_identLoaded & 1<<i)) { s_identLoaded |= 1<<i; MTX34 I; PSMTXIdentity(I); GXLoadTexMtxImm(I, 64+3*i, GX_MTX3x4); } }
  else { s_identLoaded &= ~(1<<i); GXLoadTexMtxImm(m, 64+3*i, GX_MTX3x4); }   // GX_PTTEXMTX0 + 3i
}
```
Post-texmatrix slot for layer i is always **PTTEXMTX0+3i (XF post index 3i)** — matches earth texgen PostMtxInfo 0x000/0x103/0x006/0x109.

### CalcTexMtx — fn_800AAD34
```c
bool changed = (mode==0 ? Maya : mode==1 ? XSI : Max)(m, set, srt, nib);
if (!changed && set) PSMTXIdentity(m);
// each X(m,set,srt,nib): k = (nib>>1)&7; if (k==7) return false;
//   (set ? tblSet[k] : tblConcat[k])(m, srt); m[2] = {0,0,1,0}; return true;
```
Row 2 is always `(0,0,1,0)`. `set` writes the matrix; `concat` pre-multiplies the existing m (m = S·m).

3dsMax (mode 2), full SRT (k=0, fn_800AFF00), with `(s,c) = SinCosFIdx(R*256/360)`:
```
m00 = Sx·c     m01 = Sx·s    m02 = 0   m03 = 0.5 + (−Sx·c·(0.5+Tx) + Sx·s·(Ty−0.5))
m10 = −Sy·s    m11 = Sy·c    m12 = 0   m13 = 0.5 + ( Sy·s·(0.5+Tx) + Sy·c·(Ty−0.5))
```
3dsMax scale-only (k=6: rot=0, trans=0), set (fn_800AFBFC) / concat (fn_800AFFCC):
```
set:    m = [[Sx,0,0, 0.5(1−Sx)], [0,Sy,0, 0.5(1−Sy)], [0,0,1,0]]
concat: row0 = Sx·row0, m03 = 0.5 + Sx·(m03−0.5); row1 = Sy·row1, m13 = 0.5 + Sy·(m13−0.5)
```
(i.e. scale about the texture centre (0.5,0.5)).

Maya (mode 0) full (fn_800AE644), from m2c (verify signs before relying on it — earth doesn't use it):
```
m00 = Sx·c   m01 = Sx·s   m03 = Sx·(−0.5c − (0.5s − 0.5) − Tx)
m10 = −Sy·s  m11 = Sy·c   m13 = 1 + Sy·(Ty + (−0.5c + 0.5s − 0.5))
```
XSI (mode 1) full (fn_800AF2F0), from m2c:
```
m00 = Sx·c   m01 = −Sx·s  m03 = Sx·s − Sx·c·Tx − Sx·s·Ty
m10 = Sy·s   m11 = Sy·c   m13 = 1 − Sy·c − Sy·s·Tx + Sy·c·Ty
```

### CalcEnvMtx — fn_800A5040 (mapMode 1 env-camera and 3 env-light)
```c
void CalcEnvMtx(MTX34* m, s8 camRef, s8 lightRef) {
  if (camRef >= 0 && camRef < 32) {                 // env camera, explicit camera
    m = view[camRef] · invView;  m[*][3] = 0;
    m = envTexMtx[curCam] · m;  return;
  }
  if (lightRef >= 0 && lightRef < 128 && (light[lightRef].flag & 4)) {  // env light
    VEC3 v = GXGetLightDir(light);                   // view space
    bool usePos = !(flag & 1) && !(flag & 2);
    if (usePos || v == 0) {
      v = GXGetLightPos(light);                     // view space
      v = -VEC3TransformNormal(invView, v);          // rotation only!
      if (v == 0) v = (0, -1, 0);
    } else v = VEC3TransformNormal(invView, v);
    v = normalize(v);
    VEC3 up = (|v.x| < 1e-6 && |v.z| < 1e-6) ? (0, 0, v.y > 0 ? 1 : -1) : (0, 1, 0);
    VEC3 r = normalize(cross(v, up));
    VEC3 u = cross(r, v);
    m = [ r ; u ; -v ] (3x3, t = 0);
    m = m · invView;  m[*][3] = 0;
    m = C · m;   // C = lbl_801956E8 = [[.5,0,0,.5],[0,-.5,0,.5],[0,0,0,1]]
    return;
  }
  m = envTexMtx[curCam];      // default: plain camera sphere map
}
```
`envTexMtx[cam]` = Camera::GetEnvironmentTexMtx (fn_800ADC0C) = `[[sS,0,0,tS],[0,−sT,0,tT],[0,0,0,1]]`
from CameraData +0xCC sS, +0xD0 sT, +0xD4 tS, +0xD8 tT. Camera::Init (fn_800AD504) sets all four to **0.5**,
and nothing else in main.dol writes them → `envTexMtx == C`. (Camera::Init also defaults fovy 60, aspect 4/3, near 0.1, far 1000.)

Position-light quirk: `−R⁻¹·p_view = camPos_world − lightPos_world` (translation of invView is dropped), so a
positional light's env direction is the vector **light → camera**, not light → origin.

### CalcProjMtx — fn_800A5424 (mapMode 2)
```c
if (camRef valid) { m = view[camRef] · invView; m = projTexMtx[camRef] · m; }
else m = projTexMtx[curCam];
```
### CalcEnvSpecMtx — fn_800A5550 (mapMode 4): same structure as env-light but builds the basis from
VECHalfAngle(camera dir, light dir), then `C`/envTexMtx; not used by earth.

### Pre-texmatrix (shape draw) — fn_800A77D8
For each texgen i (0..7), from `texGenKind[i]`:
- 1 (env): `idx = GX_TEXMTX0 + 3i (= 30+3i)`; load **normal matrix** of the shape's matrix (`nrmArr[mtxId]` if provided,
  else `MTX33 = InvTranspose(posMtx)`, identity if singular) as 3x4 with zero translation via GXLoadTexMtxImm(idx).
- 2 (proj): `idx = GX_PNMTX0 (0)` (the model-view position matrix).
- 0: `idx = GX_IDENTITY (60)`.
Indices go to CP 0x30/0x40 + XF 0x1018/0x1019 (fn_800A4DA0); if no env/proj texgen, all-identity (0x3CF3CF00 / 0x00F3CF3C) (fn_800A4D44, cached).

### Light channels — fn_800A6BCC, LightSet fn_800A5B5C
```c
(mask0c, mask0a, mask1c, mask1a, amb) = G3DState::GetLightSet(mat->lightSetIdx /* mat+0x1D */);
//   idx out of [0,128) → masks = 0, amb = {FF,FF,FF,FF}
//   else masks = bitmask of enabled LightObjs of the set mapped onto GX light slots 0..7 (allocated/cached), amb = ambient light color
if (chan.flag & 3) XF[0x100C] = chan.mat;
XF[0x100A] = round(chan.amb[k] * amb[k] / 255)  for each RGBA k   (if chan.flag & 0xC)
if (chan.flag & 0x10) XF[0x100E] = (chan.colorCtrl & keep) | (mask0c & 0xF) << 2 | (mask0c >> 4) << 11;
if (chan.flag & 0x20) XF[0x1010] = (chan.alphaCtrl & keep) | same with mask0a;
//   keep = ~0x783C normally; ~0x783E (also clears bit1 LIGHTING_ENABLE) when draw ctrl bit3 set
// chan1 (XF 0x100D/0x100B/0x100F/0x1011) same, only if numChans == 2
```
So yes, the LightSet overrides the **light mask** and modulates the **ambient** at runtime; mat color, mat/amb source,
diffuse fn and attn come from the ResMat. Earth: lightSet = −1 → masks 0, amb = material amb `66 66 66 FF` unchanged,
color/alpha ctrl 0x700 (lighting disabled) → channel = matColor FFFFFFFF. (Earth's TEV uses ras chan "zero" anyway.)

## Final formulas for the earth material (layers 0–3)

Notation: `n` = model-space normal; `N` = 3x3 inverse-transpose of model-view; `n_v = normalize(N·n)` (texgen normalize bit);
`V` = current camera view matrix, `R = 3x3(V⁻¹)`; GX texgen output = PostMtx · (n_v, 1) for normal sources (STQ, q = row2).

| layer | tex | mapMode / refs | pre | post matrix P |
|---|---|---|---|---|
| 0 | earth_xx | 0 | identity (texcoord0) | identity (nibble F) |
| 1 | emboss_lighting | 3 env-light, light 0 | N (TEXMTX 33) | `S(0.95) · C · L · R` |
| 2 | earth_xx_emboss | 0 | identity (texcoord0) | `S(0.9785)` |
| 3 | emboss_edge_mask | 1 env-camera, camRef −1 | N (TEXMTX 39) | `C` |

with `S(k)` (3dsMax scale-only, translation moved to col 2 for env layers — equivalent result):
```
uv' = 0.5 + k·(uv − 0.5)
```
Layer 1, written out (L rows r,u,−v built from light 0 as in CalcEnvMtx, all in world space):
```
w = R·n_v                              // world-space normal
s = 0.5 + 0.95·( 0.5·dot(w, r))        = 0.5 + 0.475·dot(w, r)
t = 0.5 + 0.95·(−0.5·dot(w, u))        = 0.5 − 0.475·dot(w, u)
q = 1
```
If light 0 is not enabled (flag & 4 == 0) layer 1 falls back to the camera sphere map: `s = 0.5+0.475·n_v.x, t = 0.5−0.475·n_v.y`.
Layer 3:
```
s = 0.5 + 0.5·n_v.x,  t = 0.5 − 0.5·n_v.y,  q = 1     (view-space normal; rim → edge of mask)
```
Layer 2: `uv = 0.5 + 0.9785·(uv0 − 0.5)` (emboss/indirect map slightly zoomed about the tile centre).

## Open questions
- Who fills G3DState light slot 0 for the globe (LightSetting → fn_800A5A68 → fn_800B5A24) and with what
  pos/dir/flags — that is game code (d_scene / SimpleGlobe; the other decomp track). Whether flag bit0/bit1 is set decides
  dir vs. (light→camera) position path.
- Exact draw `ctrl` bits passed to fn_800A88E4 for the globe (bit3 forces lighting off; irrelevant for earth since ctrl 0x700 is unlit).
- Maya/XSI formulas were transcribed from m2c only.
- CalcEnvSpecMtx details not decompiled beyond structure.
