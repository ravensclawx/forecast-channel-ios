# Scenes & screens — functional decomp (main.dol, HAFE v7)

Porting notes for the screen layer. These complement `globe.md` (globe camera and input) and `nw4r_g3d_texmtx.md`.
Message text and other content live in the layouts themselves, so the port reads them from the user's own WAD. These notes only describe behaviour and identifiers.

Tools:
- `scripts/brlyt.py <file>`: pane tree + text dump. Dumps of every layout are in `build/lyt_*.txt`.
- `scripts/decall.py lo hi dir`: batch m2c with jump tables and strings resolved. Output is in `build/m2c/all`.
- `scripts/fnindex.py dir`: per-function index of strings, SE IDs and calls (`build/fnindex.txt`).
- `scripts/words.py`: vtable/PTMF dumps.
- `scripts/eval_stores.py`: constant tables built in code.
- `scripts/rename.py` + `scripts/refresh.sh`: symbol renames, then re-split.

Symbols renamed in this pass are listed in §11. The pre-pass symbol file is backed up at `build/symbols.before_screens.txt`.

Conventions: screen space is 608×456; widescreen logical width is 832 (×1.3684211). `lang` = `lbl_80330B36` (0 JP, 1 US/English, 2 GE, 3 FR, 4 SP, 5 IT, 6 DU). The suffix strings `JP US GE FR SP IT DU` are at `lbl_80330138..50` and returned by `GetLangSuffix()`. `region` = `lbl_80330B3C` (0 JP, 1 US, 2 EU). `country` = `lbl_80330B38` (SYSCONF country code <<24; if unset, the default is JP 0x01, US 0x31, EU 0x4E).

---------------------------------------------------------------------------------------------------
## 1. Boot, main loop, system scenes (System.cpp)

`main` → `System_Init` (fn_8002F3D0); then loop forever: `Input_Update` → `System_Frame` (fn_800307C0).

**System_Init**
1. OSInit, the two heaps (MEM1/MEM2 expanded heaps), WPAD/KPAD init (4 channels, pointer and accelerometer smoothing 0.05 and 0.03), GXInit with a 0x40000 FIFO.
2. Read language, region and country. The language change call `fn_801174B0` + `fn_80116D58` syncs the SC (system config) language.
3. Init NWC24/VF (`fn_8005EF90`), the sound system (`fn_80032610`, `fn_80045ABC` + 6 audio heaps), NAND, then allocate a 0xB4000 copy buffer (`lbl_80330B44`, the frame capture used by the fade).
4. Construct `CErrorSystem` (cursor + fatal error; see §8).
5. Scene ID = 'NONE'. Then `System_ChangeScene('FATL')` if `CErrorSystem->+0x60` (a fatal NAND/system error at boot), otherwise `System_ChangeScene('WTH2')`.

**System_ChangeScene(id)** (fn_80030E78)
- Clears all KPAD state, destroys the current scene (WTH2 → vtable+0x08 dtor; FATL → `fn_8002CD80`), and panics on a heap leak (the FATL path is exempt).
- Then constructs the new scene:
  - **'WTH2'**: `CWeatherScene` (0x16C) via `CWeatherScene_ctor` (fn_8000D5C8), then vtable+0x1C (init).
  - **'FATL'**: `CFatalScene` (8 bytes) + `error_system.brlyt`.

**System_Frame** (once per 60 Hz frame, in order)
1. Begin GX frame and set the viewport (normal or field-rendering for interlace).
2. If not paused by the HOME Menu (`lbl_80330B5E==0`, or HBM is drawing `B5C`/`B5D`): scene Calc (WTH2: vtable+0x30 = `WeatherScene_Calc`; FATL: `fn_8002CED8`).
3. `CErrorSystem_Update`: cursor effect calc.
4. Scene Draw (WTH2 vtable+0x34 = `CScene_Draw`).
5. Global transition overlay when `lbl_80330B48` (mode) ≠ 0. t = `lbl_80330B4C`/`lbl_80330B50`, eased with sin(t·π/2):
   - mode 1: black full-screen quad with alpha 255·e;
   - mode 2: the captured frame (copy buffer) redrawn with alpha e;
   - modes 3/4: the captured frame redrawn **zooming**. The texcoord inset is 0.1·e (mode 3 inverts alpha), so the image grows by up to 10% while fading. This is the zoom-cross-fade used between screens.
6. Copy the EFB to the XFB and VI flip.

The whole 2D UI is drawn with `Setup2DRender` (fn_80031170: TEV = vertex colour × texture, alpha blend, Z off) and `SetOrtho2D` (fn_800313F4: ortho 0..W × 0..456, near −100, far 100).

---------------------------------------------------------------------------------------------------
## 2. Shared UI framework (d_scene.cpp + the CLayout/CPaneCtl wrapper)

