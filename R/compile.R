# =============================================================================
# compile.R -- Read WhisperX JSON output and compile it into one tidy,
#              timestamped transcript.
#
# Requires R/utils.R to have been sourced first.
# =============================================================================


#' The empty segment table, used as the schema everywhere below
empty_segments <- function() {
  tibble::tibble(
    recording_id = character(),
    source_file  = character(),
    start        = numeric(),
    end          = numeric(),
    speaker      = character(),
    text         = character()
  )
}

#' Read the segments out of one WhisperX JSON file
#'
#' Only the four fields that matter are kept. This deliberately drops the
#' nested `words` list-column: its shape varies between files, and binding
#' files that differ in that shape is a common source of failure.
#'
#' @return A tibble with the `empty_segments()` schema.
read_whisperx_json <- function(path) {
  parsed <- tryCatch(
    jsonlite::fromJSON(path, simplifyVector = TRUE),
    error = function(e) {
      log_msg("Could not parse ", basename(path), ": ", conditionMessage(e),
              level = "WARN")
      NULL
    }
  )
  if (is.null(parsed)) return(empty_segments())

  segments <- parsed$segments
  if (is.null(segments) || length(segments) == 0) {
    log_msg("No segments in ", basename(path),
            " -- the recording may be silent or have failed", level = "WARN")
    return(empty_segments())
  }
  if (!is.data.frame(segments)) {
    segments <- tryCatch(
      as.data.frame(segments, stringsAsFactors = FALSE),
      error = function(e) NULL
    )
    if (is.null(segments)) {
      log_msg("Unexpected segment structure in ", basename(path), level = "WARN")
      return(empty_segments())
    }
  }

  required <- c("start", "end", "text")
  if (!all(required %in% names(segments))) {
    log_msg("Missing required field(s) ",
            paste(setdiff(required, names(segments)), collapse = ", "),
            " in ", basename(path), level = "WARN")
    return(empty_segments())
  }

  tibble::tibble(
    recording_id = file_stem(path),
    source_file  = basename(path),
    start        = as.numeric(segments$start),
    end          = as.numeric(segments$end),
    speaker      = if ("speaker" %in% names(segments)) {
      as.character(segments$speaker)
    } else {
      NA_character_
    },
    text         = as.character(segments$text)
  )
}

#' Merge consecutive segments spoken by the same person into one turn
#'
#' WhisperX emits short segments; for reading and for qualitative coding you
#' almost always want conversational turns instead.
#'
#' @param segments A tibble with the `empty_segments()` schema.
#' @param max_gap Do not merge across a silence longer than this many seconds.
#'   `Inf` (the default) merges every consecutive run by the same speaker.
merge_consecutive_turns <- function(segments, max_gap = Inf) {
  if (nrow(segments) == 0) return(segments)

  segments |>
    dplyr::arrange(recording_id, start, end) |>
    dplyr::group_by(recording_id) |>
    dplyr::mutate(
      gap      = start - dplyr::lag(end),
      new_turn = is.na(dplyr::lag(speaker)) |
                 speaker != dplyr::lag(speaker) |
                 (!is.na(gap) & gap > max_gap),
      turn_id  = cumsum(dplyr::coalesce(new_turn, TRUE))
    ) |>
    dplyr::group_by(recording_id, source_file, turn_id, speaker) |>
    dplyr::summarise(
      start = min(start),
      end   = max(end),
      text  = paste(text, collapse = " "),
      .groups = "drop"
    ) |>
    dplyr::select(recording_id, source_file, start, end, speaker, text)
}

