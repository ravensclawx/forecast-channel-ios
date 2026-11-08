# forecast-channel-ios — decomp & Swift/Metal port notes (Forecast Channel, HAFE v7)

## Pipeline
- `tools/nus2wad.py` — download title from NUS CDN (same URLs as Dolphin's OnlineSystemUpdater) → WAD
- `tools/decrypt_wad.py <wad> <dolphin IOSC.cpp> <outdir>` — decrypt contents (common key read from Dolphin source, never committed)
- `tools/u8x.py` — recursive U8 + LZ77 extraction
- `orig/` (git-ignored): decrypted contents, `main.dol` (= content 1, 0000000d), extracted fs, `earth.brres`
- `decomp/` — decomp-toolkit project. `toolchain/dtk dol split decomp/config/HAFE/config.yml decomp/build/HAFE`
- `decomp/scripts/xref_strings.py <regex>` — string → referencing functions
- m2c: `toolchain/venv/bin/python toolchain/m2c/m2c.py --target ppc-mwcc-c++ -f <fn> <asm file>`

## Contents
| idx | cid | what |
|---|---|---|
| 0 | 0c | banner/meta (`weather_HAFE.0707031038`) |
| 1 | 0d | **main.dol** |
| 2 | 02 | wwwlib-rvl (Opera) |
| 8 | 08 | `earth.brres` — globe MDL0 + 59 TEX0 |
| 9 | 10 | layouts (`weather_layout.arc`: 22 brlyt), fonts, `rev_wtr.brsar` sound, TPLWeather/TPLCommon, cursor effect |
| 10 | 0a | html-us.arc (help pages) |
| 6 | 06 | HOME Menu resources |

## main.dol module map (CodeWarrior link order)
Game code 0x80006FC0–0x80044E30: 726 functions, 0x3DE70 bytes.
| addr ~ | source file |
|---|---|
| 8000AC44 | Connect.cpp |
| 8000D5C8–80010394 | d_s_weather.cpp (scene root) |
| — | d_weather_a_other.cpp, d_weather_a_week.cpp |
| 80014B40–80016F4C | d_weather_address.cpp |
| 8001BDCC | d_weather_around.cpp |
| — | d_weather_base_day.cpp, d_weather_normal.cpp |
| 8002881C | d_weather_setting.cpp |
| 80030E78–80031D8C | System.cpp |
| 80033C80–80035998 | WiiConnect24.cpp (`CWiiConnect24`, forecast.bin / short.bin) |
| — | d_scene.cpp |
| 800418A8–80042130 | sound_manager.cpp |
| 80044E30+ | libraries: RSO, NW4R (g3d ~800A0F40, lyt, ut, snd, ef), vcmv (Opera), RVL SDK, MSL |

Data URLs: `http://weather.wapp.wii.com/%d/%03d/forecast.bin`, `.../short.bin`

## Globe (earth.brres)
MDL0 v8, 11 sections. Bones: nw4r_root, earth, luminous. 29 polygons (28 Opa tiles + 1 Xlu `luminous` halo).
Tiles earth_{a..c}{n}, usa_*, eu_*, japan, southpole: CMPR 1024², each with IA8 `_emboss` map.
Material: 4 texgens, 6 TEV stages, 1 indirect stage; layers = base, emboss_lighting, *_emboss, emboss_edge_mask.
Radius 3.0. Float pos/nrm/uv, idx8/idx16, GX triangle strips.

## Running the port
Runtime data lives in `~/Library/Application Support/ForecastChannel/`: `HAFE.wad` + `common-key.bin` (16 bytes, from Dolphin's IOSC.cpp).
The app opens and decrypts the WAD itself (Sources/RVL/ES.swift) — no extracted files needed.
- `swift build -c release && .build/release/ForecastMac`
- `.build/release/fcdump` — parse check + compile every generated GX shader
- `.build/release/fcdump --render out.png --zoom 9 --tilt 2 --lat 38 --lon -110` — offscreen snapshot through the real game loop

Mac controls (Wii Remote mapping): pointer = mouse, A = left click (hold + drag to spin), B = right click/Esc,
+/- = `=`/`-` or scroll, d-pad = arrows (Up/Down tilt), twist = trackpad rotate, reset button = R (until layouts land).

## Port status
- [x] RVL: ES/WAD decrypt, ARC (U8), CX (LZ77, Huffman), DOLImage (tables read from main.dol at runtime)
- [x] GX: texture decoders, BP/XF state model, SDK GX API (GXSetTev* …), TEV/indirect/texgen → MSL generator
- [x] NW4R g3d (globe), lyt (BRLYT/BRLAN, Material::SetupGX decompiled), ut (ResFont, CharWriter::SetupGX decompiled), snd (BRSAR/RSEQ/DSP-ADPCM engine)
- [x] UI framework: CLayout/CPaneCtl (colour schemes recovered by simulating InitButtonColorSchemes), UI_UpdateHover, CFade
- [x] Scenes: CWeatherScene state machine, boot/connect, save data, CMessage, CAddress (first run + fly-to), CSetting, CNormal hub (UV/Current/Today/Tomorrow/5-Day/6-hour), CAround globe (6 modes, city markers), BGM layering
- [x] Data: forecast.bin/short.bin decomp + validator; Open-Meteo (CC-BY) + GeoNames (CC-BY) generator → original binary format
- [x] HOME Menu (HBM library decomp + port), cursor (HBM cursor layout with REFF state textures)
- [ ] nw4r::ef port for the cursor effect; system font wbf1.brfna (not in title — city font stands in)
- [ ] Opera pages (startup/help HTML) via WKWebView
- [ ] Zoom-crossfade hub↔globe trigger; marker label/icon constants (fn_80009E5C) exact
- [ ] iPhone shell

Notes per area: decomp/notes/{globe,nw4r_g3d_texmtx,scenes,scene_port,hub,sound,forecast_data,homemenu}.md
Dev previews: fcdump --render/--layout/--ui/--hub N/--hbm/--scene <prefix> <script…>