### CScene base (fn_8003B2C8 ctor, vtable lbl_8019C5E0; CWeatherScene derives from it)
The constructor builds everything shared:
- **Heaps**: 7 MB MEM1 + 27 MB MEM2 expanded heaps (`lbl_80330C0C/C10`).
- **Content archive object** `CContentArc` (0x234, `CContentArc_ctor`): opens `html-jp.arc`/`html-us.arc`/`html-eu.arc` by region for Opera, plus `Opera.arc` and HOME Menu resources. Flags in `+E/+F`.
- **Fonts**:
  - Time font `font_weather_time.brfnt.LZ` (JP) or `font_weather_timeWW.brfnt.LZ` (other languages), as `ResFont` `lbl_80330BE0`.
  - City-name font `/font_weather_city.brfnt.LZ` (`lbl_80330BD8`, `SetAlternateChar(0xE06B)`).
  - The layout fonts `font_weather.brfnt` / `font_weather_kion.brfnt` come from `weather_layout.arc` itself.
  - The system font `wbf1.brfna` is an `ArchiveFont` (`m_pSysFont`), used for the city name text in the telop (`lbl_801F7310` TextWriter).
- **TPLCommon.tpl.LZ** (`lbl_80330C00`): the **digit/symbol sprite sheet**. `lbl_8018F4E8` lists 0x59 character codes. For each, the image width/height is cached in `lbl_801F6C68+0x218` (12-byte records `{code, w, h}`).
  - Numbers, temperatures, times and percentages are drawn as these sprites, not with fonts: `DrawSpriteNumberCentered` (fn_8003E150) + `DrawSpriteString` (fn_8003E414).
  - The glyph lookup table `lbl_8018F668` holds `0-9 - C F` and the degree sign (0xFF9F).
- **Fades** (`CFade`, 0x64): `m_pFade` = black opaque (`lbl_80330BBC`); `m_pFade2` = black at alpha 0xA0 (`lbl_80330BC0`), used for dimming behind dialogs.
- **Globe**: `CSimpleGlobe` (`g_pSimpleGlobe`). `earth.brres` is loaded asynchronously (globe.md §0).
- **Telop text-box metrics**:
  - Telop rectangle: x = 28 (wide 36), y = 34 (wide 19).
  - JP: width 165, height 41. Other languages: height 36, plus a vertical offset of 0.25 × line height (`+0x94`).
- **Per-language PTMF**: the initial sub-state is picked from a table at `"/earth.brres.LZ"+0x140` by `lang` (US + region US use slot +0x14C).

### CLayout (0x434) — fn_80039994 ctor
`CLayout(arc, name, ?, colorScheme, wideFlag)` wraps:
- `ArcResourceAccessor` (mounted at "arc"),
- `lyt::Layout`,
- `lyt::DrawInfo` (in widescreen, `locationAdjustScale.x = 1/1.3684211` keeps the 608-wide design centred),
- an array of up to 256 **`CPaneCtl`** (0xA0) wrappers, one per pane (`+0x14[]`, count `+0x414`).

Methods:
- `CLayout_FindPane(name)`: linear search by pane name; returns the `CPaneCtl`.
- `CLayout_Reset` (fn_80039D40): resets every wrapper and the slide state.
- `CLayout_Update` (fn_80039E28): runs `CPaneCtl_Update` for every pane, plus two layout-wide effects:
  - **slide**: if `+0x418` is set, the counter `+0x420` counts up to `+0x41C` (default 15), otherwise down. Each pane gets an x offset of `width(pane0) × count/max × sign(pane.x)`, so the two halves of the screen slide outward. Used for belt/menu swipe-out.
  - **fade**: if `+0x424` is set, `+0x42C` counts up to `+0x428`. The layout alpha is `255 − 255·n/max`, applied as every wrapper's `+0x70`.
- `CLayout_Draw` (fn_8003A00C): ortho from the layout rect (flipped if `layout.+0x20 == 1`); pre-draw all wrappers, `Layout::Draw`, post-draw.
- `CLayout_HitTest(x, y)` (fn_8003A140): returns the topmost enabled wrapper containing (x, y) in layout space.

### CPaneCtl (0xA0) — naming conventions the code relies on
The constructor (fn_80037184) looks up companion panes by suffix for a pane named `P`:

| companion | role |
|---|---|
| `PB` | body/background (falls back to `P`). The hit rectangle comes from `PR` if present, else `PB`, as P-translation + pane rect → `+0x3C..0x48` (x0, y0, x1, y1). |
| `PI` | icon group; only the child `PI<lang>` is shown and its siblings are hidden (if no lang child, `PI` itself is used). |
| `PT` | text group; only `PT<lang>` is shown. Inside it, children are *variants* chosen by index (`CPaneCtl_SetTextIndex`, `+0x80/+0x84`). A suffix digit or letter selects the message, e.g. `textTUS3`, `backTUS1`, `beltTUS4A`. |
| `PF` | press frames `PF0`/`PF1`; F1 is shown while pressed, F0 otherwise. |

