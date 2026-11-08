# Globe — functional decomp (main.dol, HAFE v7)

Sources: `decomp/build/m2c/globe_cls.c`, `globe_cam.c`, `globe_callers.c`, `input.c` (raw m2c), asm in `build/HAFE/asm`.
Helpers: `scripts/dec.py <fn..>` (m2c + constant substitution), `scripts/dump_const.py`, `scripts/callgraph.py [--range lo hi | fn..]`, `scripts/dolmem.py`.
All constants below were read from the DOL. Angles are **degrees** unless noted. The screen is 608×456 (4:3) or 832×456 (16:9 when `g_isWide` `lbl_80330B34` != 0).

---------------------------------------------------------------------------------------------------
## 0. Object graph

| global | type | made by | notes |
|---|---|---|---|
| `lbl_80330BEC` | `CSimpleGlobe*` (0xD0 bytes) "m_pSimpleGlobe" | `fn_8003B2C8` (d_scene.cpp, panics at line 488 if alloc fails) | driver for globe input/camera/material tweaks |
| `lbl_80330BF0` | `CEarthModel*` (0x64, vtable `lbl_8019B968`) | `fn_8003C120` once earth.brres is decompressed | wraps ResFile/ResMdl/ScnMdl |
| `CSimpleGlobe::m_camera` | `CGlobeCamera*` (0xEC, vtable `lbl_8019B750`) | `fn_8003F628` | wraps g3d camera 0 |
| `lbl_801D7320` | `KPADStatus[4][16]` (0x84 each) | `fn_8002F9CC` (input update) | |
| `lbl_801D9730[4]` / `lbl_801D9740[4]` | smoothed pointer X / Y per channel (pixels) | `fn_8002F9CC` | |
| `lbl_801D97B0[4]` / `lbl_801D97C0[4]` / `lbl_801D97D0[4]` | KPAD hold / trig / release (newest valid sample) | `fn_8002F9CC` | |
| `lbl_80330B1C` | trigger buttons (used for globe d-pad/+/-) | input | |
| `lbl_80330C2C` | rotation sound handle | static init `fn_80041670` | |
| `lbl_80330C30` | light colour RGBA = FF FF FF FF | `fn_80041670` | |
| `lbl_801F6B28` | scratch `Mtx` shared by all globe math | | |

### Earth loading (d_scene.cpp)
`fn_8003D6D0`: CNTOpen `/earth.brres.LZ` (`lbl_803301CC`), allocate decompressed size (rounded to 32), start a worker thread (`fn_8003B0A4(fn_8003D85C)`, 0x4318-byte object) that runs CXReadUncompLZ in 0x10000-byte chunks. When the data is ready (`lbl_80330BE8` = ResFile, `lbl_80330BBB` = 1), `fn_8003C120` constructs `CEarthModel` (`fn_8002CEE0`): ResFile init+Bind, `GetResMdl(0)`, `ScnMdl::Construct(alloc, &size, resMdl, bufferOption=1)`.
The port can simply load the decompressed brres synchronously.

---------------------------------------------------------------------------------------------------
## 1. Class layouts

