#!/usr/bin/env fish
# Build the Allspeak "opening clip": a short muxed video of the film's opening so
# Pavel can see what is on screen around the first subtitle cues before the cinema
# (the sync line is not always the 1st line; the app plays this and lists the
# first five cues with timecodes).
#
#   build_clip.fish SRC_VIDEO FINAL_SRT OUTPUT.mp4 [--retime R] [--head-offset S] [--astream N] [--crf N] [--keep-work]
#
# Window (from the FINAL ear-track srt -- the same .srt shipped to the catalog):
#   start = max(0, first_cue_start - 15 s)      end = fifth_cue_end + 5 s
# The app shows exactly the first five cues, so the clip must cover all of them.
# (Fewer than five cues -> uses the last one.)
#
# SRC_VIDEO must be the SAME source you built the .m4a/.srt from, so the clip
# timeline matches. Two knobs map the srt timeline back onto the raw source:
#   --retime R      playback-speed factor used to build the ear track (e.g. 1.001
#                   for a 23.976->24 fps cinema retime; default 1.0). srt_time =
#                   source_time / R, so we seek the source at w*R and apply
#                   setpts=PTS/R + atempo=R to land the clip on the srt timeline.
#   --head-offset S source seconds removed BEFORE the window (a rare early ad cut).
#                   Opening clips sit ahead of the late-hiding ads, so this is 0
#                   for almost every film; set it only if apply_cuts removed a span
#                   before the first five cues. Default 0.
#
# --astream N picks which audio stream to take (default 0 = first). Use it when the
# source carries several dubs and the shipped one is not a:0 (e.g. an anime AVI with
# a:0 a rejected dub and a:1 the good one) -> --astream 1. The clip should carry the
# same dub you built the .m4a from.
#
# Encoding: H.264 640x360 (letterbox-pad, never distort), yuv420p, AAC stereo
# downmixed from the source, +faststart. A ~1-2 min clip lands at ~3-8 MB, well
# under 15 MB.
#
# VERIFY before publishing: the script prints the fifth cue's expected clip-relative
# offset. Spot-check that its speech lands there; if it drifts you cut from the
# wrong source or before ad removal -> fix --retime/--head-offset or the source.

argparse 'retime=' 'head-offset=' 'crf=' 'astream=' 'keep-work' -- $argv
or exit 1

if test (count $argv) -ne 3
    echo "usage: build_clip.fish SRC_VIDEO FINAL_SRT OUTPUT.mp4 [--retime R] [--head-offset S] [--crf N]" >&2
    exit 1
end

set -l src (realpath $argv[1])
set -l srt (realpath $argv[2])
set -l dst $argv[3]
set -l R 1.0; set -q _flag_retime; and set R $_flag_retime
set -l head 0; set -q _flag_head_offset; and set head $_flag_head_offset
set -l crf 23; set -q _flag_crf; and set crf $_flag_crf
set -l astream 0; set -q _flag_astream; and set astream $_flag_astream

test -f $src; or begin; echo "no source video: $src" >&2; exit 1; end
test -f $srt; or begin; echo "no srt: $srt" >&2; exit 1; end

# First five cues of the final srt -> prints: c1_start, c5_end, c5_start (seconds).
set -l cue (python3 -c "
import sys,re
t=open(sys.argv[1],encoding='utf-8',errors='ignore').read()
def sec(x):
    x=x.replace(',','.');h,m,s=x.split(':');return int(h)*3600+int(m)*60+float(s)
c=[(sec(a),sec(b)) for a,b in re.findall(r'(\d\d:\d\d:\d\d[,.]\d+)\s*-->\s*(\d\d:\d\d:\d\d[,.]\d+)',t)]
c=c[:5]
print(c[0][0]);print(c[-1][1]);print(c[-1][0])
" $srt)
or begin; echo "could not parse cues from $srt" >&2; exit 1; end

set -l c1 $cue[1]
set -l c5end $cue[2]
set -l c5start $cue[3]

set -l w0 (math "max(0, $c1 - 15)")
set -l w1 (math "$c5end + 5")
set -l dur (math "$w1 - $w0")

# srt timeline -> source timeline
set -l src0 (math "$w0 * $R + $head")
set -l srcdur (math "$dur * $R")
set -l off5 (math "$c5start - $w0")

echo "[clip] cues: first@"$c1"s  fifth@"$c5start"s  fifth_end@"$c5end"s"
echo "[clip] window (srt): "$w0" -> "$w1"  (dur "$dur"s)"
echo "[clip] source cut: ss "$src0"  t "$srcdur"  (retime x"$R", head +"$head"s)"

set -l vf "setpts=PTS/$R,scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:(ow-iw)/2:(oh-ih)/2,format=yuv420p"
set -l af "atempo=$R"

ffmpeg -nostdin -v error -y -ss $src0 -t $srcdur -i $src \
    -map 0:v:0 -map 0:a:$astream? -dn -map_chapters -1 \
    -vf $vf -af $af \
    -c:v libx264 -preset medium -crf $crf -pix_fmt yuv420p \
    -c:a aac -b:a 128k -ac 2 -movflags +faststart $dst
or begin; echo "ffmpeg failed" >&2; exit 1; end

set -l outdur (ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 $dst)
set -l bytes (stat -f%z $dst)
set -l mb (math "round($bytes / 1048576 * 10) / 10")
echo "[done] $dst"
echo "       duration "$outdur"s   size "$mb" MB ("$bytes" bytes)"
echo "       VERIFY: 5th cue speech should land at clip offset ~"$off5"s"
if test $bytes -gt 15728640
    echo "       WARNING: over 15 MB -- raise --crf (e.g. 26-28) and rebuild" >&2
end
