#!/usr/bin/env fish
# bifrost.fish — universal knife for Allspeak audio prep.
#
# Default pipeline (any input → voice-only track timed for the cinema):
#   1. Decode input to WAV (44.1k stereo)
#   2. (If MKV/video) Retime audio source-FPS → cinema-FPS (default 24)
#   3. Demucs (htdemucs_ft) — extract vocal stem (drop music & SFX)
#   4. ffmpeg loudnorm — normalize loudness
#   5. Sidon (sarulab-speech/sidon-v0.1) — speech restoration (for low-quality input)
#   6. Encode to AAC mono 96k (.m4a) for the iPhone app
#
# Why retime: BD/web-dl is usually 23.976 fps; cinemas project at 24 fps.
# Over a 2h film that's ~7s of drift. We speed audio up by 24/23.976 ≈ 1.001 —
# pitch shift of 0.1% is inaudible. Cam recordings skip this (already cinema-timed).
#
# Why Demucs even on clean MKV: dub tracks on streaming = M&E + dialogue mixed;
# we want voice only since cinema speakers carry the M&E live.
#
# Usage:
#   bifrost.fish FILE                     # full pipeline → FILE.m4a
#   bifrost.fish -m FILE                  # multi-track: .sidon.m4a + .vocals.m4a + .original.m4a
#   bifrost.fish -o ~/out FILE            # output dir (default: cwd)
#   bifrost.fish --wav FILE               # output WAV instead of AAC
#   bifrost.fish --no-sidon FILE.mkv      # skip Sidon (for already-clean inputs)
#   bifrost.fish --no-retime FILE.mkv     # skip FPS retiming
#   bifrost.fish --cinema-fps 25 FILE     # target cinema FPS (default 24)
#   bifrost.fish --source-fps 23.976 FILE # override source FPS (default: auto from video)
#   bifrost.fish -l FILE.mkv              # list MKV streams, exit
#   bifrost.fish -a 4 FILE.mkv            # pick MKV audio stream 4
#   bifrost.fish -s 10 FILE.mkv           # also extract subtitle stream 10 → .srt
#   bifrost.fish --lang eng FILE.mkv      # MKV auto-pick language (default: rus)
#
# Deps: ffmpeg, ffprobe, jq, uv.

argparse 'l/list' 'a/audio=' 's/subs=' 'o/outdir=' 'm/multi-track' \
         'no-sidon' 'no-retime' 'cinema-fps=' 'source-fps=' \
         'lang=' 'wav' 'h/help' -- $argv
or exit 1

if set -q _flag_help; or test (count $argv) -ne 1
    echo "usage: bifrost.fish [-m] [-l] [-a N] [-s N] [-o DIR] [--lang L]"
    echo "                    [--no-sidon] [--no-retime] [--cinema-fps F] [--source-fps F]"
    echo "                    [--wav] FILE"
    exit 1
end

set -l src $argv[1]
test -f $src; or begin; echo "no such file: $src" >&2; exit 1; end

for cmd in ffmpeg ffprobe jq uv
    command -q $cmd; or begin
        echo "missing dependency: $cmd  (brew install $cmd)" >&2
        exit 1
    end
end

set -l script_dir (dirname (status -f))
set -l sidon_py $script_dir/sidon_infer.py
test -f $sidon_py; or begin; echo "missing $sidon_py" >&2; exit 1; end

set -l outdir (pwd)
set -q _flag_outdir; and set outdir $_flag_outdir
mkdir -p $outdir

set -l basename (basename $src)
set basename (string replace -r '\.[^.]+$' '' $basename)

set -l lang $_flag_lang
test -z "$lang"; and set lang rus

set -l cinema_fps $_flag_cinema_fps
test -z "$cinema_fps"; and set cinema_fps 24

set -l ext m4a
set -q _flag_wav; and set ext wav