### CSimpleGlobe (0xD0) — ctor `fn_8003F628`
| off | type | name | init / meaning |
|---|---|---|---|
| 0x00 | ScnRoot* | scnRoot | `fn_800B1B38(alloc,&sz, 0x1F, 0x100, 0x80, 0x80)` ≈ g3d::ConstructScnRoot(maxChildren 31, maxScnObj 256, numLightObj 128, numLightSet 128) |
| 0x04 | CGlobeCamera* | camera | `new(0xEC) CGlobeCamera(scnRoot->GetCurrentCamera())` |
| 0x08 | Vec3 | homeLatLon | (lat, lon, 0) from Reset |
| 0x14 | Vec3 | northPole | (0, 3, 0) |
| 0x20 | Vec3 | southPole | (0, -3, 0) |
| 0x2C | struct{f32 lat, lon}[4] | grabStartAngles | camera lat/lon when A was pressed, per KPAD channel |
| 0x4C | struct{f32 x, y}[4] | grabStartPointer | pointer px when A was pressed |
| 0x6C | f32 | velLat | inertia, deg/frame |
| 0x70 | f32 | velLon | inertia, deg/frame |
| 0x74,0x78 | — | unused (0) | |
| 0x7C | Vec2 | northPoleScreen | |
| 0x84 | Vec2 | southPoleScreen | |
| 0x8C | u8[4] | grabbing[chan] | |
| 0x90 | u8 | inertiaActive | |
| 0x91 | u8 | reqZoomOut | (index+1 = farther) |
| 0x92 | u8 | reqZoomIn | |
| 0x93 | u8 | reqTiltUp | |
| 0x94 | u8 | reqTiltDown | |
| 0x95 | u8 | levelLatitude | glide lat→0 after a tilt reset when zoomIdx≥8 |
| 0x96 | u8 | nPoleBehindView: dot(N̂, look̂) < 0 | |
| 0x97 | u8 | nPoleFacing: dot(N̂, normalize(N − eye)) < 0 | |
| 0x98 | u8 | sPoleBehindView | |
| 0x99 | u8 | sPoleFacing | |
| 0x9A | u8 | nPoleBehindCam: dot(look̂, normalize(N−eye)) < 0 | |
| 0x9B | u8 | sPoleBehindCam | |
| 0x9C | s32 | zoomIdx 0..9 | |
| 0xA0 | s32 | tiltIdx 0..5 | |
| 0xA4 | f32[4] | grabStartTwist[chan] | |
| 0xB4 | f32 | distCur | |
| 0xB8 | f32 | distTarget | |
| 0xBC | f32 | pitchCur | |
| 0xC0 | f32 | pitchTarget | |
| 0xC4 | f32 | grabStartHeading | camera twist (0xA4) when A was pressed |
| 0xC8 | f32 | dist (mirror of camera->dist) | |
| 0xCC | f32 | lonDragSign ±1 | |

### CGlobeCamera (0xEC) — ctor `fn_8002B734`, vtable `lbl_8019B750`
| off | type | name | init |
|---|---|---|---|
| 0x00 | vtbl | | |
| 0x04 | g3d::Camera | cam | camera 0 |
| 0x08 | Mtx34 | viewMtx | identity (then GetCameraMtx) |
| 0x38 | Mtx44 | projMtx | identity (then GetProjectionMtx) |
| 0x78 | Vec3 | up | (0,1,0) (recomputed per frame, see quirk) |
| 0x84 | Vec3 | target | point on the sphere |
| 0x90 | f32 | lat | |
| 0x94 | f32 | lon | |
| 0x98 | f32 | surfaceRoll | always 0 in practice |
| 0x9C | f32 | pitch (tilt) | |
| 0xA0 | f32 | yaw | |
| 0xA4 | f32 | twist / heading (Wii Remote roll) | |
| 0xA8 | Vec3 | eye | |
| 0xB4 | Vec3 | look = target − eye | |
| 0xC0 | u8 | orienting (pitch/yaw/twist easing active) | |
| 0xC4 | f32 | fovy | **5.0** |
| 0xC8 | f32 | aspect | 608/456 (1.3333) or 832/456 (1.8246) |
| 0xCC | f32 | near | **0.1** |
| 0xD0 | f32 | far | **200.0** |
| 0xD4 | f32 | dist (eye→target) | 100.0 |
| 0xD8..0xE4 | f32×4 | viewport centre x, y, half-w, half-h (×832/608 when wide) | from GetViewport |

