#!/usr/bin/env fish
# Build the Allspeak ear track from an ad-cut RU audio file.
#
#   build_voice.fish INPUT.wav OUTPUT.m4a [--draft-srt FILE.srt] [--skip-patch]
#
# INPUT must be 48 kHz mono with ads already cut (apply_cuts.py), because every
# stage downstream lives on that timeline.
#
# Chain: Bandit v2 (speech/music/sfx) -> shout patch -> MossFormer2 -> cue-aware
# leveler -> static-gain normalize -> AAC. Run setup_bandit.fish once first.
#
# Wall clock on an M1 Max for a 2:45 film: ~1h50 separation, ~3 min patch,
# ~5 min restoration, ~1 min leveler, ~3 min encode.

argparse 'draft-srt=' 'skip-patch' 'keep-work' -- $argv
or exit 1

if test (count $argv) -ne 2
    echo "usage: build_voice.fish INPUT.wav OUTPUT.m4a [--draft-srt FILE.srt] [--skip-patch]" >&2
    exit 1
end

set -l src (realpath $argv[1])
set -l dst $argv[2]
set -l root $HOME/.cache/cinema-prep
set -l msst $root/msst
set -l scripts (dirname (status -f))
set -l work (dirname $src)/.voice-build
mkdir -p $work/in $work/sep

test -f $root/bandit_multi_fixed.ckpt
or begin; echo "run setup_bandit.fish first" >&2; exit 1; end

set -l rate (ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of default=nw=1:nk=1 $src)
set -l ch (ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=nw=1:nk=1 $src)
if test "$rate" != 48000 -o "$ch" != 1
    echo "input must be 48 kHz mono (got $rate Hz, $ch ch)" >&2
    exit 1
end

echo "[1/6] Bandit v2 separation"
cp $src $work/in/track.wav
set -l t0 (date +%s)
$msst/.venv/bin/python $msst/inference.py \
    --model_type bandit_v2 \
    --config_path $msst/configs/config_dnr_bandit_v2_mus64.yaml \
    --start_check_point $root/bandit_multi_fixed.ckpt \
    --input_folder $work/in --store_dir $work/sep
or begin; echo "bandit failed" >&2; exit 1; end
echo "[1/6] done in "(math (date +%s) - $t0)"s"

set -l stem $work/sep/track/speech.wav
test -f $stem; or begin; echo "no speech stem at $stem" >&2; exit 1; end

set -l voice $stem
if not set -q _flag_skip_patch; and set -q _flag_draft_srt
    echo "[2/6] shout patch"
    # --source enables source-vs-stem drop detection: catches killed AND attenuated
    # cries even when ASR never transcribed them in the noisy source (the T2 blind spot).
    uv run --no-project $scripts/patch_shouts.py detect $stem $_flag_draft_srt \
        --out $work/windows.json --source $src
    or exit 1
    mkdir -p $work/win $work/winsep
    for w in (uv run --no-project --with numpy python -c "
import json
for x in json.load(open('$work/windows.json')):
    print(f\"{x['start']}:{x['duration']}\")
")
        set -l ss (string split ':' $w)[1]
        set -l dur (string split ':' $w)[2]
        ffmpeg -nostdin -v error -y -ss $ss -t $dur -i $src -ar 44100 -ac 2 $work/win/w$ss.wav
    end
    for f in $work/win/*.wav
        test -f $f; or continue
        uvx --from 'mlx-audio-separator[convert]' mlx-audio-separator $f \
            -m melband_roformer_big_beta6x.ckpt --single_stem vocals \
            --output_format WAV --output_dir $work/winsep >/dev/null 2>&1
    end
    # --srt gain-matches each recovered segment to the dialogue-median level, so
    # restored cries sit at talk level instead of whatever MelBand output.
    uv run --no-project $scripts/patch_shouts.py splice $stem $work/windows.json $work/winsep \
        --out $work/patched.wav --srt $_flag_draft_srt
    or exit 1
    set voice $work/patched.wav
else
    echo "[2/6] shout patch skipped"
end

echo "[3/6] MossFormer2 restoration"
uv run --no-project $scripts/restore_moss.py $voice $work/restored.wav
or begin; echo "mossformer failed" >&2; exit 1; end

# Boost-only, cue-anchored leveler: raises quiet/shouted cues toward the dialogue
# median (gaps untouched -> clean-silence fix stays intact). Needs cues, so only
# runs when a draft srt is available.
echo "[4/6] cue-aware leveler"
set -l leveled $work/restored.wav
if set -q _flag_draft_srt
    uv run --no-project $scripts/level_cues.py $work/restored.wav $_flag_draft_srt $work/leveled.wav
    and set leveled $work/leveled.wav
    or begin; echo "leveler failed" >&2; exit 1; end
else
    echo "      no draft srt, leveler skipped"
end

echo "[5/6] measure integrated loudness"
set -l meas (ffmpeg -nostdin -hide_banner -i $leveled \
    -af loudnorm=I=-14:TP=-2:LRA=20:print_format=json -f null - 2>&1 | tail -14)
set -l m_i (echo $meas | string match -r '"input_i"\s*:\s*"(-?[0-9.]+)"')[2]
echo "      measured I=$m_i LUFS"

echo "[6/6] static-gain normalize + limiter + AAC"
# loudnorm's dynamic/linear pass injected loud LF+HF garbage into the digital-silence
# speech-gaps of the clean stem (crackle / HF hash in quiet scenes -- Mutiny 2026
# cinema report). A flat gain to the same integrated target leaves those gaps truly
# silent; hp40 drops subsonic DC, alimiter caps true peak at -2 dBFS, 256k (not 96k)
# stops AAC from re-seeding HF hash into the silence.
set -l gain (math "-14 - ($m_i)")
set -l gaindb (printf '%sdB' $gain)
ffmpeg -nostdin -v error -y -i $leveled \
    -af "volume=$gaindb,highpass=f=40:poles=2,alimiter=limit=0.794:level=false" \
    -ar 48000 -ac 1 -c:a aac -b:a 256k -movflags +faststart $dst
or begin; echo "encode failed" >&2; exit 1; end

ffprobe -v error -show_entries format=duration -of default=nw=1 $dst
set -q _flag_keep_work; or rm -rf $work/in $work/win $work/winsep
echo "[done] $dst"
