# Sound — sound_manager.cpp decomp + nw4r::snd port

Swift: `Sources/NW4R/Snd/*` (engine), `Sources/Forecast/Sound/SoundManager.swift` (sound_manager.cpp port),
dev tool `fcsound` (`list`, `all [--home]`, `play <name|id> [--wav out.wav] [--seconds N] [--home]`).
Build: `swift build -c release --product fcsound --scratch-path .build-sound`.

## Archives
- `rev_wtr.brsar` (content 9): 51 sounds, **all SEQ**, one bank `BANK_BGM_SE` (38 instruments, 42 DSP-ADPCM waves,
  1.1 MB wave pool), 14 players (BGM1–4, SE1–10, playable count 1 each), group `GROUP_000`.
- HOME Menu: `HomeButton3/Huf8_HomeButtonSe.brsar` (content 6) — **CX Huffman (type 0x28)** compressed RSAR; 28 SEQ
  sounds (`HOMESE_*`), bank `BANK_HOMEBUTTON`, players FOCUS×3 / DEFAULT×4 / FADE_SE×2. main.dol references
  `HomeButton3/...` (not HomeButton2).
- **Sound IDs passed by game code are BRSAR sound indices directly.**

## sound_manager.cpp (main.dol)
| addr | name (port) | notes |
|---|---|---|
| fn_800418A8 | `Init(isMemArchive, ..., allocFn, freeFn)` | Mem- or Dvd-SoundArchive (0x150/0x18C), SoundArchivePlayer (0xD8), SoundHeap 0x1F4000 + LoadGroup(0); FxReverbHi (0x190, params lbl_8018F798) → AxManager::AppendEffect(**AUX_C**=2); custom effect (0x26DDC, fn_800429B8) → AUX_B=1; HBM sound init fn_80042130; output mode from lbl_803301E8 (1 → stereo/mode 0, 0 → mono/mode 3). OSPanic line 0x19D "Cannot open Sound Archive File". |
| fn_80041C38 | `Shutdown` | removes effects, frees archive/player/heaps |
| fn_80041F54 | `Update` (per game frame) | steps 3 faders {step, cur, target, active} (cur → active ? target : 1), then SoundArchivePlayer::Update (+ HBM player) |
| fn_800420E4 | `SetOutputMode(stereo)` | |
| fn_80042520 | `PlaySE(id)` | StartSound(shared handle lbl_80330C4C, id); SetVolume(1); [if player's playable count == 1: SeqSoundHandle call fn_800C0508(-1, ·) — unidentified]; SetPitch(1); SetPan(0) |
| fn_80042640 | `PlaySE(id, vol, pitch, pan)` | same with params |
| fn_800427A8 | `StartSound(handle, id)` | |
| fn_800428A4 | `SetVolume(handle, v)` | BasicSound vt+0x38 |
| fn_80042964 / fn_80042984 | `SetPitch` / `SetPan` | vt+0x3C / +0x40 |
| fn_80042810 | `Stop(handle, fadeFrames)` | vt+0x18 |
| fn_80042830 | `Pause(handle, flag, fadeFrames)` | vt+0x1C |
| fn_80042850 | `IsPrepared(handle)` | vt+0x30 |
| fn_800429A4 | `IsAttached(handle)` | |

Effect params lbl_8018F798 (FxReverbHi): preDelay 0.1, time 2.1, coloration 0.6, damping 0.4, crosstalk 0.1, outGain 0.2.
Sequences send only to AUX C (MML 0xDE), i.e. into this reverb. AUX B's custom effect is never fed by the channel's sequences.

## BGM (d_s_weather — for the scene port)
Four BGM handles `lbl_801F76D4[4]`: **[0] SELF** (30 MORNING / 33 NIGHT), **[1] YOHOU** forecast (28 / 31),
**[2] CIKYU** globe (29 / 32), **[3] OPTION** (34). Night variant when `lbl_803309EC != 0`.
Layers play simultaneously and are crossfaded: each handle has a fade struct at scene+0xF4+12·i {cur, target, step}
(fn_800369A8 moves cur toward target by step; then SetVolume(handle, cur) every frame in fn_8000DD84). A handle whose
volume reaches 0 is paused (Pause(h,1,0)); entering a screen restarts or un-pauses (Pause(h,0,0)) the layers it needs.
- fn_8000F4B8 (enter forecast/globe group): start YOHOU + CIKYU, state 2.
- fn_8000ED20 (enter SELF): start SELF, pause YOHOU/CIKYU.
- fn_8000E7FC (enter options): start OPTION, state 3.
Fade steps table (rodata 0x80179400.. day / 0x80179420.. night): 1/135, 1/240, 1/240, 1/240 | 1/240, 1/135 ×3 (day);
1/120, 1/240 ×4, 1/120 ×3 (night).

## SE IDs by caller
| id | name | callers |
|---|---|---|
| 0 | WTR_SE_CIKYUGI | fn_800227B0 |
| 1 | WTR_SE_EARTH_SEL | fn_800083F0, fn_8003DAD0 |
| 2–11 | WTR_SE_EARTH_ZOOM1..10 | SimpleGlobe::UpdateZoom (index = zoomIdx) |
| 12–17 | WTR_SE_EARTH_ANGLE1..6 | SimpleGlobe::UpdateTilt |
| 0x12 | WTR_SE_EARTH_AXIS | globe grab twist change (PlaySE param vol/pitch) |
| 0x13 | WTR_SE_EARTH_UNDO | globe "reset" button |
| 0x14 | WTR_SE_EARTH_KAITEN | rotation loop (UpdateRotateSound: vol min(speed/5,1), pitch min(speed/90,1)+0.5, pan 0) |
| 0x15 | WTR_SE_EARTH_TUKAMI | globe grab start |
| 22 | WTR_SE_B_SCROLL | fn_8001611C |
| 23 | WTR_SE_COM_RECEIVE | Connect.cpp fn_8000AD28 (StartSound into handle; loops while downloading) |
| 24 / 25 | COM_SUCCESS / COM_ERROR | fn_8000AD28, fn_8000FEB4, fn_80010114 |
| 26 / 27 | COM_BUTTON / COM_BUTTON_B | fn_8000AD28, fn_8000C0C4 |
| 35–37 | KETTEI_B0/B1/B2 (confirm) | fn_8001673C, fn_800164F0, fn_80016F4C, fn_80019B90, fn_800227B0 |
| 0x26 (38) | WTR_SE_CANCEL | back buttons (globe, address, d_weather_*) |
| 39 | CANCEL_BIG | fn_80028598 (settings) |
| 41–43 | TENKI / TENKI2 / TENKI2_RET | fn_80025CF8, fn_80025FA8 |
| 44 | KION (temperature) | fn_8001B030, fn_80028598 |
| 45–48 | PLACE_CHANGE / PLACE_SEL1 / SEL2 / SCROLL | fn_80028598, fn_800164F0, fn_80017368, fn_80015EFC |
| 49 / 50 | RAIN / THUNDER | (not called directly — likely via the weather-type tables) |

## Engine (Sources/NW4R/Snd)
- Tables are read **from main.dol at runtime** (`SndTables`): EnvGenerator attack (0x80195938) & dB-square
  (0x80195838), Lfo sine (0x80195B50), Util Note/Pitch (0x80195BA0/0x80195BD0), Decibel2Ratio[965] (0x80195FD0),
  Pan sqrt[257] (0x80196EE4; sin/cos & linear pan tables are not linked in this DOL → formula).
- Semantics cross-checked against the ogws (Wii Sports) nw4r::snd decomp: MML command set incl. prefixes
  (A0 random / A1 variable / A2 if), call/loop stack depth 3, variables (16 local, 16 global, 16 per track, init −1),
  note-wait, tie, portamento/sweep, LFO targets, envelope (attack multiplier per ms until > −1/32 dB·10, decay/release
  linear in 0.1 dB/ms, sustain from dB-square table), 3 ms AX frames with tick fraction timing
  (ticks/ms = timebase·tempo/60000), track volume²·volume2²·playerVolume², velocity² · instVolume, pan curves.
- Voice: decoded DSP-ADPCM (loop addresses converted nibble→sample), 32 kHz mixer, per-frame linear volume ramp,
  4-point interpolation; AUX C → FxReverbHi model.
- Output: AVAudioEngine source node at 32 kHz (macOS + iOS).

## Verified
`fcsound all`: all 51 channel sounds and all 28 HOME Menu sounds start and render non-silent; no unknown MML commands.
SEs end in 0.4–3.3 s; all BGMs render 30 s continuously, peak ≤ 0.68, no clipping.

## Gaps / open questions
1. FxReverbHi is a structural model with the real parameters, not a decompiled AXFX ReverbHi (delay lengths/coefs).
2. AX's polyphase SRC replaced by Catmull-Rom; AX voice volume ramp/priority stealing simplified (no 96-voice cap).
3. fn_800C0508(-1, flag) inside PlaySE (SeqSoundHandle method, likely track-mute/variable) not identified.
4. The three faders updated in fn_80041F54 — consumers not yet traced (likely HOME-menu/fade volume).
5. AUX B custom effect (fn_800429B8, 0x26DDC bytes) not ported (no sequence sends to it).
6. Remote-speaker output (WPAD speaker, Huf8_SpeakerSe.arc) not implemented.
