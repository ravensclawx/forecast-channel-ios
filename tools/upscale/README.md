# AI texture upscaling (iPhone)

The phone shows the 608-wide logical screen at ~1200 px, so the original textures look pixelated. `fcupscale`
makes AI ×4 versions of every 2D texture and the Latin font sheets; the app uploads them in place of the originals
while keeping every original size for geometry/UV math. Output is Nintendo-derived: it lives in
`~/Library/Application Support/ForecastChannel/upscaled/` and is never committed.

    # once: Real-ESRGAN (ncnn/Vulkan via MoltenVK, runs on the Mac GPU) into the gitignored toolchain/
    curl -L -o toolchain/realesrgan/r.zip https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-macos.zip
    (cd toolchain/realesrgan && unzip -o r.zip && chmod +x realesrgan-ncnn-vulkan && xattr -dr com.apple.quarantine .)

    swift run -c release fcupscale all <workDir>     # dump + process (~2 min, ~14 MB of PNGs)
    tools/ios/stage_assets.sh                        # copies them into the iPhone bundle
    FC_UPSCALE=1 swift run fcdump --portrait …       # preview on the Mac (off by default there)

- Selection: all weather layout + content-9 images, HOME Menu shared/English images, and every font sheet holding
  Latin-range glyphs. Optional `<workDir>/used.txt` (from `FC_UPSCALE_RECORD=<file>` runs) adds whatever else the
  app uploaded.
- Model: realesrgan-x4plus (best line art, faithful shading). Colour (alpha-bled) and alpha are upscaled as
  separate planes; I4 font sheets as one coverage plane; textures padded by wrapping/clamping per their wrap mode;
  low-precision sources (RGB5A3/RGB565/CMPR/palette) get a light 3×3 soften first so banding isn't sharpened into
  painted patches; tiny textures/strips are resampled, not hallucinated.
- Tiers: fonts and images ≥256 texels ship at ×2, small sprites/UI art at ×4.
- Tools: `compare.swift` (side-by-side crops), `align.swift` (tile alignment), `centroid.swift` (alpha centroid
  shift per texture).