#' Compile every WhisperX JSON file in a directory into one transcript
#'
#' @param json_dir Directory holding the `.json` files WhisperX produced.
#' @param merge_turns Merge consecutive same-speaker segments?
#' @param max_gap Passed to `merge_consecutive_turns()`.
#' @param unknown_speaker Label used where diarization assigned no speaker.
#' @param min_chars Drop turns shorter than this many characters.
#' @return A tidy tibble, one row per turn.
compile_transcripts <- function(json_dir,
                                merge_turns = TRUE,
                                max_gap = Inf,
                                unknown_speaker = "UNKNOWN",
                                min_chars = 1) {
  json_files <- list.files(json_dir, pattern = "\\.json$", full.names = TRUE)
  if (length(json_files) == 0) {
    stop("No .json files found in ", normalizePath(json_dir, mustWork = FALSE),
         call. = FALSE)
  }
  log_msg("Compiling ", length(json_files), " transcript file(s)")

  segments <- json_files |>
    purrr::map(read_whisperx_json) |>
    dplyr::bind_rows()

  if (nrow(segments) == 0) {
    stop("Every JSON file was empty or unreadable; nothing to compile.",
         call. = FALSE)
  }

  segments <- segments |>
    dplyr::mutate(
      text    = stringr::str_squish(text),
      speaker = dplyr::if_else(is.na(speaker) | !nzchar(speaker),
                               unknown_speaker, speaker)
    ) |>
    dplyr::filter(!is.na(text), nchar(text) >= min_chars)

  unknown_n <- sum(segments$speaker == unknown_speaker)
  if (unknown_n > 0) {
    log_msg(unknown_n, " of ", nrow(segments),
            " segments carry no speaker label", level = "WARN")
  }

  turns <- if (isTRUE(merge_turns)) {
    merge_consecutive_turns(segments, max_gap = max_gap)
  } else {
    segments
  }

  turns |>
    dplyr::arrange(recording_id, start) |>
    dplyr::group_by(recording_id) |>
    dplyr::mutate(turn = dplyr::row_number()) |>
    dplyr::ungroup() |>
    dplyr::mutate(
      text      = stringr::str_squish(text),
      start     = round(start, 3),
      end       = round(end, 3),
      duration  = round(end - start, 3),
      start_hms = seconds_to_hms(start),
      end_hms   = seconds_to_hms(end),
      n_words   = stringr::str_count(text, "\\S+")
    ) |>
    dplyr::select(recording_id, turn, speaker, start_hms, end_hms,
                  start, end, duration, n_words, text, source_file)
}

#' Replace diarization labels with your own names or pseudonyms
#'
#' Diarization labels are assigned per file, so SPEAKER_00 in one recording is
#' not the same person as SPEAKER_00 in another. The mapping is therefore keyed
#' on recording_id as well as speaker.
#'
#' @param transcript Output of `compile_transcripts()`.
#' @param map_file CSV with columns: recording_id, speaker, label.
apply_speaker_map <- function(transcript, map_file) {
  map <- readr::read_csv(map_file, show_col_types = FALSE,
                         progress = FALSE)
  required <- c("recording_id", "speaker", "label")
  if (!all(required %in% names(map))) {
    stop("Speaker map must contain the columns: ",
         paste(required, collapse = ", "), call. = FALSE)
  }
  log_msg("Applying speaker map from ", basename(map_file))

  transcript |>
    dplyr::left_join(
      dplyr::select(map, recording_id, speaker, label),
      by = c("recording_id", "speaker")
    ) |>
    dplyr::mutate(speaker = dplyr::coalesce(label, speaker)) |>
    dplyr::select(-label)
}

#' Write one plain-text transcript per recording
#'
#' Readable enough to check against the audio and to paste into NVivo, MAXQDA
#' or similar. Files are written as UTF-8.
write_readable_transcripts <- function(transcript, dir) {
  if (!dir.exists(dir)) dir.create(dir, recursive = TRUE)

  ids <- unique(transcript$recording_id)
  for (id in ids) {
    rows <- transcript[transcript$recording_id == id, , drop = FALSE]
    body <- sprintf("[%s - %s] %s\n%s\n",
                    rows$start_hms, rows$end_hms, rows$speaker, rows$text)
    lines <- c(
      paste0("# ", id),
      paste0("# ", nrow(rows), " turns | ",
             dplyr::n_distinct(rows$speaker), " speaker labels | generated ",
             format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
      "",
      body
    )
    con <- file(file.path(dir, paste0(id, ".txt")), open = "wt",
                encoding = "UTF-8")
    writeLines(lines, con)
    close(con)
  }
  invisible(ids)
}

#' One row per recording: turns, distinct speaker labels, words, length
#'
#' `turn_seconds` is the time spanned by turns, which includes any pause inside
#' a merged turn; it is not a measure of speaking time. `last_turn_hms` is where
#' the final turn ends, which may fall short of the end of the recording.
summarise_transcript <- function(transcript) {
  transcript |>
    dplyr::group_by(recording_id) |>
    dplyr::summarise(
      turns          = dplyr::n(),
      speaker_labels = dplyr::n_distinct(speaker),
      words          = sum(n_words, na.rm = TRUE),
      turn_seconds   = round(sum(duration, na.rm = TRUE), 1),
      last_turn_hms  = seconds_to_hms(max(end, na.rm = TRUE)),
      .groups = "drop"
    )
}