### CEarthModel (0x64) — ctor `fn_8002CEE0`, vtable `lbl_8019B968`
0x08 ResMdl, 0x0C ScnMdl*, 0x10 Mtx34 world, 0x40 Vec3 trans (0), 0x4C Vec3 rot (0), 0x58 Vec3 scale (21,21,21; unused by the code here).
`fn_8002D004` → `fn_8002D0AC`: world = RotYFIdx(rot.y·256/360) · Rot(rot.x, 0, rot.z) · Trans(trans) → `ScnMdl::SetMtx` (`fn_800B0A60`). Every field is 0, so world = identity. Draw (`fn_8003FBFC` → `fn_8002D1A0`) is an empty stub; the ScnRoot draws the model.

---------------------------------------------------------------------------------------------------
## 2. Functions (cleaned pseudo-C, real constants)

### Shared math helpers (game code)
```c
// fn_8003DFB0  ConvLatLon16ToDeg — weather data stores angles as 16-bit binary angles
out.lat = (f32)(s16)lat16 * 0.005493164f;   // 360/65536
out.lon = (f32)(u16)lon16 * 0.005493164f;
// fn_80036834/80036880/800368CC  MtxPreRot{X,Y,Z}Deg(Mtx m, f32 deg): m = R_axis(deg) * m   (PSMTXRotRad + PSMTXConcat(R, m, m))
// fn_80036968  MtxRotZDeg(Mtx m, deg)          (PSMTXRotRad(m,'z',deg*π/180))
// fn_80035E1C  ChaseValue(f32* v, f32 target, f32 rate, f32 maxStep, f32 minStep) -> remaining |v-target|
d = *v - target;
if (*v != target) {
  if (|d| < minStep) *v = target;
  else { step = d*rate; if (|d*rate| ≈ 0 (±0.0008)) *v = target;
         else { if (|d|*rate > maxStep) step = sign(step)*maxStep; else if (|d|*rate < minStep) step = sign(step)*minStep;
                *v -= step; } }
}
return |*v - target|;
// fn_80035ED0  ChaseAngle(f32* a, f32 target, f32 rate, f32 maxStep, f32 snapEps): same, with both wrapped to [0,360) and
//   the delta wrapped to [-180,180]; snaps when |delta*rate| <= snapEps; result rewrapped to [0,360).
// fn_8002BE14  ApproachAngle(f32* a, f32 target): d = wrap180(target-*a); if |d|<0.008 || |d*0.05|<0.008 → *a=target;
//   else *a += d*0.05, wrap to [0,360).
```

### CGlobeCamera
```c
// fn_8002B734 ctor — see layout. aspect = (wide?832:608)/456.
// fn_8002B8D4 Init(Vec3* latLonRoll)
cam.SetPerspective(fovy=5, aspect, near=0.1, far=200);
cam.SetScissor(0,0, rmode.fbWidth, rmode.efbHeight);  cam.SetViewport(0,0, fbWidth, efbHeight);
if (latLonRoll) { lat = v.x; lon = v.y; surfaceRoll = v.z; }

// fn_8002B9B0 Calc  (once per frame, from SimpleGlobe::CalcCamera)
M  = Trans(0,0,3);  PreRotX(M,-lat); PreRotZ(M,surfaceRoll); PreRotY(M,lon);   // M = Ry(lon)·Rz(roll)·Rx(-lat)·T(0,0,3)
target = M.translation;                                                      // point on the radius-3 sphere
saved = M;
M  = Trans(0,0,dist); PreRotX(M,pitch); PreRotZ(M,twist); PreRotY(M,yaw);    // M = Ry(yaw)·Rz(twist)·Rx(pitch)·T(0,0,dist)
M  = saved · M;
eye = M.translation;
up  = PSMTXMultVec(M, (0,1,0));     // QUIRK: full MultVec, so the translation is included: up = eye + R·ŷ
cam.SetPosition(eye);
look = target - eye;
cam.SetPosture({type=LOOKAT, up, target});
viewMtx = cam.GetCameraMtx(); projMtx = cam.GetProjectionMtx();
cam.GetViewport(&vx,&vy,&vw,&vh,…); halfW=vw*0.5; halfH=vh*0.5; cx=vx+halfW; cy=vy+halfH;
if (wide) { cx *= 1.3684211f; halfW *= 1.3684211f; }   // 832/608
```
The lookat normalises up, so the quirk only affects the up direction slightly when pitch/twist ≠ 0. Port it verbatim for fidelity (camera 1 in UpdateMaterials does zero the translation).