**User-data flags** (the 8 bytes at pane+0xC4):
- `d` → disabled (`+0x98`)
- `f`/`F` → fixed, no hover/press colouring (`+0x90`)
- `c<digit>` → colour scheme index (`+0x6C`)

**State fields**: `+0x78` hover ramp 0..12; `+0x7C` press timer (18 frames, snapping the hover ramp to 12 at frame 9); `+0x92` "keep pressed" latch (set when a button is chosen, before the screen transitions); `+0x94` hidden; `+0x97` selected; `+0x9C` slide x offset; `+0x70` alpha multiplier.

- `CPaneCtl_Update` (fn_80037B64): advance the hover and press timers.
- `CPaneCtl_SetHoverTree` (fn_80038768): mark `P` and its first two levels of children as hovered this frame.
- `CPaneCtl_Press` (fn_800389C4): start the press on `P` and hover its subtree. `CPaneCtl_Flash(p, 1)` (fn_80038990) does the same for hardware-button activation (the press anim starts at 0x12).
- `CPaneCtl_PreDraw` (fn_80037C20) computes the colours and writes them with `Material::SetColorElement`, using nw4r AnimTarget indices 4/5/6 = TEV colour 0 RGB, 8/9/10 = TEV colour 1 RGB, 0xB = alpha:
  - body (B) gets colour pair `{c0, c1}`, icon (I) gets `{c0, c1}`, text (T) gets one colour, picked from the scheme by state, in priority order: selected → pressed (`+0x92` latched or timer > 0) → lerp(normal, hover, ramp/12) → normal.
  - If the wrapper alpha is < 255, colours are also lerped toward fixed fade colours (`lbl_80331FD4/FD8`).
  - The text colour can be overridden with a callback (`+0x30`).
- **Colour schemes**: 16 schemes × 0x3C bytes at `lbl_801F6B68`, built at static-init by `InitButtonColorSchemes` (fn_800394A4). Regenerate with `scripts/eval_stores.py fn_800394A4 lbl_801F6B68 0x3C0` (output in `build/button_colors.txt`). Offsets:
  - `+00/+04` body normal c0/c1
  - `+08/+0C` icon normal
  - `+10` text normal
  - `+14/+18` body pressed/hover target
  - `+1C/+20` icon pressed
  - `+24` text pressed
  - `+28..+38` the same set for "selected"

  (Scheme 0 normal body = transparent/white, icon = black→light grey; scheme 1 icon accent = orange FF7800; scheme 2 = yellow F8BE00; scheme 3 = cyan 59DDFF; all schemes share pressed body FFFFFF/C10000. Some word-store entries need verification; see §10.)

### Input/hover (d_scene.cpp)
- `UI_UpdateHover(layout, hoverSE)` (fn_8003DAD0): for each connected Wii Remote, map the pointer to layout space (x − W/2, scaled by 608/W when wide; y = 228 − y, clamped), then `CLayout_HitTest`.
  - When the hovered wrapper changes: un-press the old one; if the new one is enabled, play **SE hoverSE** (always 0x28) and rumble pattern (ch, 3, 0x14).
  - A trigger (0x800) → `CPaneCtl_Press`.
  - The hovered wrapper per channel is kept in `lbl_801F72F0[4]`.
- `UI_ButtonTrig(paneName, mask)` (fn_8003DEAC): returns the channel whose hovered wrapper is named `paneName` (and not disabled) with `mask` triggered; flashes it. Returns −1 if none.
- `UI_ClearHover` (fn_8003DD50).
- Hardware shortcuts: `lbl_80330B1C` holds the triggered buttons of all remotes (bit 1 LEFT, 2 RIGHT, 4 DOWN, 8 UP, 0x10 PLUS, 0x800 A, 0x1000 MINUS).

### Other helpers
- `FormatIntW(value, wchar* out, maxDigits, zeroPad)` (fn_800362D8): wide-digit string through the digit table `lbl_8018F4D0`, with a leading '-' for negatives.
- `MinutesToDate(minutes since 2000-01-01 00:00, out)` (fn_800364D8): fills {min, hour, mday, mon(0-based), year, wday = (days+6)%7 [2000-01-01 was a Saturday], yday}. Forecast timestamps use this unit.
- `LerpU8(a, b, t, max)` (fn_8003716C), `ChaseValue`/`ChaseAngle` (globe.md).
- `LoadArcFileLZ(...)` (fn_80031620): read a file from the channel's own content (CNT) into a heap and decompress it by CX type (LZ / Huffman / RL).
- `Snd_StartSoundHandle(id)` (fn_80042520): start sound `id` on the global handle (sound fork owns the internals). **All SE IDs below go through this.**

