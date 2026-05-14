#!/usr/bin/env fish
# bifrost.fish — pull one audio + one subtitle stream from an MKV for Allspeak.
#
# Default pick: first English audio, first English non-forced non-SDH .srt.
# Output: <basename>.<lang>.m4a (AAC 128k stereo) and <basename>.<lang>.srt
#         next to the cwd, or -o DIR.
#
# Usage:
#   bifrost.fish FILE.mkv                 # auto-pick eng audio + eng .srt
#   bifrost.fish -l FILE.mkv              # list streams only, do not extract
#   bifrost.fish -a 4 -s 10 FILE.mkv      # pick stream indices manually
#   bifrost.fish -o ~/out FILE.mkv        # output directory (default: cwd)
#
# Deps: ffmpeg, ffprobe, jq.

argparse 'l/list' 'a/audio=' 's/subs=' 'o/outdir=' 'h/help' -- $argv
or exit 1

if set -q _flag_help; or test (count $argv) -ne 1
    echo "usage: bifrost.fish [-l] [-a N] [-s N] [-o DIR] FILE.mkv"
    exit 1
end

set -l src $argv[1]
if not test -f $src
    echo "no such file: $src" >&2
    exit 1
end

for cmd in ffmpeg ffprobe jq
    if not command -q $cmd
        echo "missing dependency: $cmd  (brew install $cmd)" >&2
        exit 1
    end
end

set -l probe (ffprobe -v error \
    -show_entries 'stream=index,codec_type,codec_name,channels:stream_tags=language,title:stream_disposition=default,forced,hearing_impaired' \
    -of json $src | string collect)

function _list_streams -a probe
    echo $probe | jq -r '.streams[] |
        select(.codec_type=="audio" or .codec_type=="subtitle") |
        [
          (.index|tostring),
          (if .codec_type=="audio" then "AUDIO" else "SUBS " end),
          .codec_name,
          (.tags.language // "und"),
          (.tags.title // ""),
          (if .disposition.default==1 then "default" else "" end),
          (if .disposition.forced==1 then "forced" else "" end),
          (if .disposition.hearing_impaired==1 then "SDH" else "" end)
        ] | @tsv' | awk -F'\t' '
        {
            flags = ""
            for (i=6; i<=8; i++) {
                if ($i != "") {
                    flags = (flags == "" ? $i : flags "," $i)
                }
            }
            if (flags != "") flags = "  [" flags "]"
            printf "  #%-3s  %-5s  %-7s  %-4s  %-30s%s\n", $1, $2, $3, $4, $5, flags
        }'
end

echo "Streams in $src:"
_list_streams $probe
echo

if set -q _flag_list
    exit 0
end

set -l audio_idx $_flag_audio
set -l subs_idx $_flag_subs

if test -z "$audio_idx"
    set audio_idx (echo $probe | jq -r \
        '[.streams[] | select(.codec_type=="audio" and (.tags.language // "")=="eng")] | .[0].index // empty')
    if test -z "$audio_idx"
        echo "no English audio found, pass -a N to pick manually" >&2
        exit 1
    end
end

if test -z "$subs_idx"
    set subs_idx (echo $probe | jq -r \
        '[.streams[] | select(.codec_type=="subtitle"
            and (.tags.language // "")=="eng"
            and (.disposition.hearing_impaired // 0)==0
            and (.disposition.forced // 0)==0)] | .[0].index // empty')
    if test -z "$subs_idx"
        echo "no English non-SDH non-forced subtitle found, pass -s N to pick manually" >&2
        exit 1
    end
end

set -l audio_lang (echo $probe | jq -r ".streams[] | select(.index==$audio_idx) | (.tags.language // \"und\")")
set -l subs_lang (echo $probe | jq -r ".streams[] | select(.index==$subs_idx) | (.tags.language // \"und\")")

set -l outdir
if set -q _flag_outdir
    set outdir $_flag_outdir
else
    set outdir (pwd)
end
mkdir -p $outdir

set -l basename (basename $src .mkv)
set -l audio_out $outdir/$basename.$audio_lang.m4a
set -l subs_out  $outdir/$basename.$subs_lang.srt

echo "→ audio #$audio_idx ($audio_lang) → $audio_out"
ffmpeg -hide_banner -loglevel warning -stats -y -i $src \
    -map 0:$audio_idx -vn -sn \
    -c:a aac -b:a 128k -ac 2 -movflags +faststart $audio_out
or begin
    echo "ffmpeg audio extraction failed" >&2
    exit 1
end

echo "→ subs  #$subs_idx ($subs_lang) → $subs_out"
ffmpeg -hide_banner -loglevel warning -y -i $src \
    -map 0:$subs_idx -c:s srt $subs_out
or begin
    echo "ffmpeg subs extraction failed" >&2
    exit 1
end

echo
echo "done."
echo "  audio: $audio_out"
echo "  subs:  $subs_out"
