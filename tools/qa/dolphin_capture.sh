#!/bin/zsh
# usage: dolphin_capture.sh USERDIR NAME SECONDS [patch-line ...]
# patch-line: Dolphin OnFrame syntax "0xADDR:dword:0xVALUE". Saves the last dumped frame + a few earlier ones.
U=$1; NAME=$2; T=$3; shift 3
REF=$(dirname $0)/../../research/reference; mkdir -p $REF
{
  echo "[WC24Patch]"; echo '$Local'; echo "weather.wapp.wii.com:127.0.0.1:8099:1"; echo
  echo "[WC24Patch_Enabled]"; echo '$Local'; echo
  echo "[OnFrame]"; echo '$Force'; for p in "$@"; do echo $p; done; echo
  echo "[OnFrame_Enabled]"; echo '$Force'
} > $U/GameSettings/HAFE.ini
$(dirname $0)/dolphin_run.sh $U $T -C Dolphin.Core.EnableCheats=True >/dev/null
F=$U/Dump/Frames; N=$(ls $F | wc -l | tr -d ' ')
cp $F/framedump_$((N-2)).png $REF/$NAME.png
for k in 1 2 3; do cp $F/framedump_$((N*k/4)).png $REF/seq/${NAME}_$k.png 2>/dev/null; done
echo "$NAME: $N frames → $REF/$NAME.png"