---------------------------------------------------------------------------------------------------
## 3. CWeatherScene (d_s_weather.cpp) — state machine

**Object (0x16C)**
- `+A8` weather_layout.arc
- `+AC` TPLWeather.tpl.LZ (icon sprites)
- `+B0` CAddress (city select)
- `+B4` CNormal (the hub + pages)
- `+B8` around screen
- `+BC` CSetting
- `+C0` current state PTMF, `+CC` saved/next PTMF
- `+138` sub-step
- `+144/+148` timers
- `+158` CConnect (0x460)
- `+15C` CMessage (0x18; dialog boxes)
- `+160` SaveData buffer (0x20)
- `+164` load result
- `+168` save result

Globals: `lbl_803309B4` = parsed forecast data (`CForecastData`, owned by the data fork); `lbl_80330A00` location ID; `lbl_803309F0` temperature unit; `lbl_803309F4` wind unit; `lbl_803309FC` current country.

**Constructor** (`CWeatherScene_ctor`)
- Creates the sound manager (`rev_wtr.brsar`, `m_pSound`).
- `lbl_803309E0 = 1` = start page (Current). `lbl_803309E4` = page count: 4 if lang JP, else 5.
- `lbl_803309EC` = "daytime" flag (local hour 5..17 from the RTC).
- Loads `TPLWeather.tpl.LZ` and `weather_layout.arc.LZ` and allocates the 0x20 save buffer, then enters `WeatherScene_StBoot`.
- Load failures → `Globe Read!!` path / fatal.

States are PTMFs at `lbl_80199AA8 + off` (see `scripts/words.py`). Each runs with a sub-step `+138`; `−1` = exit hook.

| state | fn | role |
|---|---|---|
| StBoot | fn_8000FEB4 | see below |
| StAddress | fn_8000E934 | first-run / changed-city flow: CAddress (city picker); on confirm, store the save and go to StNormal; on save failure, StConnect error |
| StNormal | fn_8000EF08 | the hub (CNormal). Watches the request code `lbl_8032FCF0` (below) |
| StConnect | fn_80010114 | shows a CMessage error (type 4 for save-failed-full, 5 otherwise), SE 0x19 |
| StFAE4 | fn_8000FAE4 | quit to Wii Menu: fade out and OSReturnToMenu (verify) |
| StF660 | fn_8000F660 | settings (CSetting) |
| StE6B8/E6C0/E6C8/E7EC/E7F4 | small glue states (wait for fade, dispatch) |
| CNormal states | fn_80022C1C (passive), CNormal_StInteractive, fn_8002721C, fn_80027270 |
| CAround states | fn_80018C9C (interactive), fn_800172A0 (address-globe zoom), fn_8001A758 (zoom/grab), fn_8001BC58 |

**StBoot**
- step 0: init.
- step 1: start the connect (`CConnect_Start`), which builds the two download URLs (forecast.bin / short.bin, `%d` = lang, `%03d` = country) and resets dialogs.
- step 2: run `CConnect_Update` until `CConnect_IsDone` (state 6 and fade idle).
- step 3: `SaveData_Load()` → 0 ok / 1 no file / 2 broken / 3 NAND error.
  - **0**: if the saved country == current country and the saved location still exists in the new data (`fn_80020300`) → step 9 (normal start). Otherwise CMessage type 3 ("cities changed"; layout error4 text 1) → StAddress.
  - **1**: CMessage 1 → StAddress (first run: choose your location).
  - **2**: CMessage 2 + SE 0x19 (save corrupted; error4 text 0) → StAddress.
  - **3**: CMessage 4 + SE 0x19 → error.
- step 4: run CMessage until closed (state 5).
- step 9+: `fn_8000E078`: apply the saved settings (location/units from the save; else defaults from the forecast header units flag `data.hdr+0x19`: 1 → °F + mph, 2 → °C + km/h; location = country default), create CAddress/CNormal/around/CSetting, then go to StNormal.

**Request codes** `lbl_8032FCF0` (set by buttons on screens and consumed by the scene):

| code | meaning |
|---|---|
| 1 | "change city" (from settings) |
| 2 | settings back (store save if changed: `fn_8000E384` compares location/units, then `SaveData_Store`) |
| 3 | back to previous (hub back when not top-level) |
| 4 | open settings (hub) / address back |
| 5 | open globe (hub) |

`lbl_8032FD00` = 1 means the hub is top level ("Back" button shows "Wii Menu" and exits); `lbl_80330BB9 = 1` means return to the Wii Menu.

Transitions use `CFade_StartFadeOut(m_pFade, 0x19)` / `CFade_StartFadeIn(m_pFade, 0x19)` (25 frames) and `m_pFade2` for dialog dimming (0x14 frames). The globe entry uses the zoom-cross-fade (System_Frame mode 3/4).

