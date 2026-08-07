#!/usr/bin/env Rscript
# =============================================================================
# run_pipeline.R
#
# Batch-transcribe a folder of audio recordings with WhisperX (speech
# recognition + speaker diarization) and compile the results into a single
# tidy, timestamped transcript.
#
# Everything you normally need to change lives in the CONFIG block below.
#
# Usage:
#   Rscript run_pipeline.R          # from the repository root
#   source("run_pipeline.R")        # or from an R session / RStudio
#
# See README.md for setup instructions.
# =============================================================================


# ---- Configuration ----------------------------------------------------------

CONFIG <- list(

  ## Input -------------------------------------------------------------------
  # Either point audio_dir at a folder, or list files explicitly in
  # audio_files (which takes precedence when non-empty).
  audio_dir     = "audio",
  audio_files   = character(),
  audio_pattern = "\\.(mp3|wav|m4a|mp4|flac|ogg|opus|aac|wma)$",
  recursive     = TRUE,

  ## Output ------------------------------------------------------------------
  output_dir          = "output",
  transcript_filename = "transcript.csv",
  write_text          = TRUE,   # also write one readable .txt per recording
  excel_bom           = TRUE,   # UTF-8 BOM so Excel on Windows opens it cleanly

  ## How to reach WhisperX ---------------------------------------------------
  # conda_env: name of the conda environment WhisperX lives in. The call is
  # routed through `conda run`, which behaves the same on every platform.
  # Set to NULL if `whisperx` is already on your PATH.
  conda_env = "whisperx",
  conda_bin = "conda",

  ## Transcription -----------------------------------------------------------
  model         = "large-v2",   # tiny | base | small | medium | large-v2 | large-v3
  language      = "en",         # NULL to let WhisperX detect the language
  device        = "cpu",        # "cuda" if you have a supported NVIDIA GPU
  compute_type  = "int8",       # "float16" is the usual choice on GPU
  threads       = 4,            # CPU threads for inference
  batch_size    = NULL,         # e.g. 16 on GPU; NULL uses the WhisperX default
  output_format = "json",       # "all" also writes srt/vtt/txt/tsv
  extra_args    = character(),  # any further WhisperX flags, verbatim

  ## Speaker diarization -----------------------------------------------------
  diarize      = TRUE,
  min_speakers = NULL,          # set both if you know the number of people
  max_speakers = NULL,          #   in the room -- it improves results a lot
  # The Hugging Face token is read from the HF_TOKEN environment variable and
  # inherited by the WhisperX process. Passing it as a flag as well is more
  # compatible but makes it briefly visible in the system process list.
  pass_token_on_command_line = TRUE,

  ## Compilation -------------------------------------------------------------
  merge_turns     = TRUE,       # merge consecutive segments by the same speaker
  max_gap         = Inf,        # ...but not across a silence longer than this
  unknown_speaker = "UNKNOWN",
  min_chars       = 1,
  speaker_map     = NULL,       # optional CSV; see examples/speaker_map.csv

  ## Run behaviour -----------------------------------------------------------
  overwrite = FALSE,            # FALSE lets an interrupted run resume
  dry_run   = FALSE,            # print the commands without running them
  log_dir   = "logs"
)


# ---- Setup ------------------------------------------------------------------

for (f in c("R/utils.R", "R/transcribe.R", "R/compile.R")) {
  if (!file.exists(f)) {
    stop("Cannot find ", f, ". Run this script from the repository root.",
         call. = FALSE)
  }
  source(f)
}

require_packages()

log_path <- start_log(CONFIG$log_dir)
log_msg("WhisperX transcription pipeline")
log_msg("Log file: ", log_path)

hf_token <- Sys.getenv("HF_TOKEN", unset = "")
if (isTRUE(CONFIG$diarize) && !nzchar(hf_token)) {
  stop(
    "Speaker diarization is switched on but HF_TOKEN is not set.\n",
    "Create a read token at https://huggingface.co/settings/tokens, accept the ",
    "terms for the pyannote segmentation and speaker-diarization models, then ",
    "set HF_TOKEN in your environment (or in ~/.Renviron).\n",
    "To transcribe without speaker labels instead, set diarize = FALSE.",
    call. = FALSE
  )
}
opts <- c(CONFIG, list(hf_token = hf_token))

if (!isTRUE(CONFIG$dry_run) &&
    !check_whisperx(CONFIG$conda_env, CONFIG$conda_bin)) {
  stop(
    "Could not run WhisperX.\n",
    "Checked: ", if (is.null(CONFIG$conda_env)) {
      "`whisperx` on the PATH"
    } else {
      paste0("`", CONFIG$conda_bin, " run -n ", CONFIG$conda_env, " whisperx`")
    }, "\n",
    "Verify the installation, or set conda_env = NULL if whisperx is already ",
    "on your PATH.",
    call. = FALSE
  )
}


# ---- 1. Locate the recordings ----------------------------------------------

audio_files <- if (length(CONFIG$audio_files) > 0) {
  CONFIG$audio_files
} else {
  find_audio(CONFIG$audio_dir, CONFIG$audio_pattern, CONFIG$recursive)
}

if (length(audio_files) == 0) {
  stop("No audio files matched in ",
       normalizePath(CONFIG$audio_dir, mustWork = FALSE), call. = FALSE)
}
assert_unique_stems(audio_files)
log_msg("Found ", length(audio_files), " recording(s)")


# ---- 2. Transcribe ----------------------------------------------------------

json_dir <- file.path(CONFIG$output_dir, "whisperx")
results  <- transcribe_all(audio_files, json_dir, opts)

if (isTRUE(CONFIG$dry_run)) {
  log_msg("Dry run finished; nothing was transcribed or compiled.")
} else {


# ---- 3. Compile -------------------------------------------------------------

  transcript <- compile_transcripts(
    json_dir        = json_dir,
    merge_turns     = CONFIG$merge_turns,
    max_gap         = CONFIG$max_gap,
    unknown_speaker = CONFIG$unknown_speaker,
    min_chars       = CONFIG$min_chars
  )

  if (!is.null(CONFIG$speaker_map) && nzchar(CONFIG$speaker_map)) {
    if (file.exists(CONFIG$speaker_map)) {
      transcript <- apply_speaker_map(transcript, CONFIG$speaker_map)
    } else {
      log_msg("Speaker map not found, keeping diarization labels: ",
              CONFIG$speaker_map, level = "WARN")
    }
  }


# ---- 4. Export --------------------------------------------------------------

  if (!dir.exists(CONFIG$output_dir)) {
    dir.create(CONFIG$output_dir, recursive = TRUE)
  }

  csv_path <- file.path(CONFIG$output_dir, CONFIG$transcript_filename)
  if (isTRUE(CONFIG$excel_bom)) {
    readr::write_excel_csv(transcript, csv_path, na = "")
  } else {
    readr::write_csv(transcript, csv_path, na = "")
  }
  log_msg("Wrote ", nrow(transcript), " turns to ", csv_path)

  if (isTRUE(CONFIG$write_text)) {
    text_dir <- file.path(CONFIG$output_dir, "text")
    write_readable_transcripts(transcript, text_dir)
    log_msg("Wrote readable transcripts to ", text_dir)
  }

  overview <- summarise_transcript(transcript)
  readr::write_csv(overview, file.path(CONFIG$output_dir, "summary.csv"))
  log_msg("Per-recording summary:")
  print(as.data.frame(overview), row.names = FALSE)

  log_msg("Finished.")
}

invisible(results)