```c
// fn_8002BC28 StartOrient(f32 tgt[3] /*pitch,yaw,twist*/): orienting=1; step each with ApproachAngle; if all 3 arrived, orienting=0.
// fn_8002BD70 UpdateOrient(tgt): if orienting==1 { same }; return orienting.
// fn_8002BCC4 IsAtOrient(tgt): all |angle - tgt| < 0.0008.
// fn_8002BEF4 Project(Vec2* out, Vec3* world):  standard world→screen:
//   clip = proj · (view · world); ndc = clip.xy / clip.w;
//   out.x = cx + halfW·ndc.x;  out.y = cy − halfH·ndc.y     (cx,halfW additionally scaled by W/fbWidth)
```

### CSimpleGlobe
```c
// fn_8003F888 Reset(Vec3* latLon, int zoomIdx)       (also used on channel start: d_s_weather fn_8000EF08)
scnRoot: remove all children; insert earthModel.scnMdl;
reqZoomOut=reqZoomIn=reqTiltUp=reqTiltDown=0; grabbing[0..3]=0; inertiaActive=0; velLat=velLon=0;
homeLatLon = *latLon; zoomIdx = zoomIdx; distCur = distTarget = camera->dist = kZoomDist[zoomIdx];
camera->Init(&homeLatLon);                  // camera lat/lon = home city
cam1 = scnRoot->GetCamera(1);               // second ("light") camera
cam1.<fn_800AD504>(fbW, efbH, fbW, xfbH, wide?832:608, 456);   // render-mode/frame setup (exact g3d method unconfirmed)
cam1.SetPerspective(camera->fovy, aspect, near, far); cam1.SetScissor(0,0,fbW,efbH); cam1.SetViewport(0,0,fbW,efbH);

// fn_8003FA7C Init(Vec3* latLon)  — called when the globe screen is entered (fn_80017FC8 / fn_8001812C)
//   with latLon = home city (ConvLatLon16ToDeg) and zoomIdx = 0 set first via SetZoomIndex
Reset(latLon, zoomIdx);
LightSet ls = scnRoot->GetLightSetting().GetLightSet(0);
ls.SelectLightObj(0, 0); for (i=1..7) ls.SelectLightObj(i,-1); ls.SelectAmbLightObj(-1);   // one light, no ambient obj
LightObj& l = scnRoot->GetLightSetting().GetLightObj(0);
l.<fn_800B52C8>();                       // init/clear (probably InitLightSpot off / Clear)
l.InitLightColor({255,255,255,255});
l.InitLightAttnA(1,0,0); l.InitLightAttnK(1,0,0);    // no attenuation (fn_800B53A0 / fn_800B53E0)
l.flags |= 4;                                          // enable
GXSetCopyClear({0,0,0,255}, 0x00FFFFFF);              // black clear

// fn_8004006C UpdateLight (per frame, after camera calc): every light obj in light set 0:
//   InitLightPos(camera->eye); InitLightDir(camera->look)   → white "headlight" at the eye

// fn_8004012C CalcScene: scnRoot CalcWorld, CalcMaterial, CalcVtx, CalcView, GatherDrawScnObj, ZSort (6 g3d calls fn_800B1DC0..fn_800B22B4)
// fn_8003FC10 Draw: scnRoot DrawOpa (fn_800B2314); DrawXlu (fn_800B2388);
//   if (fadeAlpha `lbl_803301C4`, init 0xFF) draw a black quad (0,0)-(W,456) with that alpha  (fn_8002E79C)
// fn_8003FCD4 RebuildScene: same child reset as Reset() (no camera change); clears the four request flags.
// fn_8003FD7C CalcCamera: if (camera) { UpdateMaterials(); camera->Calc(); }
// fn_8003FDBC CalcPoles: (see flags 0x96..0x9B) + Project(northPole)->0x7C, Project(southPole)->0x84

// fn_80041074 SetZoomIndex(i): zoomIdx=i; distTarget=kZoomDist[i]
// fn_80041090 SetTwist(f): camera->twist = f
// fn_800402A4 SyncDist: dist = camera->dist
// fn_80040B08 SetTiltIndexImmediate(i): tiltIdx=i; pitchTarget=pitchCur=camera->pitch=kTilt[i]; camera->orienting=0
// fn_80040A48 SetTiltIndex(i, bool level): if (zoomIdx>=8) levelLatitude=level; tiltIdx=i; pitchTarget=kTilt[i];
//                                          camera->StartOrient(&kResetOrient)   (kResetOrient = `lbl_801D7264` = {pitch 0, yaw 0, twist 0}, filled in d_s_weather fn_8000E384)
// fn_80040A78 CanReset(): zoomIdx>=8 ? !(|camera->lat|<0.0008 && camera->IsAtOrient()) : !camera->IsAtOrient()

// fn_80040190 UpdateZoom(const int sndIds[10])
if (reqZoomOut) { zoomIdx=min(zoomIdx+1,9); distTarget=kZoomDist[zoomIdx]; if changed PlaySE(sndIds[zoomIdx]); }
else if (reqZoomIn) { zoomIdx=max(zoomIdx-1,0); …same… }
distCur = camera->dist; ChaseValue(&distCur, distTarget, 0.1, 100.0, 0.001); camera->dist = distCur; dist = camera->dist;
//  sndIds = lbl_801793A0 = {2,3,4,5,6,7,8,9,10,11}

// fn_80040B3C UpdateTilt(const int sndIds[6])         sndIds = lbl_801793C8 = {12..17}
moving = camera->UpdateOrient(&kResetOrient);
if (reqTiltUp==1)   { tiltIdx=min(tiltIdx+1,5); moving=1; pitchTarget=kTilt[tiltIdx]; camera->orienting=0; if changed PlaySE(sndIds[tiltIdx]); }
else if (reqTiltDown==1) { tiltIdx=max(tiltIdx-1,0); … }
if (!moving) { pitchCur=camera->pitch; ChaseValue(&pitchCur, pitchTarget, 0.1, 100, 0.001); camera->pitch=pitchCur; }
if (levelLatitude) { if |camera->lat|<0.0008 { levelLatitude=0; camera->lat=0; }
                     else if ChaseValue(&camera->lat, 0, 0.1, 100, 0.001)==0 → levelLatitude=0; }

// fn_800402BC TryBeginGrab(chan) -> bool        (only called when pointer y in (63,393) and not over a UI button)
if (!(kpadTrig[chan] & WPAD_A /*0x800*/)) return 0;
grabbing[chan]=1; grabbing[others]=0; camera->orienting=0; levelLatitude=0; inertiaActive=0;
grabStartAngles[chan] = {camera->lat, camera->lon};
grabStartPointer[chan] = {ptrX[chan], ptrY[chan]};
grabStartHeading = camera->twist;
grabStartTwist[chan] = Atan2FIdx(kpad[chan][0].horizon.x, -kpad[chan][0].horizon.y) * 1.40625f;   // FIdx→deg
lonDragSign = 1;
if (nPoleFacing && !nPoleBehindCam) { if (grabStartPointer.y < northPoleScreen.y) lonDragSign = -1; }
else if (sPoleFacing && !sPoleBehindCam) { if (grabStartPointer.y > southPoleScreen.y) lonDragSign = -1; }
return 1;

// fn_800405E4 UpdateGrab(chan) -> 0 idle, 1 dragging, 2 released
if (!camera) return 0;
s = 0.5f * (0.01f * dist);                  // drag gain grows with distance
if (!grabbing[chan]) return 0;
if (!(kpadHold[chan] & WPAD_A)) { grabbing[chan]=0; inertiaActive=1; return 2; }
dTwist = Atan2FIdx(hx,-hy)*1.40625f - grabStartTwist[chan];
if (|dTwist| > 30.0f) {                     // remote twisted → rotate the view instead of panning
   heading = wrap360(dTwist + grabStartHeading);
   camera->orienting=0; velLat=velLon=0;
} else {
   heading = grabStartHeading;
   prevLat=camera->lat; prevLon=camera->lon;
   v.x = s * (ptrY[chan] - grabStartPointer[chan].y);                // lat delta
   v.y = s * (ptrX[chan] - grabStartPointer[chan].x);                // lon delta
   if (|camera->twist| < 0.0008) v.y *= lonDragSign;
   v.z = 0;
   v = RotZDeg(camera->twist) * v;                                    // drag is screen-relative
   camera->lat = clamp(grabStartAngles[chan].lat + v.x, -89, 89);
   camera->lon = wrap180(grabStartAngles[chan].lon - v.y);            // while (<-180) +=360; while (>180) -=360
   velLat = camera->lat - prevLat;  velLon = wrap180(camera->lon - prevLon);
}
ChaseAngle(&camera->twist, heading, 0.1, 180, 1.0);
return 1;

// fn_80040D48 UpdateInertia(bool stop)      stop = (hoveredItem >= 0)
if (!camera) return; if (stop) inertiaActive=0; if (!inertiaActive) return;
camera->lat += velLat;
if (camera->lat > 89 || < -89) { clamp; velLat=0; if (|velLon|<1 && SE playing(rotSnd)) StopSE(rotSnd,0); }
camera->lon = wrap180(camera->lon + velLon);           // single wrap
f = kFriction[zoomIdx];
dLon = velLon*(1-f); velLon -= dLon; if |velLon|<0.0008 → 0;
if (|dLon| < 0.05) { velLat *= f; if |velLat|<0.0008 → 0; }
else if (|velLat| >= 0.0008) { velLat moves toward 0 by |dLon| (no overshoot); }
if (sqrt(velLat²+velLon²) < 0.001) { inertiaActive=0; velLat=velLon=0; }

// fn_800410A4 UpdateRotateSound(seId=0x14)
speed = sqrt(velLat²+velLon²); if (speed >= 1) {
  PlaySE(rotSnd, seId); SetVolume(min(speed/5,1)); SetPitch(min(speed/90,1)+0.5); SetPan(0); }

// fn_800411B4 UpdateMaterials (start of CalcCamera)
d = distCur;
embossK  = min(clamp01((100-d)/35), clamp01((d-2)/15));       // emboss strength: 0 at d<=2, 1 for 17..65, 0 at 100
edgeK    = clamp01((d-40)/20);
edgeScale= 0.85 + 0.15*edgeK;                                 // emboss_edge_mask tex scale
shadeK   = clamp01((d-2)/15);
// indirect matrix as mantissa*2^exp: e = exponent(1+embossK); m = embossK*2^-e (e=0 when embossK<=1e-18)
//  ---- camera 1 = the main camera offset by a quarter, used as env-map "light" ----
M = Trans(-0.75, 0.75, 3); PreRotX(M,-lat); PreRotZ(M,roll); PreRotY(M,lon); saved=M; t1=M.trans;
M = Trans(-0.25*dist, 0.25*dist, dist); PreRotX(M,pitch); PreRotZ(M,twist); PreRotY(M,yaw); M = saved·M;
eye1 = M.trans; M.trans = 0; up1 = M·(0,1,0);
cam1.SetPosition(eye1); cam1.SetPosture({LOOKAT, up1, t1});
for each material i in earth ResMdl except "luminous_mat":
   TevKColor0.a = (u8)(77 * shadeK);                          // ResMatTevColor (DL+0x20), then DCStore
   texSrt.SetMapMode(tex=1, mode=1 /*EnvCamera*/, camRef=1, lightRef=-1);  // file has tex1 = EnvLight(light 0); code switches it to cam1
   texSrt[3].scale = (edgeScale, edgeScale); texSrt.flag &= ~0x2000;   // tex3 = emboss_edge_mask
   IndMtx(GX_ITM_0) = [[m,0,0],[0,m,0]], scaleExp = e;        // ResMatIndMtx (DL+0xA0)
```