**Save data**: NAND `noerase/savedata.dat` in the title data dir (created with perm 0x3D). The scene buffer is 0x20 bytes:

| off | field |
|---|---|
| +0 | magic `HAF0` |
| +4 | country code (`lbl_803309FC`) |
| +8 | location ID (`lbl_80330A00`: country<<24 \| region<<16 \| city) |
| +C | temperature unit (0 = °C, 1 = °F) |
| +10 | wind unit (0 = mph, 1 = km/h) |
| +14..1B | unused |
| +1C | CRC32 (`fn_80067D44` = NETCalcCRC32) of bytes 0..1B |

Load checks the size, CRC and magic. Store creates the dir/file and rewrites it.

**CMessage** (`CMessage_Open(type)` / `CMessage_Update`, 0x18 bytes): modal dialog.
- Type selects the layout and text index:
  - 1 = choose location (error4 / set_area text)
  - 2 = save corrupted
  - 3 = cities changed
  - 4/5 = save errors (error2 texts 1/2)
  - (error2 text 0 = "change date/time in Wii Options", used when the RTC is invalid)
- Buttons: `next` (OK) or `yes`/`no`; hover SE 0x28.
- SEs: 0x18 open, 0x1A button, 0x1B close (from the index).
- `+10` == 5 → closed.

**CConnect** (Connect.cpp, `CConnect_ctor`, 0x460)
- Layouts: `+448` progress dialog (error1.brlyt "please wait" frame) and `+44C` error0.brlyt (8 numbered WiiConnect24 errors + "Back to Wii Menu" `next`).
- `CConnect_Update` drives the WiiConnect24 download (fork: WiiConnect24) and on error maps the NWC24 code through `MapNwc24ErrorToCode` (fn_800358A8) to the error0 text index:

| NWC24 code | index |
|---|---|
| −16..−21, −38, −41, −43, −46 | 11 (→ message "unable to download latest") |
| −49 | 12 |
| −1, −11, −42 | 2 |
| system-update-needed (`fn_8006AFD0`) | 5 |
| −39 | 3 |
| −31 | 4 |
| −32 | 5 |
| other | 6 |

  (The table maps the result onto error0 texts 0..7; verify the exact index arithmetic in `CConnect_Update` / `fn_8000B46C` jump table.)
- Fatal errors show error0 with only "Back to Wii Menu".
- "Unable to download latest info" (text 5) continues with cached data if present.

---------------------------------------------------------------------------------------------------
## 4. The hub — CNormal (d_weather_normal.cpp)
**Layouts**
- `forecast.brlyt` (+0): buttons `up`, `down`, `set`, `back`, `around`, plus `blank`.
- `base.brlyt` (+4): background plate.
- `base_belt.brlyt` (+8): top belt with title `beltT<lang><N><A|B>`, city telop `city` (bounding box), time `timeJP`/`timeWW`, logo, `belt_time`.
- `day_6h_nWW.brlyt` (+C): the US "6-Hour Weather" strip; JP uses `day_6h_nJP`.

**Pages**: `+24[i]` objects for i < page count, each with a vtable whose `+14` is Draw(pagePos, …):

| i | page | module |
|---|---|---|
| 0 | UV Index ("life" page) | d_weather_a_other, `life_nWW.brlyt`; JP uses laundry/UV/pollen life_nJP with 3 sub-pages |
| 1 | Current | fn_80010B7C module: day page with current conditions |
| 2 | Today | d_weather_base_day, `day_nWW.brlyt` |
| 3 | Tomorrow | d_weather_base_day |
| 4 | 5-Day | d_weather_a_week, `week_nWW.brlyt` |

- When data is missing, a page shows `life_no_service.brlyt` with text index 0..6 (no UV for location, no current conditions, no today, no tomorrow, no 5-day, no UV data, no 5-day data).
- The `up`/`down` button captions show the neighbouring page names (`upT` variants 0..3, `downT` 1..4); each is disabled at the ends.
- The belt title index = page index (`base_belt` titles 0..4; the 5-day detail uses titles 5..11 = weekdays).

**CNormal_StInteractive** (fn_800227B0) each frame:
1. If top level (`lbl_8032FD00`): `set` and `back` are enabled, `backI` (house icon) is hidden, and the back caption is variant 0 ("Wii Menu"). Otherwise `set`/`back` are disabled+pressed, `backI` is shown and the caption is variant 1 ("Back").
2. Update all four layouts; `UI_UpdateHover(forecast, 0x28)`.
3. `up` (or d-pad UP) → scroll up (`+7F7`); `down` (or d-pad DOWN) → scroll down (`+7F8`).
4. `set` → SE 0x25, request 4. `back` → top level: SE 0x25 + exit to Wii Menu; else SE 0x26, request 3, sub-state lbl_8019B428 (slide out). `around` → SE 0 (globe whoosh), request 5, sub-state lbl_8019B434.
5. Draw the pages with the scroll offset (`fn_80025B58`: page scroll animation via ChaseValue; SE 0x29 per page flip, 0x2B at the end/bounce).

