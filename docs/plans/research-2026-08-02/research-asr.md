# ASR stage research — cinema-prep (Russian voiceover → text + .srt cues)

Date: 2026-08-02. All numbers below are from primary sources (repo files, HF cards, arXiv). Claims I could not verify are marked **[HYPOTHESIS]**.

---

## TL;DR

1. **Keep GigaAM v3.** Nothing else is close on Russian. The gap is not marginal — v3_rnnt averages 8.3 WER across 10 Russian sets vs Whisper large-v3 at 21.0 on the same sets.
2. **Stop using `v3_e2e`. Switch to `v3_rnnt` + a separate punctuation/casing pass.** The repo's own eval shows e2e costs ~2.9 WER points on average *after* both are normalized identically. You are paying real accuracy for convenience punctuation.
3. **Add a forced-alignment pass. This is the single highest-value change for your #1 priority.** GigaAM timestamps are quantized to 40 ms and are structurally biased late (CTC/RNNT emission peakiness). `Qwen3-ForcedAligner-0.6B` reports **40.2 ms** mean shift on Russian vs **200.7 ms** for NeMo Forced Aligner, is Apache-2.0, and has a **native MLX Apple Silicon port**.
4. **Do not switch to the June-2026 GigaAM Multilingual.** It exists for Kazakh/Kyrgyz/Uzbek. It is CTC-only, has no punctuation, and its Russian numbers do not beat v3.
5. Your current pipeline's cue *start* times come from **pyannote VAD boundaries**, not from the ASR — worth knowing, because that is a different failure mode than you might assume.

---

## 1. The GigaAM line as of August 2026

### 1.1 Model inventory

From the repo README model table (`salute-developers/GigaAM`, MIT):

| Line | Pretrain objective | Pretrain hrs | ASR FT hrs | Variants |
|---|---|---|---|---|
| v1 | Wav2Vec 2.0 | 50,000 | 2,000 | `v1_ssl`, `emo`, `v1_ctc`, `v1_rnnt` |
| v2 | HuBERT-CTC | 50,000 | 2,000 | `v2_ssl`, `v2_ctc`, `v2_rnnt` |
| v3 | HuBERT-CTC | 700,000 | 4,000 | `v3_ssl`, `v3_ctc`, `v3_rnnt`, `v3_e2e_ctc`, `v3_e2e_rnnt` |
| Multilingual | HuBERT-style | 2,000,000 | 50,000 | `multilingual_ssl`, `multilingual_large_ssl`, `multilingual_ctc`, `multilingual_large_ctc` |

Encoder: Conformer, 16 layers, d_model 768, ~220–240M params (v3). Multilingual adds a 600M variant (24 layers, d_model 1024, RoPE).

### 1.2 Russian WER — the numbers that matter

Verbatim from `evaluation.md` in the repo. Columns marked `*` had post-processing applied (punctuation/casing stripped, numerals replaced) so the comparison against non-e2e models is apples-to-apples.

| Set | V3 CTC | **V3 RNNT** | E2E CTC* | **E2E RNNT*** | V2 RNNT | T-One+LM | Whisper* |
|---|---:|---:|---:|---:|---:|---:|---:|
| Golos Farfield | 4.5 | **3.9** | 6.1 | 5.5 | 4.0 | 12.2 | 16.4 |
| Golos Crowd | 2.8 | **2.4** | 9.7 | 9.1 | 2.3 | 5.7 | 19.0 |
| Russian LibriSpeech | 4.7 | **4.4** | 6.4 | 6.4 | 5.2 | 6.2 | 9.4 |
| Common Voice 19 | 1.3 | **0.9** | 3.2 | 3.0 | 0.9 | 5.2 | 5.5 |
| Natural Speech | 7.8 | **6.9** | 9.6 | 8.5 | 10.3 | 14.5 | 13.4 |
| Disordered Speech | 20.6 | **19.2** | 22.8 | 23.1 | 27.5 | 51.0 | 58.6 |
| Callcenter | 10.3 | **9.5** | 13.3 | 12.6 | 12.9 | 13.5 | 23.1 |
| OpenSTT Phone Calls | 18.6 | **17.4** | 20.0 | 19.1 | 19.8 | 19.8 | 27.4 |
| **OpenSTT Youtube** | 11.6 | **10.6** | 12.7 | 11.8 | 13.0 | 21.9 | 17.8 |
| OpenSTT Audiobooks | 8.7 | **8.2** | 10.3 | 9.3 | 10.3 | 13.4 | 14.3 |
| **Average** | 9.1 | **8.3** | 12.0 | 11.2 | 10.6 | 16.3 | 21.0 |