# ───────────────────────────────────────────────────────────────────────────
# Probe input
# ───────────────────────────────────────────────────────────────────────────

set -l probe (ffprobe -v error \
    -show_entries 'stream=index,codec_type,codec_name,channels,avg_frame_rate:stream_tags=language,title:stream_disposition=default,forced,hearing_impaired' \
    -of json $src 2>/dev/null | string collect)

set -l audio_count (echo $probe | jq -r '[.streams[] | select(.codec_type=="audio")] | length')
set -l video_count (echo $probe | jq -r '[.streams[] | select(.codec_type=="video")] | length')

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
            for (i=6; i<=8; i++) if ($i != "") flags = (flags == "" ? $i : flags "," $i)
            if (flags != "") flags = "  [" flags "]"
            printf "  #%-3s  %-5s  %-7s  %-4s  %-30s%s\n", $1, $2, $3, $4, $5, flags
        }'
end

if set -q _flag_list
    echo "Streams in $src:"
    _list_streams $probe
    exit 0
end

# MKV stream picking
set -l audio_idx $_flag_audio
if test -z "$audio_idx"; and test "$audio_count" -gt 1
    set audio_idx (echo $probe | jq -r \
        "[.streams[] | select(.codec_type==\"audio\" and (.tags.language // \"\")==\"$lang\")] | .[0].index // empty")
    if test -z "$audio_idx"
        echo "multiple audio streams, no $lang track. pass -a N or use -l" >&2
        _list_streams $probe
        exit 1
    end
    echo "[bifrost] auto-picked audio stream #$audio_idx ($lang)"
end

# Source FPS detection.
# Goal: webdl/BD (~24 fps cadence) needs retime to cinema; cam recordings (wall-clock
# audio, regardless of video fps) do NOT. We classify by video fps if present, else
# assume audio-only inputs were extracted from a 23.976 digital release.
set -l source_fps $_flag_source_fps
set -l do_retime 1
if set -q _flag_no_retime
    set do_retime 0
else if test -n "$source_fps"
    : # user provided, trust them
else if test "$video_count" -gt 0
    # avg_frame_rate is "num/den", e.g. "24000/1001"
    set -l fr (echo $probe | jq -r '[.streams[] | select(.codec_type=="video")][0].avg_frame_rate')
    set -l video_fps (math "$fr")
    # Cam recordings from phones are 30/60+ fps; digital releases sit in 23-25 fps.
    if test (math "$video_fps > 28") -eq 1
        set do_retime 0
        echo "[bifrost] video at $video_fps fps → looks like cam recording (audio is wall-clock), no retime"
    else
        set source_fps $video_fps
    end
else
    # No video stream: assume audio extracted from a 23.976 webdl/BD release.
    set source_fps 23.976
    echo "[bifrost] no video stream, assuming source FPS = 23.976 (typical webdl/BD)"
    echo "[bifrost]   override with --source-fps N or skip retime with --no-retime"
end

set -l fps_ratio 1
if test $do_retime -eq 1
    set fps_ratio (math "$cinema_fps / $source_fps")
    # Skip if numerically identical (ratio 1.0 is a no-op anyway, this just avoids the asetrate filter)
    if test "$fps_ratio" = "1"
        echo "[bifrost] source $source_fps fps == cinema $cinema_fps fps → no retime needed"
        set do_retime 0
    end
end

set -l work (mktemp -d -t bifrost-XXXXXX)
echo "[bifrost] work: $work"
echo "[bifrost] out:  $outdir"
test $do_retime -eq 1; and echo "[bifrost] retime: $source_fps → $cinema_fps fps (ratio $fps_ratio)"

# ───────────────────────────────────────────────────────────────────────────
# Step 1: decode (and optionally retime) → WAV
# ───────────────────────────────────────────────────────────────────────────

set -l map_args
test -n "$audio_idx"; and set map_args -map 0:$audio_idx

