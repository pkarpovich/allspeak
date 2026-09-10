# Speech restoration stage — SOTA review (2026-08-02)

Scope: the **restoration/enhancement** stage that runs on a source-separated Russian-voiceover vocals stem from a cinema CAM/TS capture. Fully local, Apple Silicon, quality >> speed, and hard constraints: no invented words, no voice-identity swap, no dropped quiet dialogue.

---

## 0. Bottom line up front

1. **Sidon is current.** No newer Sidon checkpoint exists (`sidon-v0.1`, last touched 2025-12-15). The paper is now at **v3**, and `DialogueSidon` code + weights *have* shipped (2026-04 / 2026-07) — but DialogueSidon is a two-speaker *separator*, not a single-speaker restorer.

2. **The decisive finding is not about Sidon specifically — it is about its whole model class.** Miipher/Sidon-style "SSL-feature-predictor + vocoder" restorers are *resynthesis* models: they discard the waveform and regenerate speech from a semantic bottleneck. Independent, blind, third-party evaluation (URGENT 2025) shows this class tops every perceptual metric and simultaneously **bottoms out on every content-fidelity metric**, with organizers explicitly documenting invented spoken content and wrong-language output under low SNR. See §3 — this is the single most important section in this document.

3. **Sidon's own paper never shows it improving content accuracy.** In every table, WER/CER after Sidon is *equal to or worse than* the noisy input (EN 0.040→0.045, EN-other 0.079→0.095, RU 0.042→0.043, 100-lang avg 0.084→0.090). Sidon is a **cosmetic** restorer built for TTS-dataset cleansing, not an intelligibility restorer. That is a real mismatch with "make it intelligible in one earbud".

4. **Keep the stage; change what runs in it — and start with the cheap safe option, not the fanciest one.** In rank order:
   - **First, because it costs an afternoon**: `MossFormer2_SE_48K` via the MLX port. Natively 48 kHz, Apache-2.0, 25–30× realtime on your Mac, and **structurally incapable of inventing a word** (it is a multiplicative mask — verified in the source, not inferred). Independently measured at CAcc 90.60 → 89.90, i.e. content untouched. Optionally chain `MossFormer2_SR_48K` for bandwidth, which splices only the synthetic high band and leaves your original speech band bit-untouched.
   - **Then the contenders**: **GAP-URGENet** (hybrid predictive+generative, 1st in ICASSP 2026 URGENT objective phase, MIT) and its generative core **UniPASE** (IEEE TASLP, Apache-2.0) — the only research line that treats hallucination as the headline metric and publishes dWER against strong baselines.
   - **Keep Sidon as a measured arm.** Its Russian numbers are genuinely good and it is the only restorer with any published Russian result at all.
   - **RE-USE has the best faithfulness numbers of anything here** (the only model that *raises* content accuracy) but is noncommercial-licensed with no Russian in training.

5. **The strongest single piece of evidence for your specific pipeline**: the CCF AATC 2025 Speech Restoration Challenge ran a track on speech that had already passed through a separator (Demucs/TF-GridNet/SGMSE+) — your exact input distribution — and **discriminative models took ranks 1, 3, 4, 5 and 6**. On that same material **DNSMOS correlated ρ = −0.8 with human judgment**, i.e. inverted. See §7.

6. **Measure before you switch.** Every number in this document comes from benchmarks whose degradations (noise, reverb, clipping, codec, packet loss, band limitation) **do not include source-separation artifacts**. Your input is out-of-domain for all of these models, and no published number transfers directly. §8 gives a runnable protocol, and §8 also warns that a naive reading of it will mislead you.

---

## 1. Sidon status