**OpenSTT Youtube is your closest analogue** (spontaneous, mixed audio quality, non-studio). There: v3_rnnt 10.6 vs e2e_rnnt 11.8.

**The e2e penalty is real but domain-dependent.** Average gap is 2.9 points, but that is inflated by Golos Crowd (2.4 → 9.1). Golos Crowd is short read utterances; the e2e model does full inverse text normalization, and I suspect much of that 6.7-point gap is normalization mismatch against the reference rather than genuine recognition error **[HYPOTHESIS — the repo does not break this down]**. On spontaneous sets the honest penalty is **~1.2–3.1 points** (Youtube +1.2, Callcenter +3.1, Natural Speech +1.6). Still worth reclaiming.

What you give up by dropping e2e: native punctuation, casing, and number normalization. The repo reports e2e_rnnt punctuation F1 of 84.5 (comma), 86.7 (period), 79.8 (question) — that is genuinely good and you must replace it, not just drop it.

### 1.3 GigaAM Multilingual (June 2026) — not for you

From `evaluation.md`, multilingual section. **Note the eval protocol differs** from the Russian table (utterances >30 s excluded, digit-containing refs excluded, greedy decoding), so cross-table comparison is invalid — use the within-table Whisper baseline as the anchor.

| Language | Dataset | ML 220M | ML 600M | Omnilingual 1B | Seamless M4T v2 | Whisper large-v3 |
|---|---|---:|---:|---:|---:|---:|
| Russian | CV | 7.1 | **5.1** | 13.6 | 9.2 | 9.1 |
| Russian | FLEURS | 4.4 | **3.0** | 6.4 | 4.6 | 3.1 |
| Russian | Internal | 7.6 | **6.0** | 14.6 | 16.1 | 10.1 |
| Kazakh | CV | 17.2 | **13.8** | 23.7 | 23.8 | 57.8 |
| Kyrgyz | CV | 12.5 | **10.2** | 21.6 | 14.3 | 95.2 |
| Uzbek | CV | 11.3 | **9.2** | 32.8 | 25.1 | 109.9 |

Read the Whisper-relative gap: Multilingual 600M beats Whisper by **1.8×** on Russian CV. In the Russian table, v3_rnnt beats Whisper by **6.1×** on CV19. v3 is far more Russian-specialised. The multilingual release is a Central-Asian-languages play, and the paper (arXiv 2607.10371) says so explicitly.

Also disqualifying: **multilingual ships CTC-only** (`multilingual_ctc`, `multilingual_large_ctc`) — no RNNT, no e2e, so no punctuation and a weaker decoder.

### 1.4 Timestamps — what GigaAM actually gives you

I read the source rather than the docs, because this matters for your #1 priority.

- `transcribe(audio, word_timestamps=True)` → word-level. Added 2026/04.
- `transcribe_longform(audio, word_timestamps=True)` → segments with absolute-time words.

**How the timing is computed** (`gigaam/timestamps_utils.py`):
```python
def compute_frame_shift(audio_length_samples, seq_len):
    return audio_length_samples / SAMPLE_RATE / seq_len
```
then word start = `first_frame * frame_shift`, end = `(last_frame + 1) * frame_shift`.

From `ai-sage/GigaAM-v3/config.json`: `hop_length = 160` (10 ms) and `subsampling_factor = 4`.

**→ one encoder frame = 40 ms. That is the hard quantization floor on every GigaAM timestamp.**

Two consequences you should care about:

1. **40 ms quantization** is fine on its own for subtitles.
2. **CTC/RNNT emission peakiness is not fine.** Frame-synchronous decoders emit a token at a spike, not at the acoustic onset of the word — and RNN-T in particular *delays* emission to accumulate right context. So word `start` values are systematically **late**, by an amount that is model- and speaking-rate-dependent. This is exactly the problem the "Less Peaky and More Accurate CTC Forced Alignment by Label Priors" line of work (arXiv 2406.02560) exists to fix. **[HYPOTHESIS: I found no published measurement of GigaAM's specific emission delay in ms. Measure it — see §6.]**

**Where your cue *starts* actually come from.** In `transcribe_longform`, each returned `Segment.start` is `seg_start` from `vad_utils.segment_audio_file` — i.e. a **pyannote/segmentation-3.0 VAD boundary**, not an ASR-derived time. Only the per-word times inside come from the encoder frames. If you build cues from segments, you are consuming VAD accuracy; if from words, you are consuming peaky-decoder accuracy. Different failure modes.

**The longform chunker has a sharp edge.** `segment_audio_file` merges VAD regions into chunks with `max_duration=22.0`, `min_duration=15.0`, `strict_limit_duration=30.0`. Any merged region longer than 30 s is split into **equal-length time slices with no regard for speech content** — it will cut mid-word. With music bleed causing pyannote to over-detect speech, long merged regions are likely on a film track. Worth logging how often this fires.

### 1.5 Licensing

MIT, code and weights, for all GigaAM lines. No attribution burden, no non-commercial clause. This is a genuine advantage over Parakeet/Canary (CC-BY-4.0).

Caveat: `transcribe_longform` pulls `pyannote/segmentation-3.0`, which is gated and requires an `HF_TOKEN` and accepting conditions. Not MIT.

---

## 2. Competing Russian-capable ASR, August 2026

Ranked by fitness for *this* pipeline.

### Tier 1 — actually worth your time

**GigaAM v3_rnnt** — github.com/salute-developers/GigaAM · huggingface.co/ai-sage/GigaAM-v3
- Russian WER 8.3 avg / 10.6 OpenSTT-Youtube. Best available, by a wide margin.
- Word timestamps, 40 ms resolution, peaky.
- **Long-form: structurally cannot hallucinate.** Frame-synchronous CTC/RNNT has no autoregressive text decoder, so Whisper-style repetition loops and invented sentences during music are not a failure mode it has. Worst case on a music-only stretch is a few spurious short words. For a 2.5 h film with music bleed this is the decisive architectural argument.
- MIT. 220–240M params.
- Caveat: 25 s hard limit on `transcribe`; longform requires gated pyannote.

**Qwen3-ASR-1.7B** — github.com/QwenLM/Qwen3-ASR · Apache 2.0
- Russian: FLEURS **5.99** WER (vs Whisper large-v3 9.91), Common Voice **8.28** (vs Whisper 14.07), MLC-SLM 15.17. Released 2026-01-30.
- Genuinely strong, and the best non-Russian-specific option. But it is an **LLM-decoder** model — autoregressive, therefore hallucination-capable. The card claims empty output on no-speech; unverified on music bleed.
- Ships `Qwen3-ForcedAligner-0.6B` alongside (see §3 — this is the valuable part).
- Native MLX port exists (§4).
- **Use it as your A/B second opinion, not your primary.**

### Tier 2 — real, but not better for you

**NVIDIA Parakeet TDT 0.6B v3** — huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- Russian: **5.51** WER FLEURS, 3.00 CoVoST. 25 EU languages incl. Russian/Ukrainian.
- **Word, segment AND char-level timestamps** — good timestamp story.
- Long-form: up to 24 min full attention / 3 h local attention (A100 80 GB figures).
- CC-BY-4.0 (attribution required).
- Frame-synchronous TDT — also hallucination-resistant.
- Excellent `parakeet-mlx` Apple Silicon support, ~3390 RTFx class throughput.
- **Why not primary:** its Russian is a slice of a 25-language model. FLEURS is clean read speech; your audio is nothing like FLEURS. GigaAM v3 is trained on 700k hours of Russian including explicit "speech with background music" and callcenter domains. Different league for your input distribution.

**T-one (T-Bank / voicekit-team)** — github.com/voicekit-team/T-one · huggingface.co/t-tech/T-one
- 71M params, streaming CTC, telephony-specialised. 8.63% WER on their call-center data.
- **It is already in GigaAM's eval table** and loses across the board: avg 16.3 vs v3_rnnt 8.3.
- Not a candidate. Its niche is 300 ms-chunk streaming telephony, which is the opposite of your batch, quality-first, wideband use case.

**Whisper large-v3 / large-v3-turbo** — MIT, 99 languages
- Avg 21.0 on GigaAM's Russian suite. 2.5× worse than v3_rnnt.
- Documented hallucination on silence/music (~1% of transcripts contain fabricated phrases per the "Careless Whisper" work); mitigations are all external (aggressive VAD, temperature 0, post-filtering). `Calm-Whisper` (arXiv 2505.12969) is a fine-tune specifically to reduce non-speech hallucination.
- **This is the worst possible architecture for your input.** Do not go here.

**Vosk (alphacep)** — Apache 2.0, Zipformer2/k2-icefall
- Big Russian model: 6.1 WER on Common Voice ru. Compare v3_rnnt at 0.9 on CV19.
- Excellent for tiny/embedded/streaming. Not competitive on quality.

### Tier 3 — checked, ruled out

- **Mistral Voxtral / Voxtral Transcribe 2 / Voxtral Mini 4B Realtime** (Apache 2.0): 13 languages, ~5.9% avg FLEURS WER. I could not find a published Russian-specific WER. Streaming-oriented. No advantage over GigaAM for Russian.
- **Meta Omnilingual ASR** (Apache 2.0, 1600+ languages): loses badly on Russian in the GigaAM table — 13.6 CV / 14.6 internal, worse than Whisper. Breadth play, not a quality play.
- **Cohere Transcribe 2B, IBM Granite Speech 4.1, ARK-ASR-3B, MOSS-Transcribe, Canary-Qwen-2.5B, Kyutai STT, diffusion-gemma-asr**: the 2026 open-ASR leaderboard race (5.0–5.6% avg WER) is **English-centric**. Cohere covers 14 languages, Granite 6, Canary English-only. None is a Russian contender.
- **Seamless M4T large v2**: 9.2 CV / 16.1 internal on Russian. No.

### API-only — noted, disqualified by your "fully local" constraint

- **ElevenLabs Scribe v2** — best-in-class on AA-WER v2.0 (2.3% headline), 90+ languages. Undisclosed model. **Non-local.**
- **OpenAI GPT-Transcribe** (released 2026-07-28, replaces Whisper as OpenAI's default; cuts whisper-1 Common Voice WER from 40.37 → 19.27 across 22 languages; $0.0045/min) and **gpt-live-transcribe**. **Non-local.**
- Google Chirp 3, Deepgram, Speechmatics Melia, AssemblyAI. **Non-local.**

Flagging these only for completeness — all fail your hard requirement.

---

## 3. Forced alignment as a separate stage — **yes, do this**

This is my strongest recommendation, because it attacks your #1 priority directly and is additive rather than a rewrite.

### The argument

You already have the text. Timestamps from an ASR decoder are a *byproduct* of recognition; timestamps from an aligner are the *objective*. The measured difference is large:

From the Qwen3-ASR technical report (arXiv 2601.21337) and the LLM-ForcedAligner paper (arXiv 2601.18220) — accumulated average shift, lower is better:

| | Russian, raw | Russian, 300 s concat | Avg (10 langs), raw | Avg, 300 s concat |
|---|---:|---:|---:|---:|
| **Qwen3-ForcedAligner-0.6B** | **40.2 ms** | **43.0 ms** | **42.9 ms** | **52.9 ms** |
| NeMo Forced Aligner (NFA) | 200.7 ms | — | 129.8 ms | 246.7 ms |
| WhisperX | — | — | 133.2 ms | — |

Note the **long-form column**. Qwen3 aligner degrades 42.9 → 52.9 ms on 300 s concatenated audio; NFA degrades 129.8 → 246.7 ms. That is drift resistance, and drift over 2.5 h is precisely your stated fear.

### The candidates

**1. `Qwen3-ForcedAligner-0.6B` — my recommendation.**
huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B (also `-hf` variant, and a GGUF community conversion)
- Russian explicitly supported (11 languages: zh, en, yue, fr, de, it, ja, ko, pt, **ru**, es).
- Word- or character-level output. Non-autoregressive → it emits timestamps, it cannot invent text.
- Up to 5 min per call — chunk your film into ~4 min windows on VAD silences.
- Apache 2.0. 0.6B params (~0.9B in some listings).
- **Native MLX implementation exists** (`moona3k/mlx-qwen3-asr`) — enabled by default when timestamps are requested, no PyTorch bridge. This is the deciding practical factor.
- Human-labelled-data accuracy: 32.4 ms avg.

**2. Montreal Forced Aligner 3.x** — montreal-forced-aligner.readthedocs.io
- The 2026 paper (arXiv 2606.18466, Interspeech 2026) reports MFA 3.0 at **mean boundary error below 15 ms** across four benchmarks — the best raw numbers here.
- Russian acoustic model + dictionary available in the pretrained model zoo.
- **Caveats that matter for you:** MFA is phoneme-level and needs a pronunciation dictionary; every OOV proper noun (exactly your film-specific names problem) needs G2P handling. It is Kaldi-based, HMM-GMM, and is built for clean corpus audio with accurate transcripts — your input is separation-artifact-laden voiceover over residual music. The <15 ms figures are on TIMIT/Buckeye-class read speech, not on this. Expect substantial degradation **[HYPOTHESIS]**.
- Practical: heavyweight conda install, Kaldi binaries on Apple Silicon are workable but fiddly.

**3. NeMo Forced Aligner (NFA)** — CTC-based, token/word/segment timestamps, user-defined segment grouping (built explicitly for subtitle generation — Interspeech 2023, Rastorgueva et al.).
- Would let you align against a NeMo CTC Russian model.
- But: 200.7 ms Russian shift in the Qwen benchmark, and 246.7 ms on long concatenated audio. **5× worse than Qwen3 aligner on your language.** Skip.

**4. `ctc-forced-aligner` (MahmoudAshraf)** — github.com/MahmoudAshraf97/ctc-forced-aligner
- Uses `MahmoudAshraf/mms-300m-1130-forced-aligner` (MMS-based, broad language coverage incl. Russian). Simple API, romanization-based so it handles any script.
- Evidence: the underlying label-priors method (arXiv 2406.02560) beats vanilla CTC by 12–40% on boundary error and is "similar to MFA on Buckeye, behind MFA on TIMIT."
- Good, cheap fallback. Much lighter than MFA. Worse than Qwen3 aligner on paper.

**5. WhisperX alignment stage** — 133.2 ms avg. Its wav2vec2 aligner has **no default Russian model** (defaults cover en/fr/de/es/it via torchaudio); you would have to source and validate a Russian phoneme model from HF yourself. Not worth it given the alternatives.

**6. `Multilingual-Word-Aligner` (MWA)** — github.com/MLSpeech/Multilingual-Word-Aligner, arXiv 2606.10675, Interspeech 2026. MMS + UnSupSeg fusion with learned dynamic programming; beats MFA on TIMIT and Buckeye and generalises to unseen languages. Trained only on TIMIT/Buckeye (English). Russian is "unseen-language" territory — plausible but unproven for you. **Interesting, not yet a production pick [HYPOTHESIS].**

**7. LLM-ForcedAligner (arXiv 2601.18220)** — this appears to be the paper *behind* Qwen3-ForcedAligner (same architecture: AuT/audio-transformer encoder + Qwen3-0.6B + linear timestamp head; same 42.9 ms average). The paper says "checkpoint and inference code will be released later" — the Qwen release is that. Treat them as one thing.

### Recommended alignment architecture

```
dub track (2.5 h)
  → Silero VAD v6 (fine-grained, no merging) → speech regions
  → GigaAM v3_rnnt on VAD-merged 15–22 s chunks → text only (discard its timestamps)
  → punctuation/casing restoration pass
  → Qwen3-ForcedAligner-0.6B, ~4 min windows cut on silences, text + audio → word timestamps
  → cue assembly: group words into cues on punctuation + max chars + max duration + VAD gaps
```

Key point: **decouple recognition from timing.** Let each stage do the thing it is good at.

---

## 4. Apple Silicon runnability

| Component | Path on M-series | Confidence |
|---|---|---|
| **GigaAM v3** | PyTorch. `forward()` does `torch.autocast(device_type=self._device.type, dtype=torch.float16)` for any non-CPU device, so `.to("mps")` should engage the MPS autocast path; CPU takes a no-autocast branch. **Authors document only CUDA and CPU.** | **[HYPOTHESIS]** — MPS is not tested upstream. Expect possible op gaps needing `PYTORCH_ENABLE_MPS_FALLBACK=1`. Verify before committing. |
| **GigaAM via ONNX** | `model.to_onnx(dir_path, dtype=torch.float32)` is supported and documented (CTC exports whole; RNNT exports encoder/decoder/joint separately). Then ONNX Runtime with the CoreML execution provider. | Good fallback. Export is first-class; CoreML EP coverage for Conformer ops unverified **[HYPOTHESIS]**. |
| **GigaAM on CPU** | Always works. 220M-param Conformer on M-series CPU. | Certain. Slow but you have hours per film. |
| **GigaAM MLX / CoreML port** | **None found.** I searched; no community MLX or CoreML conversion of GigaAM exists as of 2026-08. | Verified absent. |
| **Qwen3-ASR + Qwen3-ForcedAligner** | `mlx-qwen3-asr` (moona3k) — native MLX, no PyTorch bridge. `pip install mlx-qwen3-asr`. Aligner enabled by default when timestamps requested. **RTF 0.08× fp16 on M4 Pro** for the 0.6B; 4-bit is 4.68× faster again. Memory ~1.2 GB (0.6B) / ~3.4 GB (1.7B). Up to 20 min per chunk with energy-based chunking. | Strong. This is the best-supported piece of the proposed stack. |
| **Parakeet TDT** | `senstella/parakeet-mlx` (MLX) and FluidAudio (CoreML). Benchmarked large-model transcription: FluidAudio CoreML 0.194 s, parakeet-mlx 0.500 s, mlx-whisper 1.023 s. | Excellent, if you wanted Parakeet. |
| **Whisper** | `mlx-whisper`, `whisper.cpp`. large-v3 ≈ 2–3× realtime on Metal; Whisper large-v3-turbo reported at 108× RTF on M5 Max. | Excellent — but you should not use Whisper here. |
| **Silero VAD v6** | v6.2.1 has **CoreML and MLX backends**, ~309K params, 1.2 MB, 32 ms chunks, ~23× realtime with a Swift API. | Excellent. |
| **pyannote segmentation-3.0** | PyTorch; runs on MPS or CPU. Gated on HF, needs token. | Works, with friction. |

**Practical read:** the ASR stage (GigaAM) is your only MPS-uncertain component, and it has a documented ONNX escape hatch plus a guaranteed CPU path. Everything else in the proposed pipeline has native Apple Silicon support. Given "hours per film acceptable," even full CPU GigaAM is viable.

---

## 5. Long-form pipeline hygiene for 2.5 h

**VAD.** Two reasonable choices, and the tradeoff is documented:
- **pyannote/segmentation-3.0** — offline batch, accuracy-first. What GigaAM uses today. Gated.
- **Silero VAD v6.2.1** — streaming, 32 ms chunks, CoreML/MLX, MIT-class permissive, 1.2 MB. Community guidance for 2026 is: Silero for streaming/realtime, pyannote for offline accuracy.

For your case there is a specific reason to prefer **Silero for cue boundaries and pyannote for chunking**: Silero's acoustic boundaries are tighter. The frequently-cited framing is that Whisper cuts where *meaning* stops while Silero cuts where *the mouth* stops — and for cue timing you want the mouth. A 2026 phone-call diarization comparison found Silero+WeSpeaker+spectral clustering hit 76.1% agreement with pyannote at 2.4× the speed.

**Chunking.** GigaAM's built-in chunker merges to 15–22 s and hard-splits >30 s regions into equal slices with no content awareness — that cuts mid-word. Recommendations:
- Reduce `max_duration` / `strict_limit_duration` so the blind-split branch effectively never fires.
- Better: do your own chunking, cutting only at VAD silences, with **1–2 s overlap** between chunks and a longest-common-subsequence stitch on the overlap to drop duplicated words. GigaAM's chunker has zero overlap, so a word straddling a boundary is simply lost.
- With music bleed, expect pyannote to over-detect speech and produce long merged regions → the blind-split branch fires more than you'd think. **Log how often.**

**Hallucination during music.** Your architecture already largely solves this: CTC and RNN-T are frame-synchronous and have no free-running text decoder, so they cannot enter a repetition loop or invent a sentence. This is the single strongest reason to stay on GigaAM rather than move to any Whisper-family or LLM-decoder model. Keep VAD gating anyway as belt-and-braces.

**Diarization for the two narrators.** Worth trying, with tempered expectations. pyannote 3.1 is what WhisperX bundles; the claimed "pyannote 4.x" I could not confirm as released **[HYPOTHESIS — I found references but no primary release page]**. The realistic gain: splitting overlapping narrator turns into separate cues. The realistic risk: on source-separated audio with separation artifacts, speaker embeddings degrade badly, and two male narrators reading flatly are a hard case. **Test it, do not assume it.** If it works, it also gives you a cheap heuristic for overlap regions, which are exactly where your WER is worst.

---

## 6. A/B test protocol on one film

You have no ground truth. That is fine — you can still get decisive answers. Do these three things.

### 6.1 Build a small gold set (do this once, reuse forever)

The only real ground truth is you. Budget ~60–90 min of one-time work:

1. Pick **80 random cues** from the current output, stratified: 40 from dialogue-dense stretches, 25 from music/effects-heavy stretches, 15 from the first and last 10 minutes (drift probes).
2. For each, in Audacity or similar, transcribe the audio verbatim **and mark the true onset of the first word** to ~10 ms.
3. Save as `gold.jsonl`: `{cue_id, t_true_start, t_true_end, text_true}`.

80 cues ≈ 8–10 min of audio. This gives WER with a ±~2% confidence band and, more importantly, a **direct timing reference**.

### 6.2 Measuring text quality

**Primary metric — WER against the gold set.** Normalize both sides identically before scoring (lowercase, strip punctuation, numerals→words) — this is exactly what GigaAM's own eval does, and skipping it will make the e2e model look artificially terrible.

Report separately:
- Overall WER.
- **Proper-noun recall.** Extract the film's character/place names from any available source; measure how many are recognized correctly. This is your #2 priority and aggregate WER hides it completely — 15 name errors in a 15,000-word transcript is 0.1% WER and a ruined subtitle experience.

**Secondary metric — cross-model disagreement (no gold needed, covers 100% of the film).**
1. Transcribe the full film with candidate A (GigaAM v3_rnnt) and candidate B (Qwen3-ASR-1.7B).
2. Align the two transcripts and compute pairwise WER. This is *disagreement*, not error — do not report it as WER.
3. Take the 100 highest-disagreement regions and adjudicate ~25 by ear. The split of "A right / B right / both wrong" tells you which model to trust, and roughly how much of the disagreement mass is genuine error.
4. Regions where A and B agree are very likely correct; regions where they disagree concentrate nearly all your real errors. This is a cheap error-localizer for the whole film.

### 6.3 Measuring timing objectively — the important one

**Metric: signed start offset.** For each cue, `Δ = t_predicted_start − t_true_start`. Report **median Δ** (systematic bias) and **IQR / p90 |Δ|** (jitter). Median and spread must be reported separately — a constant +180 ms lag is trivially fixable with a global shift; 180 ms of *jitter* is not.

Three sources of `t_true_start`, in increasing order of cost:

**(a) Energy-onset reference — free, full coverage, use this first.**
Run Silero VAD v6 at fine granularity (32 ms) on the dub track. For each cue, find the nearest preceding speech onset within a ±1.5 s window. Compute Δ against it. This is not perfect ground truth, but it is *unbiased with respect to which ASR produced the cue*, which is all you need for an A/B. Runs over all ~1300 cues.

**(b) Gold set — 80 cues, hand-marked. Ground truth.** Use to calibrate whether (a) is trustworthy: if the median Δ from method (a) matches the median from the gold set within ~20 ms, method (a) is validated and you can trust it across the whole film.

**(c) Aligner cross-check — full coverage.** Run Qwen3-ForcedAligner on the *same* text and compare word starts. Where the aligner and the ASR disagree by >200 ms, listen to a sample. This directly measures the thing you want to know: does alignment buy you anything.

**The specific comparison to run:**

| Arm | Text from | Timing from |
|---|---|---|
| **A — baseline** | `v3_e2e_rnnt` | its own word/segment timestamps (current pipeline) |
| **B — decoupled** | `v3_rnnt` + punctuation pass | its own word timestamps |
| **C — aligned** | `v3_rnnt` + punctuation pass | **Qwen3-ForcedAligner** |
| **D — control** | `v3_e2e_rnnt` | **Qwen3-ForcedAligner** |

A vs B isolates the e2e WER penalty on *your* audio. B vs C isolates the alignment gain. A vs D tells you whether you can get most of the timing win with a one-line addition and no other changes — **run D first, it is the cheapest possible win.**

**Drift test.** Bucket all cues into 15-minute bins and plot median Δ per bin. A rising line is drift. GigaAM's per-segment VAD-anchored design should be drift-free by construction (each chunk gets absolute boundaries from VAD) — this test confirms that and would catch a chunk-accounting bug. Do it once; it is nearly free.

**Duration sanity.** Flag cues where `chars / duration` implies >21 chars/sec (unreadable) or <5 (cue hangs). Not accuracy, but it catches boundary bugs that WER and Δ both miss.

### 6.4 Decision rule

- If C beats A on median |Δ| by **>60 ms** → adopt alignment. (60 ms ≈ 1.5 GigaAM frames; below that you are inside quantization noise.)
- If B beats A on WER by **>0.8 points** on your gold set → drop e2e, adopt separate punctuation.
- If Qwen3-ASR-1.7B beats GigaAM v3_rnnt on your gold set at all → surprising; re-examine, because it contradicts every published Russian benchmark. Most likely explanation would be that your separation artifacts hurt GigaAM's training distribution more than Qwen's.

---

## 7. Direct answers

**Keep GigaAM v3 or switch?**
**Keep it — it is not close.** GigaAM v3 is the only model in this survey trained on 700k hours of Russian *including* explicit background-music and callcenter domains, and its frame-synchronous decoder is structurally immune to the hallucination failure mode that would wreck a 2.5 h film track. Every alternative is either much worse on Russian (Whisper 2.5×, T-one 2×, Vosk, Omnilingual, Seamless), English-centric (the entire 2026 leaderboard race), non-local (Scribe v2, GPT-Transcribe), or a breadth play that trades away Russian specialisation (Parakeet v3, GigaAM Multilingual).

**But make two changes within the GigaAM line:**
1. Move `v3_e2e_rnnt` → `v3_rnnt` + a separate punctuation/casing/ITN pass. Reclaims ~1.2–3.1 WER points in your domain. Verify on your gold set before committing, since part of the published gap is likely normalization-mismatch artifact.
2. Do **not** move to GigaAM Multilingual. It is CTC-only, unpunctuated, and built for Central Asian languages.

**Should we add a forced-alignment pass?**
**Yes. This is the highest-value change available to you, and it is additive rather than a rewrite.** Your #1 priority is timestamp accuracy, and GigaAM's timestamps are a byproduct of recognition: quantized to 40 ms and systematically late from CTC/RNNT emission peakiness, with cue starts actually inherited from pyannote VAD boundaries rather than from the audio. `Qwen3-ForcedAligner-0.6B` is purpose-built for exactly this, reports 40.2 ms on Russian against NFA's 200.7 ms, holds 43.0 ms on 300 s concatenated audio (drift resistance), is Apache 2.0, and runs natively in MLX on Apple Silicon at RTF 0.08× on an M4 Pro. Run arm **D** first — same pipeline, aligner bolted on — and you should see most of the gain for almost no work.

---

## Sources

Read directly:

- https://github.com/salute-developers/GigaAM
- https://raw.githubusercontent.com/salute-developers/GigaAM/main/README.md
- https://raw.githubusercontent.com/salute-developers/GigaAM/main/README_ru.md
- https://raw.githubusercontent.com/salute-developers/GigaAM/main/evaluation.md — the Russian and multilingual WER tables
- https://raw.githubusercontent.com/salute-developers/GigaAM/main/gigaam/model.py
- https://raw.githubusercontent.com/salute-developers/GigaAM/main/gigaam/timestamps_utils.py
- https://raw.githubusercontent.com/salute-developers/GigaAM/main/gigaam/vad_utils.py
- https://raw.githubusercontent.com/salute-developers/GigaAM/main/gigaam/preprocess.py
- https://raw.githubusercontent.com/salute-developers/GigaAM/main/gigaam/encoder.py
- https://huggingface.co/ai-sage/GigaAM-v3
- https://huggingface.co/ai-sage/GigaAM-v3/raw/main/config.json — hop_length 160, subsampling_factor 4
- https://huggingface.co/ai-sage/GigaAM-Multilingual
- https://arxiv.org/abs/2607.10371 / https://arxiv.org/html/2607.10371 — GigaAM Multilingual
- https://arxiv.org/abs/2506.01192 — GigaAM, Interspeech 2025
- https://deepwiki.com/salute-developers/GigaAM/1.3-model-performance-and-evaluation
- https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B
- https://github.com/QwenLM/Qwen3-ASR
- https://arxiv.org/html/2601.21337v1 — Qwen3-ASR technical report
- https://arxiv.org/html/2601.18220v1 — LLM-ForcedAligner
- https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- https://github.com/voicekit-team/T-one
- https://arxiv.org/abs/2606.18466 — MFA 3.0, Interspeech 2026
- https://arxiv.org/abs/2406.02560 — CTC forced alignment with label priors
- https://arxiv.org/abs/2606.10675 — Multilingual Word Aligner, Interspeech 2026
- https://github.com/MahmoudAshraf97/ctc-forced-aligner
- https://github.com/moona3k/mlx-qwen3-asr
- https://github.com/senstella/parakeet-mlx
- https://soniqo.audio/guides/vad — Silero VAD v6.2.1 CoreML/MLX
- https://arxiv.org/html/2510.06961v4 — ASR Leaderboard methodology
- https://arxiv.org/pdf/2512.19161 — ASR for TV subtitling evaluation
- https://www.marktechpost.com/2026/07/23/best-open-speech-recognition-asr-models-in-2026-wer-languages-latency-and-license-compared/
- https://arxiv.org/html/2505.12969v1 — Calm-Whisper
- https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/tools/nemo_forced_aligner.html
- https://www.isca-archive.org/interspeech_2023/rastorgueva23_interspeech.html — NFA for subtitles
- https://github.com/m-bain/whisperX
- https://alphacephei.com/vosk/models
- https://spokenly.app/blog/gpt-transcribe — GPT-Transcribe, 2026-07-28
- https://elevenlabs.io/blog/introducing-scribe-v2
- https://www.x2q.net/post/diarization-five-alternatives/
- https://hf.co/spaces/hf-audio/open_asr_leaderboard