### Globe screen driver (d_weather_around.cpp?, fn_800186F0 = interactive state, per frame)
```c
reqZoom*/reqTilt* cleared (fn_8003FCD4 at state entry) …
if (LayoutButtonTrig("back",A))           { PlaySE(0x26); velLat=velLon=0; inertiaActive=0; → scene state 6 }
if (LayoutButtonHeld("zoom_out",A)) reqZoomOut=1; else if (trig & WPAD_MINUS 0x1000) { reqZoomOut=1; flash button }
if (LayoutButtonHeld("zoom_in",A))  reqZoomIn=1;  else if (trig & WPAD_PLUS  0x0010) { reqZoomIn=1; … }
if (LayoutButtonHeld("rot_a",A))    reqTiltUp=1;  else if (trig & WPAD_UP    0x0008) …
if (LayoutButtonHeld("rot_b",A))    reqTiltDown=1;else if (trig & WPAD_DOWN  0x0004) …
if (LayoutButtonTrig("next",A))     next=1;       else if (trig & WPAD_RIGHT 0x0002) …
if (!camera->orienting && LayoutButtonTrig("reset",A)) { PlaySE(0x13); globe->SetTiltIndex(0, true); }
globe->UpdateInertia(hoveredItem >= 0);
fn_80018BE0: globe->CalcCamera(); globe->CalcPoles(); UpdateCityMarkers (fn_80019B90); globe->UpdateLight(); blink timers; globe->CalcScene();
cursor per chan: grabbing→2 (grab hand), over hovered rect→3, pointerY<=63 || >=393 → 0 (arrow), else 1 (open hand)
```
Zoom state (`fn_8001A758` / `fn_8001BC58`): `UpdateZoom(lbl_801793A0)`, `SyncDist`, marker scale = `min(0.24 + 0.6/sqrt(dist), 0.6)` (`0.26 + 0.2/sqrt(dist)` when `lbl_80330B36`), marker min-rank = zoomIdx, then `fn_8001AA70` (grab loop over 4 channels: TryBeginGrab → SE 0x15 on success; UpdateGrab==2 → UpdateRotateSound(0x14); twist-change SE 0x12 with vol 0.5+0.25·min(Δ,2), pitch 1+0.5·min(Δ,2)), then `UpdateTilt(lbl_801793C8)`.
Draw (`fn_80018E90`): `globe->Draw()` after the layout's background pass.