**City telop** (`CNormal_SetupCityTelop`):
- The belt `city` box shows the location name from forecast data (entry `+4`; second line `+C` region/state, `+10` country) using `TextWriter` with the city font.
- Each line is scaled to fit the box width (scale = min(1, boxWidth/textWidth)).
- JP + country Japan shows a single line plus an optional prefecture.
- Clock: `belt_time` with `timeWW` (US: `h:mm` + AM/PM sprite parts `belt_timeBUS0..3`) from the current RTC. The date/time formatter is `fn_8002767C`/`fn_800277E4` (`MinutesToDate` + `FormatIntW`).

### Pages (common pattern)
Every page module has a vtable `{dtor, init, calc, draw(posY, …), …}`:
- life `lbl_8019A1D8`, current `lbl_8019A0B0`, week `lbl_8019A960`, day `lbl_8019AF2C`, JP extra life pages `lbl_8019A210`, `lbl_8019A248`.

Each page draws its brlyt via CLayout and overlays sprite numbers at the named **anchor panes** (empty `pan` nodes used only as positions). The data → pane mapping:
- **Current** (fn_80010B7C module, `day_nWW` + `life_no_service`):
  - weather icon (TPLWeather sprite by weather-type ID) at `icon`;
  - temperature at `kion_do_cnt` (°C) / `kion_doF_cnt` (°F): field `+F` = °C, `+10` = °F, chosen by `lbl_803309F0`;
  - wind direction/speed into the `belt_wind` B0/B1 parts (speed field `+13` mph / `+12` km/h by `lbl_803309F4`; `+11 == 0xFF` means no wind);
  - telop text (weather description from data) in bounding `telop`, wind text in `wind_telop`.
- **Today/Tomorrow** (`day_nWW`, d_weather_base_day): same fields from the day forecast record. Precipitation chance via `text_rain_a..d` / `rain_a_10..d_10` (4 six-hour blocks shown on the `day_6h` strip), high/low via `kionH_1-100` / `kionL_1-100`, °/% symbols `text_ondo` / `text_percent`.
- **5-Day** (`week_nWW`, d_weather_a_week): 5 columns a..e (JP 7 a..g). Each has `week_X_1` (date), `week_X_youbi` (weekday), `week_X_icon`, `week_XH_10`/`week_XL_10` (high/low anchors), `week_Xr_10` (rain %), plus `week_XB0` backgrounds; `week_XH_do_cnt` / `week_XH_cnt` choose the °C/°F digit layout. Unit selection is `lbl_803309F0` throughout.
- **UV** (`life_nWW`, d_weather_a_other): `life_b` group. The icon is `life_bI` (`life_b_UVWW.tpl` frames by index), the number goes at `life_b_1-1`/`-10`/`-100` anchors, and the description text in bounding `life_b_telop`. The scale for WW is `{1.0, 0.75}` (two anchors).

Weather/description strings come from the forecast data (data fork), not from the layouts. Weekday and month names are layout variants (`beltT…5..11`, `week_X_youbi` sprite frames).

---------------------------------------------------------------------------------------------------
## 5. Globe screen — CAround (d_weather_around.cpp, 0x80017548–0x8001C2A4)
- **Layouts**: `around.brlyt` (+6C; buttons `zoom_out`, `zoom_in`, `next`, `back`, `rot_a`, `rot_b`, `reset`) and `around_belt.brlyt` (+70; mode title + legend `kion`/`rain`/`high` + digit anchors `text_kionH/L`, `text_ondo`).
- **Construction**: `CAround_ctor` creates up to N `CCityMarker`s (fn_80006FC0, one per city in the forecast data) and the reset button wrapper (+74).
- **Entering**: `fn_80017FC8` (from the hub) or `fn_8001812C` (from the address picker) → `ConvLatLon16ToDeg(home city)` → `SimpleGlobe_SetZoomIndex(0)` + `SimpleGlobe_Init` (globe.md).
- **Interactive frame** (`CAround_StInteractive`, fn_80018C9C + globe.md §2):
  - Clear the request flags; layout slide; `reset` is disabled while `!SimpleGlobe_CanReset`.
  - **Marker scale**: non-JP `0.26 + 0.2/√dist`; JP `min(0.24 + 0.6/√dist, 0.6)`. (globe.md had these two swapped: the condition is `lang != 0`.)
  - Marker min-rank = zoom index.
