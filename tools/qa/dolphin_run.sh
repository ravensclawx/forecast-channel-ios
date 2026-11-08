#!/bin/zsh
# usage: dolphin_run.sh USERDIR SECONDS [extra -C options...]  — boots HAFE.wad headless, dumps frames, exits cleanly.
U=$1; T=$2; shift 2
rm -rf $U/Backup $U/Dump/Frames
python3 -I $(dirname $0)/sysconf.py $U/Wii/shared2/sys/SYSCONF IPL.IDL=${IDL:-0101} >/dev/null 2>&1
/Applications/Dolphin.app/Contents/MacOS/Dolphin -u $U -b -e ~/Library/Application\ Support/ForecastChannel/HAFE.wad \
  -C Dolphin.Movie.DumpFrames=True -C GFX.Settings.DumpFramesAsImages=True "$@" > $U/run.log 2>&1 &
P=$!
sleep $T
kill -TERM $P; sleep 4; kill -9 $P 2>/dev/null
ls $U/Dump/Frames | wc -l