### Input (fn_8002F9CC)
KPADRead(chan, buf, 16). For the newest valid sample: `KPADGetProjectionPos(&p, &pos, {0,0,W,456}, fbWidth/viWidth)`, then
`rawX = p.x*k + W/2`, `rawY = p.y*k + 228` with `k = wide ? 1.1666666 : 1`.
Smoothing: `a = clamp(0.002*|raw−smoothed|, 0.1, 1)`; `smoothed = (1−a)·smoothed + a·raw` (separately for x, y).

### City marker position (fn_80006FC0, CCityMarker ctor; radius 3.0 from fn_80017548)
```c
SinCosFIdx(lat16/256) → sLat,cLat; SinCosFIdx(lon16/256) → sLon,cLon;    // u16 binary angle (GQR3 = u16, scale 0)
pos = r * ( sLon*cLat, sLat, cLon*cLat )      // r = 3.0
```
This matches the camera: `Ry(lon)·Rx(-lat)·(0,0,3)`. Default lat/lon (`0x29C/0x2A0`) = **34.8, 135.4**.
Marker visibility (`fn_80007630`): rank ≥ zoomIdx ⇒ fade toward 1 at ±0.05/frame; drawn only if screen pos is within [−50, W+50]×[−50, 506] and the marker faces the camera; alpha also scales by `clamp(−3·dot,1)` and a cosine falloff by depth.

