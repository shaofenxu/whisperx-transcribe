# whisperx-transcribe

Batch-transcribe a folder of audio recordings with [WhisperX](https://github.com/m-bain/whisperX) – speech recognition, word-level alignment and speaker diarization – and compile the results into a single tidy, timestamped transcript ready for analysis.

R drives the pipeline; WhisperX does the heavy lifting. Everything runs locally: your audio never leaves the machine.

> This began as a set of scripts for transcribing a batch of recorded group discussions in a research project ([10.36399/gla.pubs.397771](https://doi.org/10.36399/gla.pubs.397771)). It has been rewritten here as a general-purpose tool, with no project-specific content.

---

## What it does

1. **Finds** every audio file in a folder (mp3, wav, m4a, flac, …).
2. **Transcribes** each one with WhisperX, with optional speaker diarization.
3. **Compiles** the JSON output into one tidy table, merging consecutive segments by the same speaker into conversational turns.
4. **Exports** a CSV, one readable `.txt` per recording, and a per-recording summary.

Runs are resumable: files that already have a transcript are skipped, so an interrupted batch just picks up where it stopped.

---

## Requirements

| | |
|---|---|
| R | ≥ 4.1 (the scripts use the native `\|>` pipe) |
| R packages | `dplyr` (≥ 1.0), `purrr`, `readr`, `stringr`, `tibble`, `jsonlite` |
| Python | WhisperX in a conda environment, plus `ffmpeg` |
| Hugging Face | A read token, only if you want speaker diarization |

```r
install.packages(c("dplyr", "purrr", "readr", "stringr", "tibble", "jsonlite"))
```

### Install WhisperX

```bash
conda env create -f environment/whisperx.yml
conda activate whisperx
whisperx --help          # check it starts
```

Or, if you prefer to build the environment yourself:

```bash
conda create -n whisperx python=3.10 ffmpeg -c conda-forge
conda activate whisperx
pip install whisperx
```

The pipeline calls WhisperX through `conda run`, so you do **not** need to activate the environment before running it – but `conda` does need to be on your PATH. If it isn't, set `conda_bin` in `CONFIG` to the full path of the conda executable, or install WhisperX so that `whisperx` is on the PATH and set `conda_env = NULL`.

### Hugging Face token (diarization only)

Speaker diarization uses [pyannote.audio](https://github.com/pyannote/pyannote-audio) models, which are gated. One-off setup:

1. Create a **read** token at <https://huggingface.co/settings/tokens>.
2. Accept the terms for `pyannote/segmentation-3.0` and `pyannote/speaker-diarization-3.1` on the Hugging Face website.
3. Make the token available as an environment variable. Copy `.Renviron.example` to `.Renviron` and paste it in:

   ```r
   # ~/.Renviron  or  ./.Renviron  (restart R afterwards)
   HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxx
   ```

   ```bash
   # or, for a shell session
   export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxx
   ```

The token is never written into the code and never committed. It downloads model weights – no audio is uploaded. If you don't want speaker labels at all, set `diarize = FALSE` and skip this entirely.

---

## Quick start

```
your-project/
├── audio/              # put your recordings here
├── R/
├── run_pipeline.R
└── output/             # created for you
```

```bash
Rscript run_pipeline.R
```

Or from an R session, with the repository root as the working directory:

```r
source("run_pipeline.R")
```

Before committing to a long run, try `dry_run = TRUE` – it prints the exact WhisperX commands (with the token redacted) without executing them.

---

## Configuration

Everything is set in the `CONFIG` list at the top of `run_pipeline.R`.

### Input and output

| Option | Default | Notes |
|---|---|---|
| `audio_dir` | `"audio"` | Folder to scan |
| `audio_files` | `character()` | Explicit file list; overrides `audio_dir` |
| `audio_pattern` | mp3/wav/m4a/… | Case-insensitive regex |
| `recursive` | `TRUE` | Search sub-folders |
| `output_dir` | `"output"` | Everything is written under here |
| `transcript_filename` | `"transcript.csv"` | |
| `write_text` | `TRUE` | Also write readable `.txt` per recording |
| `excel_bom` | `TRUE` | UTF-8 BOM so Excel on Windows opens it correctly |

### Transcription

| Option | Default | Notes |
|---|---|---|
| `model` | `"large-v2"` | `tiny`/`base`/`small`/`medium`/`large-v2`/`large-v3` |
| `language` | `"en"` | `NULL` to auto-detect; fixing it is faster and steadier |
| `device` | `"cpu"` | `"cuda"` on a supported NVIDIA GPU |
| `compute_type` | `"int8"` | `"float16"` is the usual GPU choice |
| `threads` | `4` | CPU threads |
| `batch_size` | `NULL` | e.g. `16` on GPU |
| `output_format` | `"json"` | `"all"` also writes srt/vtt/txt/tsv |
| `extra_args` | `character()` | Any further WhisperX flags, passed verbatim |

### Diarization

| Option | Default | Notes |
|---|---|---|
| `diarize` | `TRUE` | Requires `HF_TOKEN` |
| `min_speakers`, `max_speakers` | `NULL` | **Set these if you know the number of people.** It is the single most effective way to improve diarization |
| `pass_token_on_command_line` | `TRUE` | The child process inherits `HF_TOKEN` anyway; set `FALSE` to keep the token out of the process list, if your WhisperX build reads the environment |

### Compilation

| Option | Default | Notes |
|---|---|---|
| `merge_turns` | `TRUE` | Merge consecutive same-speaker segments into turns |
| `max_gap` | `Inf` | Don't merge across a silence longer than this (seconds) |
| `unknown_speaker` | `"UNKNOWN"` | Label for segments diarization left unassigned |
| `min_chars` | `1` | Drop turns shorter than this |
| `speaker_map` | `NULL` | CSV of real names or pseudonyms; see below |

### Run behaviour

| Option | Default | Notes |
|---|---|---|
| `overwrite` | `FALSE` | `FALSE` makes runs resumable |
| `dry_run` | `FALSE` | Print commands only |
| `log_dir` | `"logs"` | One timestamped log per run |

---

## Output

```
output/
├── transcript.csv        # the compiled transcript
├── summary.csv           # one row per recording
├── text/                 # readable transcripts, one per recording
│   └── interview_01.txt
└── whisperx/             # raw WhisperX JSON -- keep it, it's the source of truth
    └── interview_01.json
logs/
└── run_20260101_093000.log
```

Because the raw JSON is kept, you can re-compile with different settings at any time without re-transcribing – see [Using the functions directly](#using-the-functions-directly).

### `transcript.csv`

| Column | Type | Description |
|---|---|---|
| `recording_id` | chr | Audio file name without extension |
| `turn` | int | Turn number within the recording, from 1 |
| `speaker` | chr | Diarization label, or your own label via `speaker_map` |
| `start_hms`, `end_hms` | chr | `HH:MM:SS`, for locating the turn in the audio |
| `start`, `end` | dbl | Seconds from the start of the recording |
| `duration` | dbl | `end - start` in seconds; includes any pause inside a merged turn |
| `n_words` | int | Whitespace-delimited word count |
| `text` | chr | The turn |
| `source_file` | chr | JSON file the row came from |

### Naming speakers

Diarization labels are assigned **per file**: `SPEAKER_00` in one recording is not the same person as `SPEAKER_00` in another. The mapping is therefore keyed on both columns.

`examples/speaker_map.csv`:

```csv
recording_id,speaker,label
interview_01,SPEAKER_00,Facilitator
interview_01,SPEAKER_01,P01
interview_02,SPEAKER_00,P02
```

Point `speaker_map` at your version. Rows you leave out keep their original label. Use pseudonyms rather than real names if the transcripts will be shared.

---

## Using the functions directly

The three files in `R/` are independent of the driver and can be sourced on their own:

```r
source("R/utils.R"); source("R/compile.R")

# Recompile from existing JSON without re-transcribing anything
transcript <- compile_transcripts("output/whisperx", max_gap = 5)

# One long recording, no merging
segments <- read_whisperx_json("output/whisperx/interview_01.json")
```

---

## Things worth knowing

**Runtime.** On CPU, `large-v2` runs at roughly real time or slower – an hour of audio can take an hour or more, and diarization adds to that. Use `small` or `medium` while you're testing the setup, and switch to `large-v2` for the real run. A CUDA GPU is an order of magnitude faster.

**Diarization is the weak link.** Overlapping speech, cross-talk and quiet participants all cause errors, and speaker counts drift when several people sound similar. Constrain it with `min_speakers`/`max_speakers` whenever you can.

**Whisper hallucinates on silence.** Long silences, background music and non-speech noise can produce fluent, entirely invented text – often a repeated stock phrase. Skim the output before you trust it.

**Nothing here replaces checking the transcript.** Timestamps exist so that any turn can be found in the audio in seconds. For anything that will be quoted or coded, verify against the recording.

**Recording quality dominates everything else.** A table microphone in a quiet room beats any amount of model tuning.

**Personal data.** Recordings of identifiable people are personal data. `.gitignore` excludes `audio/`, `output/` and common media and transcript formats by default – check it before your first commit, and keep audio out of the repository. Where consent or ethics approval limits how the material may be handled, note that the models are downloaded once and then run locally.

---

## Repository layout

```
├── R/
│   ├── utils.R           # logging, formatting, preconditions
│   ├── transcribe.R      # builds and runs the WhisperX commands
│   └── compile.R         # JSON -> tidy transcript
├── environment/
│   └── whisperx.yml      # conda environment
├── examples/
│   └── speaker_map.csv
├── run_pipeline.R        # configuration + driver
├── .Renviron.example     # template for your HF_TOKEN
├── CITATION.cff
└── LICENSE
```

---

## Credits

The transcription itself is entirely WhisperX's work; this repository is a wrapper around it. If you publish results produced with it, cite:

> Bain, M., Huh, J., Han, T., & Zisserman, A. (2023). WhisperX: Time-Accurate Speech Transcription of Long-Form Audio. *Proc. INTERSPEECH 2023*, 4489–4493. https://doi.org/10.21437/Interspeech.2023-78

> Radford, A., Kim, J. W., Xu, T., Brockman, G., McLeavey, C., & Sutskever, I. (2023). Robust Speech Recognition via Large-Scale Weak Supervision. *ICML 2023*, 28492–28518.

And, if you used diarization:

> Bredin, H. (2023). pyannote.audio 2.1 speaker diarization pipeline: principle, benchmark, and recipe. *Proc. INTERSPEECH 2023*.

## Licence

MIT – see [LICENSE](LICENSE). WhisperX, Whisper and pyannote.audio carry their own licences.
