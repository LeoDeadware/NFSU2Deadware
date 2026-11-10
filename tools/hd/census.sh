#!/bin/zsh
# Texture census for the HD pack: scripted runs with NFSU2_TEX_DUMP (no HD pack,
# original glyphs) into work/hd/census/<run>/. Then:
#   python3 tools/hd/build_pack.py work/hd/census/* --out work/hd/pack
# Dumps are the game's pictures: work/ is git-ignored, nothing is published.
set -u
cd "$(dirname "$0")/../.."
C=$PWD/work/hd/census; mkdir -p $C
S="9000:start:200,11000:start:200,13000:start:200,15000:start:200"
A="18000:a:200,21000:a:200,24000:a:200,27000:a:200,30000:a:200,33000:a:200,36000:a:200,39000:a:200,42000:a:200,45000:a:200"
run() {  # name secs script
  rm -rf $C/$1; tools/dev/run.sh hd-$1 $2 NFSU2_HD=0 NFSU2_PROMPTS=0 NFSU2_TEX_DUMP=$C/$1 NFSU2_WINDOW=1386x900 \
    RECOMP_PAD_SCRIPT="$3" || return $?
  echo "census $1: $(ls $C/$1 | wc -l | tr -d ' ') textures"
}
# A circuit race, driving (throttle held) for 40 s.
run race 100 "$S,$A,48000:rt:40000" || exit $?
# Main menu items left and right, into a few screens and back out.
run menus 70 "$S,18000:right:200,20000:right:200,22000:right:200,24000:right:200,26000:right:200,28000:a:200,32000:a:200,36000:b:200,39000:b:200,42000:left:200,44000:left:200,46000:left:200,48000:left:200,50000:left:200,52000:left:200,54000:a:200,58000:a:200,62000:b:200,65000:b:200" || exit $?