---------------------------------------------------------------------------------------------------
## 3. Key constants
- **Projection**: fovy **5°**, aspect 608/456 (wide 832/456), near **0.1**, far **200**. Viewport/scissor = render mode fb.
- **Globe radius 3.0**. North pole (0,3,0). Lon 0 → +Z, lon 90 → +X, lat + → +Y.
- **Zoom distances** `kZoomDist` (lbl_8018F730): {1, 2, 5, 8, 12, 17, 25, 40, 65, 100}; start index 0 (dist 1) at the home city; initial camera dist 100.
- **Friction** `kFriction` (lbl_8018F770) per zoomIdx: {0.85, 0.90, 0.95, 0.97, 0.98, 0.98, 0.98, 0.98, 0.98, 0.98}.
- **Tilt** `kTilt` (`lbl_8018F758`): {0, 45, 55, 65, 73, 80}.
- Easing: ChaseValue(rate 0.1, maxStep 100, minStep 0.001) for dist/pitch/lat-level; ChaseAngle(0.1, 180, 1.0) for twist; ApproachAngle 5%/frame.
- Lat clamp ±89; lon wrap ±180; twist threshold 30°; drag gain `0.005*dist` deg/pixel.
- Light: white, at eye, direction look, attn (1,0,0)/(1,0,0), no ambient obj. Clear colour black.
- Emboss: see UpdateMaterials; TevKColor0.a max 77.
- Pointer play area: 63 < y < 393 (px, 456-high screen).

