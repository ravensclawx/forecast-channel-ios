# Cursor: CErrorSystem + nw4r::ef (ported 2026-11-07)

Port: `Sources/Forecast/UI/Cursor.swift` (CErrorSystem), `Sources/NW4R/Ef/` (EfResource, EfEffect, EfDraw).

## Game side
- `CErrorSystem_ctor` (0x8002C164): loads `nw4r_defcursor_all01.breff.LZ` / `.breft.LZ` (content 9) into the
  effect system (0x20000 heap, 0x40 emitters/managers/particles).
- Cursor variable `lbl_801D6F98[chan]` (set by CNormal/CAround/CAddress): 0 pointer, 1 open hand, 2 grab,
  3 over a button, 4 B held in the address list (fn_8001611C).
- `fn_800101C0` → `fn_80032324(chan, s)` → `fn_8002C8E8`: var 0/3/default → 1, 1 → 3, 2 → 2, 4 → 5.
- `fn_8002C304` (Input_Update, every frame), per chan 3..0: kill last frame's effects (+30/+40/+50), then
  - kind = `lbl_8017B4A0[state]` = {0, 0, 1, 2, 2, −1} → normal / hold / open;
  - shadow `lbl_8019B810[kind]` = `def_cursor_<kind>_sd` at (x + 3, 456 − y − 3);
  - state 4 only: a second `def_cursor_open_<n>p` with a jitter offset and colours × 0.85 (unreachable here);
  - hand `lbl_8019B920[kind·4 + chan]` = `def_cursor_<kind>_<chan+1>p` at (x, 456 − y);
  - EffectSystem::Calc(group 0); then `fn_8002CB1C(effect, angle, scale)`: every live particle's
    rotate.z (+0x48) = 2π/256 · Atan2FIdx(horizon.y, horizon.x), RGB of the 4 colours × scale.
- `CErrorSystem_Update` (System_Frame): C_MTXOrtho(t 456, b 0, l 0, r 608/832, −100, 100), identity view,
  EffectSystem::Draw(group 0).
- State 5 is drawn immediately by `fn_8002C8E8`: Setup2DRender/SetOrtho2D, PNMTX1 = fn_80031484(scale 1,
  horizon, translate): TEVREG0 black → TPLCommon image 2 at (+3, +3), white → image 1, both at (−32, −32).

## Resources (all 33 emitters)
- Billboard (type 3, option 0), point form (9), one particle per Calc, life 1, size 27×27 (quad 54×54), no
  animation tracks, MAX_LIFE emitter.
- Hand: 3 TEV stages: `lerp(K1, C0, badge)` → PREV; `lerp(K3, C1, hand)` → REG2 (alpha A1·hand.a);
  `PREV · C2`, alpha A2. ColorInput: C0 = L0 pri (white), C1 = L1 pri (white), K1 = L0 sec (#008CFF), K3 =
  L1 sec (black). Textures: tex1 `defcursor_final_p<n>` (32×32 I8, stretched over the quad), tex2
  `defcursor_final64_{a normal, b hold, c open}` (64×64 IA8). Blend SRCALPHA/INVSRCALPHA, no Z.
- Shadow: 1 stage, colour = C0 = #000000, alpha = 0x5A · `defcursor_sd_{a,b,c}` (64×64 I8).

## Library version notes (vs. the ogws decomp of nw4r::ef)
- EmitterDesc is 0xA0 here: ptcl type/option/dir/axis at +0x8C (ParticleManager ctor fn_80090698 reads the type
  at res+0x94); EmitterDrawSetting is 0xA0 (no trailing type fields); ParticleParameterDesc has no rotate
  offsets (texture names at +0x7A).
- InitTev (fn_8009A78C) has the same alpha-op-from-colour-op table bug; billboard SinCosFIdx(−rot.z) (fn_8009C06C).
