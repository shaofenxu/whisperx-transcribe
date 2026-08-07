# =============================================================================
# transcribe.R -- Drive the WhisperX command-line tool from R.
#
# Requires R/utils.R to have been sourced first.
# =============================================================================


#' Work out how to invoke WhisperX
#'
#' If `conda_env` is supplied the call is routed through `conda run`, which
#' works identically on Windows, macOS and Linux and needs no shell activation
#' script. Otherwise `whisperx` is called directly and must be on the PATH.
#'
#' @return A list with `command` and `prefix` (arguments that precede the
#'   WhisperX arguments proper).
whisperx_invocation <- function(conda_env = NULL, conda_bin = "conda") {
  if (is.null(conda_env) || !nzchar(conda_env)) {
    list(command = "whisperx", prefix = character(0))
  } else {
    list(
      command = conda_bin,
      prefix  = c("run", "-n", conda_env, "--no-capture-output", "whisperx")
    )
  }
}

#' Check that WhisperX can actually be started
#'
#' @return TRUE if `whisperx --help` exits cleanly, FALSE otherwise.
check_whisperx <- function(conda_env = NULL, conda_bin = "conda") {
  inv <- whisperx_invocation(conda_env, conda_bin)
  status <- tryCatch(
    suppressWarnings(
      system2(inv$command, c(inv$prefix, "--help"), stdout = FALSE, stderr = FALSE)
    ),
    error = function(e) 127L
  )
  isTRUE(status == 0L)
}

#' Build the WhisperX argument vector for one audio file
#'
#' @param audio Path to the audio file.
#' @param output_dir Directory WhisperX should write into.
#' @param opts A list of options; see CONFIG in run_pipeline.R.
build_whisperx_args <- function(audio, output_dir, opts) {
  args <- c(
    shell_quote(normalizePath(audio, mustWork = FALSE)),
    "--model",         opts$model,
    "--output_dir",    shell_quote(normalizePath(output_dir, mustWork = FALSE)),
    "--output_format", opts$output_format,
    "--device",        opts$device,
    "--compute_type",  opts$compute_type
  )

  # Fixing the language skips detection and is both faster and more reliable.
  # Leave NULL to let WhisperX detect it.
  if (!is.null(opts$language) && nzchar(opts$language)) {
    args <- c(args, "--language", opts$language)
  }
  if (!is.null(opts$threads)) {
    args <- c(args, "--threads", as.character(opts$threads))
  }
  if (!is.null(opts$batch_size)) {
    args <- c(args, "--batch_size", as.character(opts$batch_size))
  }

  if (isTRUE(opts$diarize)) {
    args <- c(args, "--diarize")
    # Bounding the speaker count markedly improves diarization when the number
    # of people in the room is known in advance.
    if (!is.null(opts$min_speakers)) {
      args <- c(args, "--min_speakers", as.character(opts$min_speakers))
    }
    if (!is.null(opts$max_speakers)) {
      args <- c(args, "--max_speakers", as.character(opts$max_speakers))
    }
    # The child process inherits HF_TOKEN from this R session, so the flag is
    # only needed for WhisperX builds that do not fall back to the environment.
    # See `pass_token_on_command_line` in run_pipeline.R.
    if (isTRUE(opts$pass_token_on_command_line) &&
        !is.null(opts$hf_token) && nzchar(opts$hf_token)) {
      args <- c(args, "--hf_token", opts$hf_token)
    }
  }

  c(args, opts$extra_args)
}

#' Transcribe a single audio file
#'
#' Existing output is left alone unless `opts$overwrite` is TRUE, so an
#' interrupted run can simply be restarted.
#'
#' @return A one-row tibble: audio, json, status, seconds.
transcribe_one <- function(audio, output_dir, opts) {
  json_path <- file.path(output_dir, paste0(file_stem(audio), ".json"))
  result <- function(status, seconds = NA_real_) {
    tibble::tibble(audio = audio, json = json_path,
                   status = status, seconds = seconds)
  }

  if (!file.exists(audio)) {
    log_msg("Audio file not found: ", audio, level = "ERROR")
    return(result("missing"))
  }
  if (file.exists(json_path) && !isTRUE(opts$overwrite)) {
    log_msg("Skipping, transcript already present: ", basename(json_path))
    return(result("skipped"))
  }

  inv  <- whisperx_invocation(opts$conda_env, opts$conda_bin)
  args <- c(inv$prefix, build_whisperx_args(audio, output_dir, opts))

  log_msg("Command: ",
          redact(paste(c(inv$command, args), collapse = " "), opts$hf_token))

  if (isTRUE(opts$dry_run)) return(result("dry-run"))

  started <- Sys.time()
  status <- tryCatch(
    system2(inv$command, args),
    error = function(e) {
      log_msg("Could not start WhisperX: ", conditionMessage(e), level = "ERROR")
      127L
    }
  )
  elapsed <- as.numeric(difftime(Sys.time(), started, units = "secs"))

  if (!identical(as.integer(status), 0L)) {
    log_msg("WhisperX exited with status ", status, " for ", basename(audio),
            level = "ERROR")
    return(result("failed", elapsed))
  }
  if (!file.exists(json_path)) {
    log_msg("WhisperX reported success but no JSON was written for ",
            basename(audio), level = "ERROR")
    return(result("no-output", elapsed))
  }

  log_msg(sprintf("Done in %s: %s", seconds_to_hms(elapsed), basename(audio)))
  result("ok", elapsed)
}

#' Transcribe every file in a vector
#'
#' A failure on one recording is logged and the run continues, so one bad file
#' does not cost you the whole batch.
#'
#' @return A tibble with one row per input file.
transcribe_all <- function(audio_files, output_dir, opts) {
  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

  n <- length(audio_files)
  results <- vector("list", n)
  for (i in seq_len(n)) {
    log_msg(sprintf("[%d/%d] %s", i, n, basename(audio_files[i])))
    results[[i]] <- transcribe_one(audio_files[i], output_dir, opts)
  }
  out <- dplyr::bind_rows(results)

  tally <- table(out$status)
  log_msg("Transcription summary: ",
          paste(sprintf("%s=%d", names(tally), as.integer(tally)),
                collapse = ", "))

  failed <- out$audio[out$status %in% c("failed", "missing", "no-output")]
  if (length(failed) > 0) {
    log_msg("The following recordings produced no transcript:\n  ",
            paste(basename(failed), collapse = "\n  "), level = "WARN")
  }
  out
}