| Item | Finding |
|---|---|
| Paper | arXiv **2509.17052v3** (v1 Sept 2025; now v3). Authors Nakata, Saito, Ueda, Saruwatari (U. Tokyo / AIST) |
| Repo | `github.com/sarulab-speech/Sidon` — MIT, 172 stars, last push **2026-04-24** |
| Weights | `sarulab-speech/sidon-v0.1` (MIT, lastModified **2025-12-15**) and `sarulab-speech/sidon_raw_weight` (2025-12-13). **No newer Sidon checkpoint.** |
| Files | `feature_extractor_{cpu,cuda}.pt`, `decoder_{cpu,cuda}.pt` — TorchScript only. **No MPS variant.** |
| Successor | **DialogueSidon** — arXiv 2604.09344, SIGDIAL 2026. Code merged into the same repo (2026-04-24); weights at `sarulab-speech/DialogueSidon`, **CC-BY-NC-4.0** (note: more restrictive than Sidon's MIT), 24 kHz DAC-VAE decoder. |

**Architecture** (2,219 h across **104 languages incl. Russian**, ~9,000 paired degraded hours): w2v-BERT 2.0 600M finetuned with LoRA, layer 8 features (198M) → HiFi-GAN-with-snake vocoder (52.4M). 250M total. Output 48 kHz.

**Training degradations**: reverberation, additive noise at **SNR ~ U(−5, 20) dB**, band limitation ({8,16,22.05,24,44.1,48} kHz), clipping, MP3 65–245 kbps, 9% packet loss. **No source-separation artifacts.**

### Sidon's own published numbers

LibriTTS **test-clean** / **test-other** (ASR = `mms-1B-all`):

| | WER↓ | SpkSim↑ | NISQA↑ | DNSMOS↑ |
|---|---|---|---|---|
| Noisy (clean set) | **0.040** | – | 4.093 | 3.179 |
| Miipher | 0.047 | 0.942 | 4.688 | 3.134 |
| Sidon | 0.045 | **0.971** | **4.790** | **3.303** |
| Noisy (other set) | **0.079** | – | 3.623 | 2.949 |
| Miipher | **0.090** | 0.930 | 4.597 | 3.040 |
| Sidon | 0.095 | **0.961** | **4.698** | **3.219** |

FLEURS multilingual (CER, 100 languages):

| Lang | CER noisy | CER Miipher-2 | CER Sidon | DNSMOS noisy→Sidon | SpkSim Sidon |
|---|---|---|---|---|---|
| **ru** | **0.042** | 0.046 | 0.043 | 3.005 → **3.364** | **0.986** |
| en | 0.051 | 0.061 | 0.061 | 2.925 → 3.466 | 0.976 |
| cmn | 0.266 | 0.287 | 0.280 | 3.112 → 3.374 | 0.984 |
| ja | 0.212 | 0.225 | 0.213 | 2.673 → 3.453 | 0.958 |
| **Average (100)** | **0.084** | 0.094 | 0.090 | 2.910 → 3.393 | 0.979 |

**Read this carefully.** Sidon *never* improves CER/WER over the noisy input in its own paper. It improves DNSMOS by ~0.45 and NISQA by ~1.2, and preserves speaker identity very well (RU SpkSim 0.986). The content-accuracy cost on Russian is small (+0.001 CER) — genuinely reassuring **on FLEURS-grade material**, which is clean read speech with *simulated* degradations, evaluated in short clips.

### Known Sidon defects (from its own issue tracker)

- **#1 "The tail of some audios will be cut off"** — author confirms: *"Yes you do need to add paddings to prevent that from happening. Not sure what the cause and potential fix is."* Unresolved root cause; workaround is zero-padding. Directly relevant to "must not drop dialogue".
- **#5 "Models have hardcoded `cuda:0`"** — the published TorchScript is device-baked; `CUDA_VISIBLE_DEVICES` does not work around it. This is why separate `_cpu.pt` / `_cuda.pt` files exist and why there is no MPS path.
- **#10 (open)** — no official `.ckpt` → TorchScript export script, so retraining/fine-tuning cannot be round-tripped into the inference path without guesswork.

### Your current pipeline vs. the reference implementation

`/Users/pavel.karpovich/Projects/allspeak/scripts/sidon_infer.py` runs `device = "cpu"` with the `_cpu.pt` TorchScript. Two observations:

- Your chunking is **better than the official demo**. The HF Space (`sarulab-speech/sidon_demo_beta`) splits at 96 s with a **single** carried feature frame (`feature_cache = feature[:,-1:]`). Yours uses 30 s chunks with 25 frames (500 ms) of carried context and re-decodes the held-back tail with proper right context. That is a sound overlap scheme; keep it.
- **Sidon internally resamples your input to 16 kHz** (`resample(wav, sample_rate, 16000)` before the feature extractor). Everything above 8 kHz in the output is *generated*, not restored. The "48 kHz output" is bandwidth extension, not fidelity. For one-earbud intelligibility this is acceptable — speech intelligibility lives below 8 kHz — but it means chasing 48 kHz elsewhere in the pipeline buys you nothing at this stage.
- `waveform = 0.9 * (waveform / waveform.abs().max())` is the peak-normalisation you observed (≈ −0.9 dBFS).

---

## 2. Miipher / Miipher-2 (Google)

| | Miipher | Miipher-2 |
|---|---|---|
| Paper | Koizumi et al. | arXiv **2505.04457** (May 2025) |
| Open weights | **No** | **No** — Google-internal |
| Conditioning | Text-conditioned (needs transcript) | Conditioning-free |
| SSL backbone | w2v-BERT | **USM** (300+ languages), frozen + parallel adapters |
| Vocoder | WaveFit | WaveFit, **24 kHz** |
| RTF | – | 0.0078 (~128× realtime) on consumer accelerators |

**Neither is obtainable.** The only reproductions:

- `github.com/yukara-ikemiya/Open-Miipher-2` — MIT, faithful training code, **no pretrained weights**, and it substitutes a 0.6B USM stand-in (`Atotti/Google-USM`) for Google's 2B. Training from scratch is out of scope for a hobby pipeline.
- `Atotti/miipher-2-HuBERT-HiFi-GAN-v0.1` — a small third-party checkpoint; 9 downloads, effectively unvalidated. **Not recommended.**
- `lab260/ru-Miipher` — a **Russian** Miipher+HiFiGAN baseline built for the ReVoice-2025 hackathon. Interesting as the only Russian-specific artifact found, but it is hackathon baseline code with no published metrics, no stated license, and no WER evidence. **Hypothesis-grade only.**

**Sidon vs Miipher-2**, per Sidon's paper: Sidon wins CER (0.090 vs 0.094) and DNSMOS (3.393 vs 3.352), loses NISQA (4.420 vs 4.475), ties SpkSim (0.979). Sidon is a legitimate open replacement for Miipher-2 — but it inherits the class-level fidelity problem below.

---

## 3. The decisive evidence: what blind third-party evaluation says about this model class

This is the section that should drive the decision.

### 3.1 URGENT 2025 (Interspeech), arXiv 2505.23212

22 submissions, blind test, 14 metrics, 5 training languages (en/de/fr/es/zh) + **Japanese as an unseen language**. System **T13** was the only *purely generative* entry, described as "latent diffusion and vocoding" — the same architectural family as Miipher/Sidon.

| System | Type | DNSMOS | NISQA | UTMOS | PESQ | ESTOI | SDR | SpkSim | CAcc% | MOS |
|---|---|---|---|---|---|---|---|---|---|---|
| T1 (winner) | Discriminative | 2.88 (8) | 3.22 (6) | 2.09 (5) | **2.64 (1)** | **0.82 (1)** | **12.66 (1)** | **0.76 (1)** | **79.80 (1)** | 3.24 |
| **T13** | **Generative** | **3.10 (1)** | **3.74 (1)** | **2.53 (1)** | 1.34 (21) | 0.54 (22) | **−12.28 (22)** | **0.47 (22)** | **67.87 (21)** | **3.69 (1)** |
| T22 (noisy input) | – | 1.90 | 1.58 | 1.55 | 1.31 | 0.58 | 3.24 | 0.55 | **73.41** | 2.13 |

**T13 ranked 1st on every perceptual metric including subjective MOS, and 21st–22nd on every fidelity metric. Its character accuracy (67.87%) is worse than doing nothing at all (73.41%). Its speaker similarity, 0.47, is the worst in the field — below the raw noisy input.**

Per-language CAcc (Table 3):

| System | de | en | fr | es | **zh** | **ja (unseen)** |
|---|---|---|---|---|---|---|
| T1 (discriminative) | 82.0 | 79.2 | 75.8 | 86.4 | 75.3 | 75.1 |
| T10 (discriminative baseline) | 79.0 | 73.8 | 70.2 | 82.3 | 70.7 | 73.0 |
| **T13 (generative)** | 74.0 | 68.0 | 68.6 | 80.9 | **20.1** | **36.8** |
| T22 (noisy) | 76.8 | 70.3 | 67.3 | 80.8 | 69.3 | 74.5 |

**Chinese character accuracy collapses from 69.3% (untouched) to 20.1%. Japanese from 74.5% to 36.8%.** The discriminative systems are flat across languages; the generative one is not.

The organizers investigated and wrote (quoting the paper):

> "We found that the model occasionally hallucinated spoken content, particularly under low-SNR conditions… Notably, for Japanese inputs — which were unseen during training — the output under low-SNR conditions sometimes resembled English or other European languages that dominated the training data."

And, critically for how you would evaluate this yourself:

> "DNSMOS yields high scores even when hallucinations occur."

> "…it may be difficult to penalize the correctness of the spoken content and speaker consistency as long as the speech sounds natural."

Their conclusion: *"generative approaches appeared to be more language-dependent than discriminative ones"* and *"generative models tended to be preferred to discriminative ones in the subjective evaluation."* **Listeners preferred the hallucinating model.** Your ears in a cinema will not catch this; only ASR will.

### 3.2 Is T13 Sidon?

UniPASE's Table VIII names this team **`wataru9871`** (rank 13, purely generative) — **Wataru Nakata is Sidon's first author**, and the metric fingerprint matches (PESQ 1.34/1.36, ESTOI 0.54/0.56, SpkSim 0.47/0.51, rank 13, type G; the two papers report the blind and non-blind splits respectively).

**Mark as strong hypothesis, not verified fact:** the submission is by Sidon's author and is in Sidon's architectural family, but the URGENT 2025 submission predates the Sidon paper and the challenge paper calls it "latent diffusion" (Sidon's released model is deterministic feature-prediction; the diffusion latent predictor appears in *DialogueSidon*). I could not confirm the submitted system is the released `sidon-v0.1` checkpoint. **The class-level conclusion holds regardless of the identification** — and Sidon's own paper independently shows the same directional signature (WER always ≥ noisy).

### 3.3 Independent ASR-after-enhancement numbers for the older toolchain (RE-USE paper, Table 2)

The RE-USE paper (arXiv 2603.02641, CC BY 4.0) benchmarks the popular open tools on the **URGENT 2025 non-blind test set** with `CAcc` = character accuracy after enhancement. This is the only third-party faithfulness measurement that exists for ClearerVoice and Resemble Enhance:

**48 kHz subset**

| Model | DNSMOS | NISQA | UTMOS | PESQ | ESTOI | SDR | SpkSim | **CAcc↑** |
|---|---|---|---|---|---|---|---|---|
| Noisy (input) | 2.04 | 1.83 | 1.99 | 1.28 | 0.56 | 2.29 | 0.69 | **90.60** |
| ClearerVoice (MossFormer2) | 2.97 | 3.38 | 3.02 | 2.09 | 0.72 | 11.55 | 0.63 | **89.90** |
| RE-USE | 3.31 | 4.41 | 3.55 | 2.65 | 0.77 | 12.79 | **0.87** | **92.50** |

**44.1 kHz subset**

| Model | DNSMOS | NISQA | UTMOS | PESQ | ESTOI | SDR | SpkSim | **CAcc↑** |
|---|---|---|---|---|---|---|---|---|
| Noisy (input) | 1.91 | 1.79 | 1.52 | 1.33 | 0.64 | 3.34 | 0.71 | **83.60** |
| **Resemble Enhance** | 3.13 | 3.68 | 2.11 | 1.33 | 0.45 | **−15.01** | 0.61 | **47.20** |
| RE-USE | 3.32 | 4.15 | 2.68 | 2.28 | 0.78 | 7.18 | **0.88** | **92.20** |

Three conclusions, and they reinforce §3.1 exactly:

1. **Resemble Enhance loses roughly half the characters (83.60 → 47.20) while its DNSMOS nearly doubles (1.91 → 3.13).** SDR of **−15.01 dB** means the output is anti-correlated with the reference. The paper states it plainly: *"substantially improves non-intrusive quality metrics but yields low intrusive scores and CAcc, suggesting a tendency to hallucinate content, which is consistent with prior findings on purely generative models."* **Disqualifying.**
2. **ClearerVoice is safe but does not buy intelligibility**: CAcc 90.60 → 89.90 (marginally worse), SpkSim 0.69 → 0.63. What it does buy is real: PESQ +0.81, SDR +9.3 dB.
3. **RE-USE is the only model in this entire document that *improves* content accuracy** (90.60 → 92.50, 83.60 → 92.20) while also topping SpkSim at 0.87/0.88. Which makes its noncommercial licence genuinely annoying rather than academic.

Once again: **every model improves DNSMOS/UTMOS, including the one that destroys half the content.** Those metrics cannot arbitrate this decision.

### 3.4 Why this matters more for you than for a dataset-cleansing user

Sidon is designed for TTS corpus cleansing, where a hallucinated utterance is one bad row among millions and gets averaged out. In your pipeline the output **is the product**, consumed once, live, un-checkable. Your material also stacks all three of T13's failure triggers:

- **low SNR** — residual music/effects bleed after separation;
- **out-of-domain degradation** — separation artifacts (musical noise, smearing) were in nobody's training set;
- **a language that is not the training-set plurality** — Russian is ~1/104 of Sidon's mix; the corpus list (LibriTTS-R, VCTK, EARS, EXPRESSO, JSUT, JVS, HiFi-CAPTAIN, Bible-TTS, FLEURS-R) is heavily English/Japanese.

---

## 4. Ranked shortlist

### #1 — GAP-URGENet (hybrid predictive + generative) — RECOMMENDED PRIMARY

- Repo: `github.com/Xiaobin-Rong/gap-urgenet` — **MIT**, pushed 2026-07-21
- Weights: `huggingface.co/Xiaobin-Rong/gap-urgenet` — **MIT**, 2026-07-21 (`DeWavLM-Omni.pt`, `Adapter.pt`, `Vocoder.pt`, `Predictor.pt`, `PostNet.pt`)
- Paper: arXiv **2604.01832**

**What it is**: UniPASE's generative branch (DeWavLM-Omni + Adapter + Vocoder) **fused with a predictive TF-GridNet branch** by a PostNet that also does bandwidth extension to 48 kHz.

**Quality evidence**: **1st place in the ICASSP 2026 URGENT Challenge objective evaluation** (team WR). This is stated in the paper itself ("Results on the blind-test set further confirm the superiority of GAP-URGENet, achieving 1st place in the objective evaluation") and in the repo README, but it is an **author claim** — the challenge results page has been reorganised and I could not independently re-verify the ranking table (**flagged**). Note the URGENT 2026 objective score *does* aggregate character accuracy, so winning it is indirect content-fidelity evidence.

**Faithfulness evidence — important caveat**: the GAP-URGENet paper publishes **no CER/WER number of its own**. Its validation-set ablation reports only perceptual + speaker metrics:

| Configuration | DNSMOS | UTMOS | PESQ | NISQA | ESTOI | SpkSim |
|---|---|---|---|---|---|---|
| Predictive branch alone | 3.20 | 3.13 | – | – | – | 0.70 |
| Generative branch alone | 3.23 | 3.01 | – | – | – | 0.76 |
| **Fused (GAP-URGENet)** | **3.31** | **3.22** | 2.89 | 3.96 | 0.90 | **0.82** |

So the *direct* dWER evidence for this line of work lives in the **UniPASE** paper (§4.2), which is GAP-URGENet's generative core. The fusion demonstrably improves speaker fidelity (0.82 vs 0.76 generative-only vs 0.70 predictive-only); its effect on content accuracy is **unpublished — treat as hypothesis**.

**Why it is still ranked first**: the fusion is precisely the architectural fix for §3. §3.1 shows discriminative branches are language-flat and content-faithful while generative branches are perceptually superior; this architecture keeps a predictive branch in the signal path so the output is anchored to the actual waveform rather than resynthesised from a semantic bottleneck. Combined with the best-in-class SpkSim and a challenge win on a CAcc-inclusive score, it is the best-hedged option — but **§8 is what will actually settle it for your material**.

**Sample rate**: internal 16 kHz core, PostNet BWE → 48 kHz, `--sr_out` selectable.
**Long audio**: ships **`inference.inference_long`** explicitly for >20 s inputs — the only candidate with a first-class long-form path.
**Apple Silicon**: pure PyTorch, `-D` accepts `cpu` (default `cuda:0`). No custom CUDA kernels. MPS untested (**hypothesis**: works with `-D mps`, may need dtype fixes).
**Caveats**: trained on URGENT 2026 corpora — **en/de/es/fr/zh, no Russian** (see §5). ~550M+ params. **Set `--enable_plc False`.** Packet-loss concealment is pure generative inpainting — the task where LLaSE-G1 hit 31.46% WER — and you have no packet loss to conceal. The risk is bounded (UniPASE's packet-loss detector only fires on near-digital-silence: amplitude threshold 1e-4 with a ≥0.99 zero-ratio, which an analog cinema capture will essentially never hit), but there is zero upside in leaving an inpainting path armed on a track where invented speech is the top-priority failure.

### #2 — UniPASE (pure generative, low-hallucination) — RECOMMENDED A/B ARM

- Repo: `github.com/Xiaobin-Rong/unipase` — **MIT**, pushed 2026-07-21, accepted **IEEE TASLP**
- Weights: `huggingface.co/Xiaobin-Rong/unipase` — **Apache-2.0**, 515 downloads
- Paper: arXiv **2604.14606v2**

**What it is**: DeWavLM-Omni (WavLM-Large distilled into a denoising expert) → Adapter → Vocoder (16 kHz) → PostNet (→48 kHz). Same *shape* as Sidon, but the SSL module is explicitly distilled to produce "linguistically faithful phonetic representations", and the vocoder is conditioned on the **degraded acoustic representations** to hold speaker identity.

**Faithfulness evidence — the best in this document.** UniPASE reports dWER/WER on four test sets against every major generative competitor:

DNS 2020 **with-reverb** (the hardest, closest to your reverberant CAM material):

| Model | Type | DNSMOS↑ | UTMOS↑ | PESQ↑ | SpkSim↑ | **dWER%↓** |
|---|---|---|---|---|---|---|
| Noisy | – | 1.39 | 1.30 | 1.16 | 0.70 | 10.23 |
| TF-GridNet | Predictive | 2.63 | 1.42 | 1.51 | 0.70 | 8.86 |
| StoRM | Generative | 2.87 | 1.84 | 1.39 | 0.60 | **49.65** |
| LLaSE-G1 | Generative | 3.35 | 2.90 | 1.20 | 0.55 | **41.66** |
| AnyEnhance | Generative | 3.20 | 2.75 | 1.79 | 0.70 | **14.16** |
| PASE | Generative | 2.75 | 1.61 | 1.41 | 0.60 | 9.78 |
| **UniPASE** | Generative | **3.33** | **3.62** | 1.74 | **0.79** | **8.16** |

Note the pattern: **StoRM 49.65%, LLaSE-G1 41.66%, AnyEnhance 14.16%** — all against a 10.23% noisy baseline. Most generative restorers make content *dramatically* worse under reverb. Only PASE/UniPASE beat the noisy input.

Other sets: DNS2020 no-reverb dWER **2.17%** (noisy 3.51); PLC-2024 WER **13.55%** (lossy 18.10, UNIVERSE++ 19.60, LLaSE-G1 31.46); VoiceFixer GSR dWER **8.21%** (noisy 9.50, VoiceFixer 12.64, AnyEnhance 10.10); URGENT 2025 non-blind CER **12.90%** (noisy 18.71) with SpkSim 0.81 vs `wataru9871`'s CER 20.30% / SpkSim 0.51.

**Cost**: 545.7M params, 79.2 GMACs/s. RTX 4090: 1 s @48 kHz ≈ 44 ms / 3.2 GB; 4 s ≈ 75 ms / 4.6 GB, **scaling linearly with duration** — so chunking is mandatory for 2.5 h, but `inference_long` exists.
**Caveats**: same en/de/es/fr/zh training as #1; 16 kHz core + BWE.

### #3 — Sidon (incumbent) — KEEP AS BASELINE ARM

Covered in §1. Strengths that genuinely matter for you and that #1/#2 lack: **104-language training including Russian**, **RU SpkSim 0.986**, MIT, already integrated, and a **CoreML port** (§6). Weakness: never improves content accuracy in any published table, and its class fails badly under blind out-of-domain evaluation.

### #4 — PASE (Cisco) — solid, English-first fallback

- Repo `github.com/cisco-open/pase` (**Apache-2.0**, pushed 2026-07-15), weights `huggingface.co/cisco-ai/pase` (**Apache-2.0**)
- Paper arXiv **2511.13300**, **AAAI 2026**
- **16 kHz mono only** (no BWE stage), 382M params
- Reported WER **6.76%**, SpkSim 0.80, DNSMOS 3.08, UTMOS 3.21
- Model card states plainly: *"trained primarily on English speech; performance may degrade for other languages."*
- Superseded by UniPASE on every metric; listed because Apache-2.0 + a clean single-stage 16 kHz pipeline is easier to integrate. **Only if you want the simplest possible drop-in.**

### #5 — NVIDIA RE-USE — strong numbers, likely unusable on your hardware

- Weights `huggingface.co/nvidia/RE-USE` + `nvidia/Real-time_RE-USE`; paper arXiv **2603.02641**
- **License: NVIDIA One-Way Noncommercial (NSCLv1)** — fine for personal use, but not a permissive license
- Architecture: two-stage **USEMamba** (30-layer bidirectional Mamba regression → 6-layer generative + multi-band CNN discriminators), 9.6M params, sampling-frequency-independent STFT supporting **8/16/22.05/24/32/44.1/48 kHz natively** — the only candidate with true native 48 kHz
- URGENT 2025 non-blind: DNSMOS 3.26, NISQA 4.12, UTMOS 2.80, PESQ 2.38, ESTOI 0.76, **CAcc 89.88%**. Per-subset (§3.3): **CAcc 92.50 @48 kHz and 92.20 @44.1 kHz — the only model here that raises content accuracy above the noisy input** (90.60 / 83.60), with the best SpkSim in the field (0.87 / 0.88). Its model card frames the goal in your exact terms: *"preserving fidelity, ensuring that all other factors remain unchanged, e.g., linguistic content, speaker identity, emotion, accent."*
- Trained en/de/es/fr/zh, evaluated zero-shot on it/nl/ja with "strong language-agnostic generalization"
- Sampling-frequency-independent: rescales n_fft/hop/win by `sr/8000` for a constant **200 fps** at any rate. Ships `inference.py` + `inference_chunk.py` for long audio. Upstream architecture is `RoyChao19477/SEMamba`.
- **The blocker is the licence, not the hardware.** Contrary to my first read, RE-USE *is* runnable on Apple Silicon via the pure-MLX `mlx-speech` port (no torch/triton/mamba-ssm), weights at `appautomaton/re-use-semamba-mlx`. But those weights inherit **NSCLv1 noncommercial**, and the one repo with a fused Metal selective-scan kernel ships **no LICENSE file at all** — legally unusable. For a personal hobby pipeline NSCLv1 is arguably fine; it is still a downgrade from Sidon's MIT and UniPASE's Apache-2.0. RTF on Apple Silicon is unpublished, and at 200 fps × 9,000 s = 1.8M frames this is sequence-length-bound despite only 9.6M params. See §6.

### #6 — ClearerVoice-Studio / MossFormer2_SE_48K — the conservative floor

- Repo: `github.com/modelscope/ClearerVoice-Studio` — **Apache-2.0**, 4,361 stars, **last push 2025-08-14 (dormant ~1 year)**
- Weights: `alibabasglab/MossFormer2_SE_48K` (enhancement), `alibabasglab/MossFormer2_SR_48K` (super-resolution), `MossFormerGAN_SE_16K`

**Why it deserves a slot despite being unmaintained — the safety argument is mathematical, not empirical.** `MossFormer2_SE_48K` predicts a **phase-sensitive mask** and multiplies it onto the input spectrogram. The decode path is literally `spectrum = real_part * pred_mask` followed by iSTFT. **A purely multiplicative mask can only attenuate energy that is already present — it is structurally incapable of inventing a word.** That is the strongest faithfulness guarantee available anywhere in this document, and it is verified by reading the code rather than trusting a benchmark. Independent confirmation in §3.3: CAcc 90.60 → 89.90, i.e. content essentially untouched.

**`MossFormer2_SR_48K` (= HiFi-SR, arXiv 2501.10045) has an equally good property for your band-limiting problem.** Its decode ends in `bandwidth_sub()`: it detects the input's effective `f_high` (99.96% energy) and returns `highpass(generated, f_high) + lowpass(original, f_high)`. **Your original speech band passes through untouched; only the synthetic high band is spliced in.** Contrast with Sidon, which downsamples everything to 16 kHz and regenerates the whole signal. LSD improvements: 16 kHz 2.80 → 1.93, 24 kHz 2.60 → 1.52.

**Apple Silicon — the best story in this document.** `starkdmi` has ported the whole family to MLX (Apache-2.0, Python + Swift): `MossFormer2_SE_48K_MLX` (fp32 221 MB down to int4 67 MB) at **25× realtime in Python, 30× in Swift**; `MossFormer2_SR_48K_MLX` at **~1e-5 parity with PyTorch and `bandwidth_sub` preserved**. Also `mlx-audio`'s own `mossformer2_se`. **Do not use the upstream `clearvoice` pip package on a Mac**: MPS was enabled in commit `55ef8598` (2025-07-02) then **silently reverted to CPU** in `0168707f` (2025-07-28) — the code still reads `self.device = torch.device('cpu') #torch.device('mps')`.

**Caveats**: it denoises; it does **not** restore, and CAcc says it will not improve intelligibility. Known issues that matter for cinema audio: **#58** — metallic/screeching artifacts after SR, with the maintainer replying *"try near-field speech, the model's support for far-field speech is currently insufficient"* (a CAM capture is far-field); **#2** — standalone audience laughter is often *kept* because the model reads it as speech; **#125/#122/#116** — long audio silenced or trimmed at the end, fixed on GitHub main but **the fix was never synced to HuggingFace**; **#101** — do not shrink `decode_window` below ~1 s. Training data is DNS4 + internal TTS; DNS4 is multilingual and does include Russian, but as its smallest slice (~18 h, **unverified**).

**Best-in-class Apple Silicon story, and this materially raises its ranking**: MossFormer2_SE_48K has a **native MLX port** — `starkdmi/MossFormer2_SE_48K_MLX` (plus 4-bit and 8-bit), driven by `mlx-audio` (MIT, actively developed, pushed 2026-07-31) with a one-line API (`model.enhance("noisy.wav")`) and **automatic chunking above 60 s**. It is the only 48 kHz enhancement model in this document that runs natively on Metal with no conversion work and no licence ambiguity. Also in `mlx-audio`: **DeepFilterNet3** (48 kHz, 2.1M params, **true stateful streaming** — chunk seams are exact by construction rather than crossfaded), weights `mlx-community/DeepFilterNet-mlx`.

**Use it as**: a fifth arm in §8, your fallback if every generative arm fails the dWER gate, and the cheapest thing to try first given it needs no porting. `MossFormer2_SR_48K` (speech super-resolution, also MLX-ported) separately targets the band-limiting problem — and unlike Sidon's implicit 16 kHz→48 kHz generation, it is a dedicated SR model you can evaluate on its own.

### Not recommended (and why)

| Model | Verdict |
|---|---|
| **AnyEnhance** | dWER **14.16%** vs 10.23% noisy under reverb, **10.10%** vs 9.50% on VoiceFixer GSR — measurably *adds* content errors. Only repo found is `viewfinder-annn/AnyEnhance-v1` (MIT, a CCF-AATC challenge baseline); no official HF weights located. 44.1 kHz. |
| **LLaSE-G1** | dWER **41.66%** (reverb), WER **31.46%** (PLC). Catastrophic. LM-based restorers are the worst offenders. |
| **StoRM / SGMSE-family** | dWER **49.65%** under reverb. Diffusion-in-waveform-domain hallucinated severely. |
| **Resemble Enhance** | **Hard disqualification.** §3.3: CAcc **83.60 → 47.20**, SDR **−15.01 dB**, SpkSim 0.71 → 0.61. Abandoned (last commit 2024-12-03). Maintainer confirms English-only (*"may not work as well with other languages"*); users report Spanish output *"sounds kinda german"*. Open issue **#43 "Enhancing changes words"** — *"Whenever I enhance audios some words being said change"* — unanswered for two years. This is your exact failure mode, reported by users, on a model that has no Russian training. |
| **VoiceFixer** | dWER **12.64%** vs 9.50% noisy *on its own benchmark*; reports MOS only. Author, in issue #36: *"the open-sourced model is not enough for production use and may encounter many bad cases."* Users report dropped `s` sounds. Fully vocoder-resynthesized, so voice drift is inherent. Both the RE-USE and CCF AATC papers use VoiceFixer as a *source of degradation* in their pipelines. |
| **Descript / Adobe** | **No open weights have ever been released by either.** Adobe Research publishes (DiTSE arXiv 2504.09381 — which names *"content hallucination, where plausible phonemes generated differ from the original utterance"* in its own abstract — and SpeechOp, which conditions on Whisper transcripts specifically to stop content drift) but ships nothing. `descript/dac` is a **codec**, not a restorer; it will not denoise anything, and `main` has not moved since 2023-07-20. Adobe Enhance user reports are nonetheless useful proxy evidence and map onto your material uncomfortably well: quiet off-mic speech turned into *"some weird non-english thing"*, phantom second speakers, and an explicit warning not to run it on files containing both music and voice. |
| **UNIVERSE++** | WER **19.60%** vs 18.10% lossy on PLC-2024 — no faithfulness gain. |
| **StuPASE** (arXiv 2603.09234) | Genuinely interesting — "low-hallucination **studio-quality**" is exactly the Miipher/Sidon niche done right (DNS1 with-reverb UTMOS 4.01, dWER 7.89%, SpkSim 0.74). But **16 kHz, English-only, and no code/weights released** (demo page only). **Watch this one.** |
| **DialogueSidon** | Two-speaker separator, not a restorer; CC-BY-NC-4.0; 24 kHz. See §7 for a speculative alternative use. |
| **Open-Miipher-2** | No weights; training from scratch only. |
| **TF-GridNet / BSRNN-FAN** (discriminative) | Best faithfulness of all (dWER 2.86%, CAcc 79.80%) and language-flat. Worth remembering as the conservative floor — but they denoise rather than restore, and won't fix band-limiting or separation smearing. |

---

## 5. Russian coverage — the awkward trade-off

| Candidate | Russian in training? | Evidence |
|---|---|---|
| **Sidon** | **Yes** — 104 languages | RU CER 0.042→0.043, RU SpkSim **0.986** (best of the 10 shown languages) |
| UniPASE / GAP-URGENet / PASE / StuPASE | **No** — en/de/es/fr/zh (URGENT corpora) | Russian would be an **unseen language** |
| RE-USE | No (en/de/es/fr/zh) | Claims zero-shot generalization to it/nl/ja |
| Miipher-2 | Yes (USM, 300+ langs) | Not obtainable |
| `lab260/ru-Miipher` | Russian-specific | Hackathon baseline, no metrics, no license — hypothesis only |

**This is the central tension in the whole decision.** §3.1 shows that the *unseen-language* case is exactly where generative restorers collapse (Japanese CAcc 74.5 → 36.8). UniPASE/GAP-URGENet have never seen Russian.

Two things blunt the risk but do not remove it:

1. WavLM-Large (UniPASE's backbone) was pretrained on English-dominant data, but Russian is Indo-European and phonologically much closer to the de/es/fr training mix than Japanese or Chinese are. Note that in the URGENT table T13's *European*-language degradation was mild (de 76.8→74.0, fr 67.3→**68.6**, es 80.8→80.9) while the collapse was confined to zh/ja. **This is the strongest single argument that Russian is a low-risk case for these models — but it is inference from a related-language pattern, not a Russian measurement. Hypothesis.**
2. GAP-URGENet's predictive branch is architecturally language-agnostic (it operates on spectrograms, not phonetic representations), which is why the hybrid should degrade more gracefully than pure UniPASE on an unseen language.

**No candidate has published Russian restoration numbers except Sidon.** You will have to generate that evidence yourself — which §8 does.

---

## 6. Apple Silicon runnability

| Path | Verdict |
|---|---|
| **Sidon, CPU TorchScript** (current) | Works. This is what you run today. |
| **Sidon, ONNX** ⭐ **best long-audio path** | `huggingface.co/soniqo/Sidon-ONNX` — MIT, fp32/fp16/int8. **The ONNX graph has a DYNAMIC time axis**, so you keep your own chunk length and overlap. fp16 (470 MB) is near-lossless: waveform cos 0.999, SI-SDR 28 dB. int8 (286 MB) cos 0.96, SpkSim 0.791 vs fp32 0.795. `onnxruntime` 1.28.0 ships macOS arm64 wheels with a **CoreML execution provider**. **Critical card warning, verbatim: "never quantize activations on this SSL encoder"** — activation-quantized int8 and 4-bit weight quant corrupt it (cos 0.26–0.59) because CNN/attention outliers get amplified by the DAC vocoder. Weight-only int8 is fine. |
| **Sidon, CoreML** | `huggingface.co/aufklarer/Sidon-CoreML` — MIT, 6,505 downloads, 2026-06-14. fp16 (713 MB, 1.7 GB peak) / int8 (407 MB, 1.3 GB peak) via `github.com/soniqo/speech-swift` (Apache-2.0, `brew install speech`). **Two catches.** (a) Fixed **T=499 (~10 s)** graph. (b) speech-swift's stitching is, verbatim from its own docs, *"non-overlapping 10 s windows… padded to the fixed graph length, restored, and concatenated"* — **no crossfade, no overlap**, i.e. **~900 hard butt-joins across a 2.5 h film**. That is strictly worse than what you already have. (c) **Speed claims conflict**: the HF card says ~120× RTF (ANE); speech-swift's docs say ~2 s per 10 s window ≈ **5× realtime**. That is 75 s vs ~30 min for your film. Unreconciled — **measure it**. |
| **Sidon, MPS** | **Blocked as shipped**, but not for the reason I first assumed. Only `_cpu.pt`/`_cuda.pt` exports exist (issue #5: device baked in). Workable route: load `sidon_raw_weight` (PEFT LoRA on `facebook/w2v-bert-2.0` + `decoder_state_dict.pt`, MIT) through transformers/PEFT and `.to("mps")` yourself. **Every op Sidon needs is MPS-native in torch 2.13** — STFT/iSTFT left the fallback list in 2023, `weight_norm` is native, complex-tensor support got heavy 2026 investment. TorchScript-on-MPS status: **unverified**. |
| **UniPASE / GAP-URGENet / PASE** | Pure PyTorch, no custom kernels; CLI exposes `-D cpu`. CPU definitely works; **MPS untested (hypothesis)**. Memory scales linearly with chunk length (~3.2 GB per 1 s @48 kHz on CUDA) — chunk short. |
| **RE-USE** | **Correction to my earlier assumption: it IS runnable on Apple Silicon — but the licence blocks it, not the compute.** `mamba-ssm` v2.3.2 no longer force-builds CUDA (the build is opt-in behind `MAMBA_FORCE_BUILD`). The actual blocker for a *PyTorch* install is **`triton`, which publishes no macOS wheels and no sdist**, and `mamba_ssm/__init__.py` imports it unguarded. However a **pure-MLX port exists**: `mlx-speech` 0.4.3 (MIT, `github.com/appautomaton/mlx-speech`) has no torch/triton/mamba-ssm dependency at all and ships `REUSEEnhancer`; weights at `appautomaton/re-use-semamba-mlx`. **But those weights inherit NSCLv1 (noncommercial), and the one fully-optimised Metal port (`PositiveLoss/re-use-mlx`) has no LICENSE file at all.** Sidon is MIT. RTF on Apple Silicon unpublished. |
| **MLX — correction** | I was wrong that MLX has no speech enhancement. `mlx-audio` (MIT, 7.7k★, pushed 2026-07-31) now has a first-class `sts/` tree including **`mossformer2_se`** and **DeepFilterNet 1/2/3**. Weights: **`starkdmi/MossFormer2_SE_48K_MLX`** (+4-bit/8-bit) — 48 kHz, ~55M params, `model.enhance("noisy.wav")`, auto-chunks >60 s; `mlx-community/DeepFilterNet-mlx` (48 kHz, **true stateful streaming** — seams are exact by construction). What genuinely does *not* exist in MLX: any SSL-feature-cleaner restorer. **No MLX Sidon, no MLX Miipher, no MLX w2v-BERT.** |

### PyTorch MPS caveats that matter here (torch 2.13.0, 2026-07-08)

Most historic blockers are gone — but three open **silent-corruption** bugs are directly in your path:

- **#189960 — `torch.cat` silently corrupts output and writes out of bounds past 2^31 elements**, open, high-priority, reproduced on 2.13.0. **This is exactly the reassembly step for a 2.5 h film.** Mitigation: **concatenate on CPU/NumPy, never on MPS.**
- **#169236 — `ConvTranspose1d/2d/3d` skip `output_padding < stride` validation → silently wrong output.** Open. Direct HiFi-GAN / DAC-decoder risk.
- **#169342 — `chunk()` views through conv give wrong results for batch > 1.** Open. Hits the chunk-then-batch pattern precisely; call `.contiguous()`.

Also worth taking for free: **#181725** — `nn.MultiheadAttention` is ~9× slower than calling `F.scaled_dot_product_attention` directly for bit-identical output.

Guardrails if you go MPS: run fp32, call SDPA directly, `.contiguous()` before convs, reassemble on CPU, and A/B a single chunk against the CPU path before committing 2.5 h. **MPS-vs-CPU speedup for a conformer or GAN vocoder is unverified** — no credible 2025–2026 benchmark exists.

### Chunking / seams — what real implementations do

| Project | Chunk | Overlap | Blend |
|---|---|---|---|
| **Your `sidon_infer.py`** | 30 s | 500 ms feature cache | re-decode held-back tail with right context |
| Sidon HF Space demo | 96 s | 1 frame | none |
| **Sidon repo `spaces/app.py`** (newer) | 120 s | 10 s | **linear crossfade** |
| speech-swift CoreML | 10 s | **0** | **none — butt-joined** |
| **resemble-enhance** | 30 s | 1 s | **mel cross-correlation offset search (5 ms) → shift → linear fade** |
| Demucs (the reference) | model `segment` | 0.25 | triangular weights, normalized weighted-sum |
| MossFormer2-SE (mlx-audio) | 4 s (auto >60 s) | 0.25 | discard-edges, keep the middle |

**Two traps specific to vocoder-based restoration:**

1. **Per-chunk peak normalization → audible level jumps.** Sidon's own Space does `0.9 * chunk / chunk.abs().max()` **per chunk**. **Your script normalizes globally before chunking — that is correct, keep it.** If you adopt anyone else's `inference_long`, check this first.
2. **Phase incoherence between independently vocoded chunks.** A naive overlap-add comb-filters because two separately generated chunks are not phase-aligned. `resemble-enhance`'s `compute_offset()` — mel-spectrogram cross-correlation at 5 ms resolution, shift the chunk, *then* blend — is the best-documented open mitigation. The cheaper alternative is to **split at VAD/silence boundaries** so seams land where there is no phase to mismatch.

The only documented audible-seam report found anywhere is speech-swift's DeepFilterNet3 note that GRU state re-zeroing degrades the first ~100–200 ms of each chunk, masked by their 500 ms crossfade, with *"stationary low-SNR noise may show a brief noise-floor flicker at boundaries."* Their regression test asserts levels stay within **1.5 dB** across a seam — a good acceptance criterion to steal. Sidon issue #1 (tail truncation) means keep zero-padding the input tail regardless of model.

---

## 7. Should the restoration stage exist at all?

**Yes — but its job should be redefined, and it should be re-validated after any separation upgrade.**

Arguments and evidence:

1. **Restoration cannot be a free win.** Sidon's own tables never show a content-accuracy improvement; the entire measured benefit is perceptual (DNSMOS +0.45, NISQA +1.2). If your goal is strictly "intelligible in one earbud", the stage is buying you *listening comfort and reduced fatigue*, not *more words understood*. That is still a legitimate goal for a 2.5 h film in a noisy room — just be honest that it is the goal.

2. **Better separation genuinely reduces the need.** Every restorer's headline gains come from removing noise/reverb the separator failed to remove. MelBand-RoFormer-class separators leave far less residue than demucs, which shrinks the restoration stage's remaining job to de-smearing and band-extension.

3. **But separation + restoration is a validated pattern — when the restorer is trained on separator output.** `arXiv 2603.04032` (CPJKU, "Multi-Stage Music Source Restoration with BandSplit-RoFormer Separation and HiFi++ GAN", code at `github.com/CPJKU/music-source-restoration`) adopts an explicit "separation-then-restoration" design, and its key methodological point is exactly the caveat that applies to you:

   > "we generate restoration inputs by running the trained separator on our synthetic training mixtures; each expert is then trained to map the resulting separator output to the corresponding clean stem, **exposing the restorers to realistic separation errors**."

   **None of the speech restorers in this document were trained on separator output.** Musical noise and spectral smearing are not in any of their degradation lists. You are running all of them out-of-distribution, which is precisely the condition under which §3 says generative restorers hallucinate.

4. **There is a whole challenge track on exactly your problem, and it settles the architecture question.** The **CCF AATC 2025 Speech Restoration Challenge** (retrospective: **arXiv 2509.12974**) had a third track dedicated to *"secondary processing artifacts"* — speech that had already been through an upstream separator (**Demucs, TF-GridNet, SGMSE+**) and then needed enhancement. That is your pipeline, precisely. Two results transfer directly:
   - **Discriminative models took ranks 1, 3, 4, 5 and 6.** Generative restoration was not the winning approach on separator-artifact input.
   - **DNSMOS correlated ρ = −0.8 with human MOS on hybrid-processed outputs** — i.e. on this exact class of material, DNSMOS is not merely uninformative but *inverted*. Anything you tune on DNSMOS you will tune backwards.
   - The winning architecture was **MP-SENet** (`github.com/yxlu-0102/MP-SENet`, MIT, 6.6M params) — small, discriminative, parallel magnitude-and-phase estimation. Worth adding to §8 as a seventh arm; it is cheap.

5. **Practical consequence**: treat separation quality as the primary lever and restoration as a secondary polish. If a MelBand-RoFormer upgrade lands, **re-run §8 with and without restoration** — it is entirely plausible the stage becomes net-negative once the stem is clean, because a good restorer on a clean stem mostly adds risk.

6. **A cheap hedge worth testing**: mix the restored track back with the *original* stem at partial gain rather than using it neat. This is independently recommended by ASR-evaluation practitioners and by Adobe Enhance users, on the same reasoning — it suppresses artifact-induced intelligibility loss and bounds how far any hallucination can travel, at the cost of some of the perceptual gain. A 70/30 or 50/50 blend is trivial to A/B alongside the neat arms.

5. **Speculative alternative framing (hypothesis, untested)**: your source is a Russian voiceover mixed over foreign-language theatrical dialogue — structurally a *two-speaker monaural mixture*, which is exactly **DialogueSidon**'s task. Using a dialogue *separator* rather than a music separator to pull the VO off the original dialogue bed might outperform vocals-stem separation followed by restoration. CC-BY-NC-4.0, 24 kHz, and completely unvalidated for this use — but cheap to try on one reel.

---

## 8. A/B test protocol (runnable on one film)

The whole point is to measure **faithfulness objectively**, because §3.1 proves listening tests and DNSMOS both fail to detect hallucination.

### Design

Arms, all from the same separated stem:

- **A0** — separated stem, no restoration (the control; also your fallback)
- **A1** — Sidon (current, 30 s/500 ms chunking)
- **A2** — GAP-URGENet (`--enable_plc False`)
- **A3** — UniPASE (`inference_long`)
- **A4** — MossFormer2_SE_48K via MLX (cheapest to run; the structurally-safe discriminative control) — optionally `+ MossFormer2_SR_48K` for bandwidth
- **A5** — MP-SENet (winner of the CCF AATC separator-artifact track; 6.6M params, MIT)
- *(optional)* **A6** — Sidon-ONNX fp16, to test whether the ONNX port is quality-neutral vs A1
- *(optional)* **A7** — best-performing arm blended back with A0 at 50/50 and 70/30 (see §7.6)

Run A4 first: it is the cheapest, and if it passes the ear test it may end the search.

### ⚠️ Read this before designing the harness

**arXiv 2605.12107, "Too Good to Be True: A Study on Modern ASR for the Evaluation of Speech Enhancement"** (Univ. Hamburg, 2026-05) runs almost exactly this experiment, with a 20-participant listening study as ground truth. Two findings change the protocol:

1. **Whisper is disqualified as an instrument, quantitatively.** Looping produced word accuracies as low as **−2061%** (one 11 s clip generating ~20× the reference word count). Unclipped, Whisper Base's correlation with human judgment collapses from PCC 0.82 → **0.32**. Parakeet TDT reached system-level SRCC **1.00**.
2. **The trap that will mislead you**: *"For Parakeet and Whisper, as well as humans, the enhancement of speech is counterproductive to speech recognition, as the WAcc is higher for the noisy subset than for any enhanced subset."* **A dWER increase after restoration is the expected baseline, not proof of hallucination.** This is why A0 is the reference and why you compare arms *against each other*, not against an absolute threshold.

Also: keeping punctuation cost ~10% WAcc and **changed system rankings in 18.6% of samples** — another reason to use an ASR that emits no punctuation.

### The faithfulness metric: dWER against the source stem

There is no ground-truth transcript for a pirate capture, so use the **source stem as pseudo-reference** — the same `dWER` construct UniPASE uses.

1. **Segment ONCE, not per-arm.** GigaAM caps at ~25 s per utterance. Derive VAD boundaries a **single time** and apply the *identical* boundaries to every arm — segmenting each file separately makes your diff measure segmentation jitter instead of content. Use silero-vad (MIT; `onnx-asr`'s `.with_vad("silero")` wires it up and avoids the gated `pyannote/segmentation-3.0`).
2. **Primary ASR: `gigaam-v3-ctc`** (MIT). Two good Apple Silicon runtimes:
   - `transcribe.cpp` (MIT, Metal) — measured **146× realtime on M4 Max**, Q8_0 259 MB, and quantization is essentially free (FLEURS-ru WER: F32 8.42%, Q8_0 8.40%). A 2.5 h film is ~60 s of compute.
   - `onnx-asr` (MIT, pure Python, CoreML EP) — has **built-in VAD long-form, token timestamps, and per-token log-probs**, the last of which is a useful confidence signal when triaging a diff.

   **Why CTC — a structural argument, not a benchmark result.** CTC emits one label per encoder frame then collapses. GigaAM-v3 subsamples to **40 ms frames**, so output length is hard-bounded at **~25 characters/second**, and the vocabulary is **33 characters** (space + а-я) with no subword prior to snap noise onto. It is arithmetically impossible for CTC to invent a sentence over a silent span. Whisper, being an unconstrained autoregressive LM over text, has no such bound.

   GigaAM-v3-CTC is also simply the right model for this audio: **Golos Farfield 4.5% vs Whisper large-v3 16.4%**; OpenSTT YouTube 11.6% vs 17.8%. Reverberant/distant-mic Russian is its strong suit.
3. **Cross-check with `gigaam-v3-rnnt` and `nvidia/parakeet-tdt-0.6b-v3`** (CC-BY-4.0, FLEURS ru 5.51%, different vendor and corpus; runs via `parakeet-mlx`). **A CTC-vs-RNN-T disagreement is itself the signal**: if CTC leaves a gap and RNN-T fills it with fluent text, that text came from the prediction network's LM, not from your audio.
4. **Diff with `jiwer.process_words`** (Apache-2.0), A0 as `reference`, each arm as `hypothesis`. It returns `alignments: List[List[AlignmentChunk]]` where each chunk has `.type ∈ {equal, substitute, insert, delete}` plus index ranges. Filter `type == "insert"` → **hallucination candidates**; `type == "delete"` → **dropped dialogue**. **Runs of consecutive insertions are the strongest hallucination signature.** jiwer tokenizes on whitespace and is script-agnostic, so Cyrillic needs no special handling.
5. **Normalization: keep it minimal.** Both transcripts come from the same ASR with the same conventions, and GigaAM-v3-CTC already emits lowercase, unpunctuated, 33-character Russian — the normalized form you want, with no normalization step to introduce its own artifacts. Add only ё→е folding and `num2words` (which has real Russian case/gender agreement) if numerals appear. Skip NeMo text processing: its Russian grammars exist but require `pynini`, which is **conda-only on macOS arm64**.
6. Report **dWER**, **insertion rate**, and **deletion rate separately** — never collapsed. Insertions ≈ invented words; deletions ≈ dropped dialogue. These are your two distinct hard constraints.

**Decision rule**: rank arms by insertion rate first, deletion rate second. Reject any arm whose insertion rate is materially above A0's noise floor or whose deletions cluster in the quiet slices. Do **not** apply an absolute dWER threshold — per "Too Good to Be True", some divergence is the ASR reacting to restoration artifacts rather than to changed words. Anchor every flagged span to a timestamp and confirm both tracks actually have acoustic energy there before believing it.

**Optional positive control**: run Whisper deliberately. Spans where Whisper invents text and GigaAM-CTC does not give you a free map of where your audio is degraded enough to break plausibility-driven models.

### Supporting metrics (secondary, never decisive)

- **Speaker identity**: cosine similarity of `wavlm-base-plus-sv` embeddings, A0 vs each arm — the same SpkSim used by both papers. §3.1's disaster case was 0.47; Sidon's RU claim is 0.986. **Anything below ~0.8 means the voice moved.**
- **LPS (Levenshtein Phoneme Similarity)** — explicitly designed to detect hallucination in generative SE; and **SpeechBERTScore** from `github.com/Takaaki-Saeki/DiscreteSpeechMetrics`.
- **DNSMOS / UTMOS** — report them if you like, but they cannot arbitrate anything here. Per the URGENT organizers they score hallucinated audio highly; §3.3 shows every model improves them including the one that destroys half the content; and per the CCF AATC retrospective, **DNSMOS correlates ρ = −0.8 with human MOS on separator-then-enhancer output specifically**. On your material this metric is actively inverted. Do not tune on it.

### Don't build the harness from scratch

- **`github.com/urgent-challenge/urgent2026_challenge_track1`** (Apache-2.0) ships the official evaluation scripts: **`calculate_wer.py`, `calculate_speaker_similarity.py`, `calculate_phoneme_similarity.py`** — WER, SpkSim and LPS already wired up and consistent with every number quoted in this document.
- **`github.com/sp-uhh/gibberish`** (AGPL-3.0, from the SGMSE lab) detects hallucinated speech via **LM perplexity** — a genuinely useful automated tripwire that flags fluent-but-wrong output without needing a reference, complementing the jiwer diff.

### Targeted stress slices

Averages over 2.5 h will hide exactly the failures you care about. Cut and score these separately:

- the **10 quietest dialogue minutes** (drop-out risk);
- **3–5 segments with heavy residual music/effects bleed** (low-SNR → the documented hallucination trigger);
- **all chunk boundaries** — concatenate ±2 s windows around every boundary into one file and listen; also diff dWER on that subset to catch seam-induced word loss;
- **the final 30 s** of the film (Sidon issue #1 tail truncation).

### Cheap pre-flight

Before spending hours on a full film, run one 5-minute reel through all arms. If an arm's dWER is already >20% or SpkSim <0.8, drop it immediately.

### Sequencing note

Run this **against your current separator first** to get a clean comparison, then re-run the winner-vs-A0 comparison after any MelBand-RoFormer upgrade — per §7, the right answer may change once the stem gets cleaner.

---

## Sources

**Sidon / sarulab-speech**
- https://arxiv.org/abs/2509.17052 · https://arxiv.org/html/2509.17052v1 · https://arxiv.org/pdf/2509.17052 (v3)
- https://github.com/sarulab-speech/Sidon/ (+ GitHub API: repo metadata, commit log, issues #1/#5/#9/#10)
- https://huggingface.co/sarulab-speech/sidon-v0.1 · https://huggingface.co/sarulab-speech/sidon_raw_weight
- https://huggingface.co/spaces/sarulab-speech/sidon_demo_beta/raw/main/app.py
- https://arxiv.org/abs/2604.09344 · https://arxiv.org/html/2604.09344 (DialogueSidon)
- https://huggingface.co/sarulab-speech/DialogueSidon
- HF API listing for author `sarulab-speech` (models + spaces)

**Miipher**
- https://arxiv.org/abs/2505.04457 · https://arxiv.org/pdf/2505.04457 · https://google.github.io/df-conformer/miipher2/
- https://github.com/yukara-ikemiya/Open-Miipher-2
- https://huggingface.co/lab260/ru-Miipher · https://huggingface.co/Atotti/miipher-2-HuBERT-HiFi-GAN-v0.1

**URGENT challenges (the faithfulness evidence)**
- https://arxiv.org/pdf/2505.23212 (URGENT 2025, Interspeech — Tables 2 & 3, §4.2, §4.3)
- https://arxiv.org/abs/2601.13531 (ICASSP 2026 URGENT)
- https://urgent-challenge.github.io/urgent2026/track1/ · https://v2.urgent-challenge.com/

**PASE / UniPASE / GAP-URGENet / StuPASE**
- https://arxiv.org/abs/2511.13300 (PASE, AAAI 2026) · https://ojs.aaai.org/index.php/AAAI/article/view/40562
- https://github.com/cisco-open/pase · https://huggingface.co/cisco-ai/pase
- https://arxiv.org/pdf/2604.14606 (UniPASE, IEEE TASLP — Tables IV–VIII)
- https://github.com/Xiaobin-Rong/unipase · https://huggingface.co/Xiaobin-Rong/unipase
- https://arxiv.org/abs/2604.01832 · https://github.com/Xiaobin-Rong/gap-urgenet · https://huggingface.co/Xiaobin-Rong/gap-urgenet
- https://arxiv.org/html/2603.09234 (StuPASE)

**Other restoration candidates**
- https://arxiv.org/html/2603.02641v2 · https://huggingface.co/nvidia/RE-USE (RE-USE / USEMamba)
- https://github.com/modelscope/ClearerVoice-Studio (+ GitHub API metadata, `clearvoice/utils/decode.py`, `networks.py`, issues #2/#58/#101/#116/#122/#125/#127/#169) · https://www.isca-archive.org/interspeech_2025/zhao25f_interspeech.pdf · https://arxiv.org/abs/2501.10045 (HiFi-SR = MossFormer2_SR_48K) · https://huggingface.co/alibabasglab/MossFormer2_SE_48K · https://huggingface.co/alibabasglab/MossFormer2_SR_48K
- https://github.com/resemble-ai/resemble-enhance (issues #6/#43/#44/#57/#64) · https://github.com/haoheliu/voicefixer (issues #36/#38/#57/#58) · https://arxiv.org/abs/2109.13731
- https://arxiv.org/abs/2509.12974 (CCF AATC 2025 Speech Restoration Challenge retrospective — separator-artifact track) · https://github.com/yxlu-0102/MP-SENet
- https://arxiv.org/abs/2504.09381 (Adobe DiTSE) · https://arxiv.org/abs/2509.14298 (Adobe SpeechOp) · https://github.com/descriptinc/descript-audio-codec · https://news.ycombinator.com/item?id=34047976
- https://github.com/sp-uhh/sgmse · https://github.com/sp-uhh/gibberish · https://github.com/urgent-challenge/urgent2026_challenge_track1
- MLX ports: https://github.com/starkdmi/mossformer_se_mlx · https://github.com/starkdmi/mossformer_sr_mlx · https://huggingface.co/starkdmi/MossFormer2_SE_48K_MLX · https://huggingface.co/starkdmi/MossFormer2_SR_48K_MLX · https://github.com/Blaizzy/mlx-audio · https://github.com/kylehowells/DeepFilterNet-mlx · https://github.com/appautomaton/mlx-speech · https://github.com/RoyChao19477/RE-USE-MPS
- Apple Silicon / ASR tooling: https://github.com/handy-computer/transcribe.cpp · https://github.com/istupakov/onnx-asr · https://github.com/senstella/parakeet-mlx · https://github.com/salute-developers/GigaAM · https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 · https://github.com/jitsi/jiwer · https://github.com/snakers4/silero-vad
- PyTorch MPS correctness issues: pytorch/pytorch #189960, #169236, #169342, #181725, #188756
- ASR-as-SE-metric methodology: https://arxiv.org/abs/2605.12107 ("Too Good to Be True") · https://arxiv.org/abs/2402.08021 ("Careless Whisper") · https://arxiv.org/abs/2502.12414 (Hallucination Error Rate)
- https://arxiv.org/html/2604.01832 (GAP-URGENet full text — validation ablation, Table 1)
- https://arxiv.org/abs/2501.15417 · https://arxiv.org/html/2501.15417 (AnyEnhance) · https://github.com/viewfinder-annn/AnyEnhance-v1
- https://arxiv.org/abs/2508.17229 (Multi-Metric Preference Alignment for Generative Speech Restoration)
- https://github.com/honee-w/flowse · https://github.com/seongq/flowmse (FlowSE)
- https://arxiv.org/html/2605.08608 (Reducing Linguistic Hallucination in LM-Based SE)

**Separation + restoration stacking**
- https://arxiv.org/pdf/2603.04032 · https://github.com/CPJKU/music-source-restoration
- https://arxiv.org/abs/2407.07275 (DnR v3, multilingual cinematic separation) · https://arxiv.org/pdf/2506.02499 (DnR-nonverbal)

**Apple Silicon**
- https://huggingface.co/aufklarer/Sidon-CoreML · https://github.com/soniqo/speech-swift · https://huggingface.co/soniqo/Sidon-ONNX

**Evaluation tooling**
- https://huggingface.co/ai-sage/GigaAM-v3 · https://huggingface.co/istupakov/gigaam-v3-onnx · https://huggingface.co/al-bo/gigaam-v3-rnnt-mlx
- https://github.com/Takaaki-Saeki/DiscreteSpeechMetrics · https://arxiv.org/html/2401.16812v3 (SpeechBERTScore)

**Local files inspected**
- `/Users/pavel.karpovich/Projects/allspeak/scripts/sidon_infer.py`