- **Display mode** (`lbl_803309E8`, 0..5, persists across visits): `next` or d-pad RIGHT advances, d-pad LEFT goes back (SE 0x2C, wraps at 6).
  - Table `lbl_80179B98[mode] = {marker icon/number draw PTMF, belt legend PTMF, day selector}`.
  - Modes: 0 current weather (icons), 1 current temperature (numbers), 2 today's weather, 3 today's high, 4 tomorrow's weather, 5 tomorrow's high.
  - Day selector: 2 = current (short.bin), 0 = today, 1 = tomorrow.
  - The belt title = `around_belt beltT<lang><mode>`. The legend functions `fn_8001B268..BA6C` fill `text_kionH`/`text_ondo` etc.
  - For lang JP the table `lbl_80179AA8` (6 PTMFs) is used instead.
- **Buttons**: `back` (SE 0x26 → hub), `reset` (SE 0x13; globe.md), `zoom_in`/`zoom_out` held + Plus/Minus; `rot_a`/`rot_b` + d-pad UP/DOWN = tilt. Hover SE 0x28; marker hover SE 0x25.
- **CCityMarker** (fn_80006FC0 ctor; draw/update ~0x80007000–0x8000A8D0):
  - Position = `3·(sinλcosφ, sinφ, cosλcosφ)`; visibility, fade and rank as in globe.md §2.
  - Each marker shows the mode-dependent icon (TPLWeather sprite) or number (TPLCommon sprites, `°F`/`°C` unit by `lbl_803309F0`, index `(unit×0xA)` into the per-day temperature record `+0x18 + day×0x66`).
  - The marker for the user's city (`lbl_80330A00`) is highlighted.
  - Clicking a marker (hover + A) opens its forecast (SE 0x25; `CAround_UpdateMarkers` fn_80019B90 → request to show that city's pages).
  - Marker label: city name with the city font.

---------------------------------------------------------------------------------------------------
## 6. City select — CAddress (d_weather_address.cpp)
**Layouts**: `base.brlyt` (bg), `set_area1.brlyt` (scrolling list with `up`/`down`/`back`, message `text` 0 = "choose location", 1 = "choose region") and `set_area2.brlyt` (confirm `yes`/`no`, message "is this location correct?").

**Flow**
1. `CAddress_StList` (fn_800168F8) or `StList2` for two-level countries: region list, then city list from forecast data (the entries per region come from the data's location table).
   - Items are drawn as text rows; the scroll is ChaseValue-smoothed, SE 0x30 per step (fn_80015EFC).
   - Wheel/d-pad and `up`/`down` buttons scroll (`fn_80015668`; hover SE 0x28).
   - Choosing a row (fn_800164F0) → SE 0x24 (0x2F for region).
   - `back` → SE 0x26, request 4 (only enabled if `lbl_80330A09`, i.e. not first run).
2. After a choice, the globe flies to the city (`fn_800172A0`: SE 0x2E, globe zoom via `fn_8001812C`), then `CAddress_StConfirm` (fn_80016F4C): `yes` → SE 0x25, commit `lbl_80330A00`; `no` → SE 0x26, back to the list.

---------------------------------------------------------------------------------------------------
## 7. Settings — CSetting (d_weather_setting.cpp)
**Layout**: `set.brlyt` over `base.brlyt`. Rows:
- `city` with `city_set` (city name, bounding box) + `city_btn` "Change";
- `kion` with `kion_set` variants: index = `lbl_803309F0`; per-language sub-variants a/b/c for °C/°F wording;
- `wind` with `wind_set` (0 mph, 1 km/h) + `wind_btn` (row hidden for JP);
- `back`.

**`CSetting_StInteractive`**:
- Value panes glow `LerpU8(0x40, 0xC0, hover/12)`.
- `back` → SE 0x27, request 2 (scene saves if changed).
- `city_btn` → SE 0x2D, request 1 (→ CAddress).
- `kion_btn` → toggle °C/°F, SE 0x2C.
- `wind_btn` (non-JP) → toggle mph/km/h, SE 0x2C.

---------------------------------------------------------------------------------------------------
## 8. Cursor, HOME Menu, fatal errors, Opera
- **Cursor** (`CErrorSystem`, 0x64): `nw4r_defcursor_all01.breff/.breft` loaded via `LoadArcFileLZ`.
  - Emitters `def_cursor_normal_<n>p`, `def_cursor_hold_<n>p`, `def_cursor_open_<n>p` per player, plus shadows `def_cursor_*_sd`.
  - Choice per channel (globe.md): grab hand while dragging the globe, pointing hand over a button, open hand in the globe play area, arrow (normal) elsewhere.
  - `CErrorSystem_Update` runs the effect system each frame and draws in a 2D ortho.
  - For the port: draw the cursor sprites from the breft textures with the same states; full breff emitter emulation is optional.
- **HOME Menu**: HomeButton3 resources from content 6 (`LZ77_homeBtn.arc`, `LZ77_homeBtn_<lang>.arc`, `Huf8_HomeButtonSe.brsar`, `Huf8_SpeakerSe.arc`, `home_nosave.csv.LZ` = the "progress isn't saved" message table, `config.txt`).
  - Invoked by the HOME button (`lbl_80330B5E` = HBM active; the scene Calc pauses).
  - `fn_8002D6F8` handles resume (fade-in + earth reload).
  - Port: a native overlay with Wii Menu / Reset / close is acceptable; the original HBM is a separate NW4R layout package.
- **FATL scene**: `error_system.brlyt` shows a fatal system/NAND error with no exit except power/reset.
- **Opera / startup.html**: `CContentArc` mounts `html-us.arc` and Opera (`wwwlib-rvl`). Used for the per-region `startup*.html` (the first-run notice/legal text) and `index/index_Frameset.html` (help/manual). The trigger is in the region of fn_8002D1D4..fn_8002DDCC (not fully traced). Port: WKWebView on the same HTML files.
- **Reset/Power**: the standard OSSetResetCallback/OSSetPowerCallback set in System_Init (fn_8002F990 / fn_8002F9A0 set flags; the scene fades and exits).

---------------------------------------------------------------------------------------------------
## 9. SE IDs used by screens (Snd_StartSoundHandle)
0x00 open globe · 0x13 globe reset · 0x15 globe grab · 0x18/0x1A/0x1B dialog open/button/close · 0x19 error/notice · 0x23 address scroll end · 0x24 choose city · 0x25 decide/confirm · 0x26 back/cancel · 0x27 settings back · 0x28 hover · 0x29 page flip · 0x2B page end · 0x2C toggle/next mode · 0x2D open city change · 0x2E globe fly-to · 0x2F choose region · 0x30 list scroll · 0x02..0x0B globe zoom levels · 0x0C..0x11 tilt levels · 0x12 twist · 0x14 rotate loop.
Meanings are inferred from the call sites; the sound fork maps IDs to brsar names.

---------------------------------------------------------------------------------------------------
## 10. Open questions / to verify
1. Colour scheme table: m2c's word stores (`.unk0 = (s32) sp94`) are not captured by `eval_stores.py`. Check entries +00/+24..+38 against the asm of `InitButtonColorSchemes`.
2. The exact `MapNwc24ErrorToCode` → error0 text index arithmetic (inside `CConnect_Update` / `fn_8000B46C`).
3. Page vtable slot meanings beyond Draw (`+14`); the JP life sub-pages (laundry/pollen) are irrelevant for the US build.
4. StFAE4/StE6xx glue states: confirm which one performs OSReturnToMenu vs. the HOME-menu reset.
5. Opera trigger conditions (first-run legal notice) and the `lbl_8032FD00` source (launch argument / first run?).
6. CCityMarker draw code (0x80007000–0x8000A8D0) is summarised only; the icon/number placement constants are in `fn_80008094`/`fn_80008AF4`/`fn_80008B3C`/`fn_80009E5C`.
7. The forecast data field offsets quoted here (`+F/+10` temperature, `+12/+13` wind, `+11` wind direction, `hdr+0x19` units, day record stride 0x66) come from the screen code; the data fork should confirm them against the parser.

## 11. Symbols renamed in this pass
FormatIntW, MinutesToDate, CLayout_* (ctor/dtor/Reset/Update/Draw/FindPane/HitTest), CPaneCtl_* (ctor/Update/PreDraw/SetHoverTree/Press/Flash/SetTextIndex/ResetPos), Pane_SetChildVisible, Pane_SetTevColorRec, Pane_SetAlphaRec, Pane_GetScreenCenter, InitButtonColorSchemes, GetLangSuffix, CFade_* (ctor/dtor/StartFadeIn/StartFadeOut/StateIdle/StateFadeIn/StateFadeOut), Mem_Alloc/Mem_Free, LoadArcFileLZ, System_Init/Frame/ChangeScene, CScene_ctor, CScene_Draw, CWeatherScene_ctor, WeatherScene_* states, CConnect_*, SaveData_Load/Store/SetSize, CMessage_ctor/Open/Update, MapNwc24ErrorToCode, CErrorSystem_ctor/Update, CFatalScene_ctor, CContentArc_ctor, UI_UpdateHover/UI_ButtonTrig/UI_ClearHover, Setup2DRender, SetOrtho2D, DrawSpriteNumberCentered, DrawSpriteString, TPL_GetImageWidth/Height, WPAD_RumblePattern, LerpU8, CopyColor, ForecastFindById, CForecastData_ctor, CNormal_*, CAround_*, CAddress_*, CSetting_*, Snd_StartSoundHandle, CreateEarthModel, __ptmf_test/__ptmf_scall/__construct_array/__destroy_arr, sprintf, strcmp.