## 4. Luminous halo
Bone `luminous` has **billboard mode 1 (STD)**, so it's a camera-facing quad of radius ≈3.53 drawn Xlu (`luminous_mat`, texture `luminous` 64×8 RGBA8, DrawXlu priority 2). The code skips it in UpdateMaterials; it has no dynamic parameters. Its look comes entirely from material/TEV data plus the g3d STD-billboard rule (rotation replaced by view-aligned axes, keeping scale).

## 5. Open questions
1. `fn_800AD504` (6 rmode-ish args) on camera 1: exact g3d method (projection-for-copy / viewport jitter?).
2. `fn_800B52C8` on the light obj: Clear vs InitLightSpot/Shininess. `flags |= 4` meaning (g3d LightObj flag bit).
3. Texture SRT flag bit 0x2000 cleared for tex3: which per-texture flag (scale-one assumed).
4. `fn_800A2618(&srt,1,1,1,-1)` argument order (mapMode/camRef/lightRef) is inferred from the file's TexMtxEffect layout (`cam,light,mapMode,flag`); verify against an nw4r::g3d reference.
5. (resolved) StartOrient/IsAtOrient target = `lbl_801D7264` = {kTilt[0]=0, 0, 0}.
6. CEarthModel scale (21,21,21) at 0x58: not used by the functions examined.
7. The globe-screen module name: the functions at 0x80017548–0x8001BE00 sit between d_weather_address.cpp and d_weather_around.cpp strings; most likely `d_weather_around.cpp` (the globe "world" view).
8. ScnRoot g3d function identities (ConstructScnRoot, Calc*/Draw*, GetLightSetting, SelectLightObj, InitLightAttnA/K) are inferred from arguments and order. A matching nw4r symbol map (e.g. from another NW4R decomp) would confirm them.
