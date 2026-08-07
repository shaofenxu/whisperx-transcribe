# =============================================================================
# utils.R -- Small helpers shared by the transcription and compilation steps.
#
# All functions are namespace-qualified, so this file can be sourced without
# attaching any packages. Sourcing has no side effects.
# =============================================================================


# ---- Null-coalescing --------------------------------------------------------

`%||%` <- function(x, y) if (is.null(x)) y else x


# ---- Logging ----------------------------------------------------------------

#' Start a run log
#'
#' Creates `dir` if needed and registers a timestamped log file in
#' `options(wx.log_file)`. Every subsequent `log_msg()` call is tee'd to it.
#'
#' @param dir Directory in which to write the log file.
#' @return The path of the log file, invisibly usable as a character scalar.
start_log <- function(dir) {
  if (!dir.exists(dir)) dir.create(dir, recursive = TRUE)
  path <- file.path(dir, format(Sys.time(), "run_%Y%m%d_%H%M%S.log"))
  options(wx.log_file = path)
  path
}

#' Print a timestamped message to the console and to the run log
#'
#' @param ... Parts of the message; pasted together without a separator.
#' @param level One of "INFO", "WARN", "ERROR".
log_msg <- function(..., level = c("INFO", "WARN", "ERROR")) {
  level <- match.arg(level)
  line <- sprintf(
    "%s [%-5s] %s",
    format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    level,
    paste0(..., collapse = "")
  )
  cat(line, "\n", sep = "")
  utils::flush.console()

  log_file <- getOption("wx.log_file")
  if (!is.null(log_file)) {
    cat(line, "\n", sep = "", file = log_file, append = TRUE)
  }
  invisible(line)
}


# ---- Formatting -------------------------------------------------------------

#' Convert seconds to HH:MM:SS
#'
#' Vectorised; NA and non-finite values return NA.
seconds_to_hms <- function(seconds) {
  s <- as.numeric(seconds)
  out <- rep(NA_character_, length(s))
  ok <- !is.na(s) & is.finite(s) & s >= 0
  if (any(ok)) {
    whole <- floor(s[ok])
    out[ok] <- sprintf(
      "%02d:%02d:%02d",
      as.integer(whole %/% 3600),
      as.integer((whole %% 3600) %/% 60),
      as.integer(whole %% 60)
    )
  }
  out
}

#' File name without directory or extension
file_stem <- function(path) tools::file_path_sans_ext(basename(path))

#' Quote a path for the platform's shell
shell_quote <- function(x) {
  shQuote(x, type = if (.Platform$OS.type == "windows") "cmd" else "sh")
}

#' Replace a secret with a placeholder before printing or logging
redact <- function(x, secret) {
  if (is.null(secret) || !nzchar(secret)) return(x)
  gsub(secret, "<HF_TOKEN>", x, fixed = TRUE)
}


# ---- Preconditions ----------------------------------------------------------

#' Stop early with an actionable message if R dependencies are missing
require_packages <- function(pkgs = c("dplyr", "purrr", "readr",
                                      "stringr", "tibble", "jsonlite")) {
  missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing) > 0) {
    stop(
      "Missing R packages: ", paste(missing, collapse = ", "), "\n",
      "Install them with:\n  install.packages(c(",
      paste0('"', missing, '"', collapse = ", "), "))",
      call. = FALSE
    )
  }
  if (utils::packageVersion("dplyr") < "1.0.0") {
    stop("dplyr >= 1.0.0 is required. Installed: ",
         as.character(utils::packageVersion("dplyr")), call. = FALSE)
  }
  if (getRversion() < "4.1.0") {
    stop("R >= 4.1.0 is required (the scripts use the native |> pipe). ",
         "Running: ", as.character(getRversion()), call. = FALSE)
  }
  invisible(TRUE)
}

#' Discover audio files in a directory
#'
#' @param dir Directory to search.
#' @param pattern Regular expression matched case-insensitively against names.
#' @param recursive Search sub-directories?
#' @return A sorted character vector of full paths.
find_audio <- function(dir,
                       pattern = "\\.(mp3|wav|m4a|mp4|flac|ogg|opus|aac|wma)$",
                       recursive = TRUE) {
  if (!dir.exists(dir)) {
    stop("Audio directory does not exist: ", normalizePath(dir, mustWork = FALSE),
         call. = FALSE)
  }
  sort(list.files(dir, pattern = pattern, full.names = TRUE,
                  recursive = recursive, ignore.case = TRUE))
}

#' Refuse to proceed if two inputs would produce the same output file
#'
#' WhisperX names its output after the audio file's stem, so two inputs called
#' `interview.mp3` in different folders would silently overwrite each other.
assert_unique_stems <- function(files) {
  stems <- file_stem(files)
  dupes <- unique(stems[duplicated(stems)])
  if (length(dupes) > 0) {
    stop(
      "Input files share a base name, so their transcripts would overwrite ",
      "one another:\n  ", paste(dupes, collapse = "\n  "),
      "\nRename the files (or flatten them into one folder with unique names) ",
      "and run again.",
      call. = FALSE
    )
  }
  invisible(TRUE)
}