set -l filters
if test $do_retime -eq 1
    set filters -af "asetrate=44100*$fps_ratio,aresample=44100"
end

echo "[1] decoding → wav"
ffmpeg -y -hide_banner -loglevel warning -i $src $map_args -vn -sn $filters -ac 2 -ar 44100 -c:a pcm_s16le $work/in.wav
or begin; echo "ffmpeg decode failed" >&2; exit 1; end

# Optional: extract subs
if set -q _flag_subs
    set -l subs_out $outdir/$basename.srt
    echo "[bonus] subs #$_flag_subs → $subs_out"
    ffmpeg -y -hide_banner -loglevel warning -i $src -map 0:$_flag_subs -c:s srt $subs_out
    or echo "subs extraction failed (continuing)" >&2
end

function _encode_for_app -a in_wav out_path
    if string match -q '*.wav' $out_path
        cp $in_wav $out_path
    else
        ffmpeg -y -hide_banner -loglevel warning -i $in_wav -c:a aac -b:a 96k -ac 1 -movflags +faststart $out_path
    end
end

# ───────────────────────────────────────────────────────────────────────────
# Step 2: Demucs (always — we want voice-only)
# ───────────────────────────────────────────────────────────────────────────

echo "[2] demucs htdemucs_ft (vocal stem)..."
uvx --from demucs --with torchcodec demucs -n htdemucs_ft --two-stems vocals -o $work/sep $work/in.wav
or begin; echo "demucs failed" >&2; exit 1; end

set -l vocals $work/sep/htdemucs_ft/in/vocals.wav
test -f $vocals; or begin; echo "demucs vocals not found: $vocals" >&2; exit 1; end

# ───────────────────────────────────────────────────────────────────────────
# Step 3: loudnorm
# ───────────────────────────────────────────────────────────────────────────

echo "[3] loudnorm..."
# Force output back to 44.1k s16: loudnorm internally upsamples to 192k float,
# default output keeps that (5.8GB for a 2h film, breaks WAV 4GB header limit).
ffmpeg -y -hide_banner -loglevel warning -i $vocals -af loudnorm=I=-16:TP=-1.5:LRA=11 \
    -ar 44100 -c:a pcm_s16le $work/vocals_norm.wav
or begin; echo "loudnorm failed" >&2; exit 1; end

# ───────────────────────────────────────────────────────────────────────────
# Step 4: Sidon (skip with --no-sidon for already-clean inputs)
# ───────────────────────────────────────────────────────────────────────────

set -l final $work/vocals_norm.wav
if not set -q _flag_no_sidon
    echo "[4] sidon restoration..."
    uv run --script $sidon_py \
        --input $work/vocals_norm.wav \
        --output $work/sidon.wav \
        --chunk-seconds 30 --context-frames 25
    or begin; echo "sidon failed" >&2; exit 1; end
    set final $work/sidon.wav
end

# ───────────────────────────────────────────────────────────────────────────
# Step 5: emit
# ───────────────────────────────────────────────────────────────────────────

echo "[5] encoding output(s)..."
if set -q _flag_multi_track
    set -l out_primary $outdir/$basename.sidon.$ext
    set -l out_vocals  $outdir/$basename.vocals.$ext
    set -l out_original $outdir/$basename.original.$ext
    _encode_for_app $work/sidon.wav $out_primary 2>/dev/null
    or _encode_for_app $work/vocals_norm.wav $out_primary  # if --no-sidon was set
    _encode_for_app $work/vocals_norm.wav $out_vocals
    _encode_for_app $work/in.wav $out_original
    echo "done. multi-track set:"
    echo "  primary : $out_primary"
    echo "  backup1 : $out_vocals     (demucs+loudnorm, no sidon)"
    echo "  backup2 : $out_original   (raw input, retimed)"
else
    set -l out $outdir/$basename.$ext
    _encode_for_app $final $out
    echo "done."
    echo "  $out"
end

rm -rf $work
