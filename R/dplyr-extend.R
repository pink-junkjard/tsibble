#' Tidyverse methods for tsibble
#'
#' * `arrange()`: if not arranging key and index in past-to-future order, a warning is
#' likely to be issued.
#' * `slice()`: if row numbers are not in ascending order, a warning is likely to
#' be issued.
#' * `select()`: keeps the variables you mention as well as the index and key.
#' * `transmute()`: keeps the variable you operate on, as well as the index and key.
#' * `summarise()` reduces a sequence of values over time instead of a single summary,
#' as well as dropping empty keys/groups.
#'
#' @param .data,data A `tbl_ts`.
#' @param ... Same arguments accepted as its tidyverse generic.
#' @inheritParams dplyr::filter
#' @details
#' Column-wise verbs, including `select()`, `transmute()`, `summarise()`,
#' `mutate()` & `transmute()`, keep the time context hanging around. That is,
#' the index variable cannot be dropped for a tsibble. If any key variable
#' is changed, it will validate whether it's a tsibble internally. Use `as_tibble()`
#' to leave off the time context.
#'
#' @name tsibble-tidyverse
NULL

#' @export
arrange.tbl_ts <- function(.data, ...) {
  arr_data <- arrange(as_tibble(.data), ...)
  update_meta(arr_data, .data, ordered = FALSE, interval = interval(.data))
}

#' @export
arrange.grouped_ts <- arrange.tbl_ts

#' @export
select.tbl_ts <- function(.data, ...) {
  loc <- eval_select(expr(c(...)), .data)
  data_cp <- .data
  names(data_cp)[loc] <- names(loc)
  bind_tsibble(NextMethod(), data_cp, position = "after")
}

#' @export
select.grouped_ts <- select.tbl_ts

#' @rdname tsibble-tidyverse
#' @export
transmute.tbl_ts <- function(.data, ...) {
  bind_tsibble(NextMethod(), .data, position = "before")
}

#' @export
transmute.grouped_ts <- transmute.tbl_ts

#' @rdname tsibble-tidyverse
#' @examples
#' library(dplyr, warn.conflicts = FALSE)
#' # Sum over sensors
#' pedestrian %>%
#'   index_by() %>%
#'   summarise(Total = sum(Count))
#' # shortcut
#' pedestrian %>%
#'   summarise(Total = sum(Count))
#' # Back to tibble
#' pedestrian %>%
#'   as_tibble() %>%
#'   summarise(Total = sum(Count))
#' @export
summarise.tbl_ts <- function(.data, ...) {
  # Unlike summarise.grouped_df(), summarise.tbl_ts() doesn't compute values for
  # empty groups. Bc information is unavailable over the time range for empty
  # groups.
  idx <- index(.data)
  idx2 <- index2(.data)

  # workaround for scoped variants
  lst_quos <- enquos(..., .named = TRUE)
  idx_chr <- as_string(idx)
  idx2_chr <- as_string(idx2)
  nonkey <- setdiff(names(lst_quos), c(key_vars(.data), idx_chr, idx2_chr))
  nonkey_quos <- lst_quos[nonkey]

  grped_data <- as_tibble(index_by(.data, !!idx2))
  sum_data <-
    group_by(
      summarise(grped_data, !!!nonkey_quos),
      !!!head(groups(grped_data), -2) # remove index2 and last grp
    )
  if (identical(idx, idx2)) int <- is_regular(.data) else int <- TRUE
  grps <- setdiff(group_vars(.data), idx2_chr)

  build_tsibble(
    sum_data,
    key = !!grps, index = !!idx2, ordered = TRUE, interval = int,
    validate = FALSE
  )
}

#' @export
summarise.grouped_ts <- summarise.tbl_ts

#' @importFrom dplyr group_by_drop_default
#' @export
group_by.tbl_ts <- function(.data, ..., .add = FALSE,
                            .drop = group_by_drop_default(.data)) {
  lst_quos <- enquos(..., .named = TRUE)
  grp_vars <- names(lst_quos)
  if (.add) grp_vars <- union(group_vars(.data), grp_vars)
  if (is_empty(grp_vars)) return(.data)

  index <- index_var(.data)
  if (index %in% grp_vars) {
    err <- sprintf("Column `%s` (index) can't be a grouping variable for a tsibble.", index)
    hint <- "Did you mean `index_by()`?"
    abort(paste_inline(err, hint))
  }

  grp_key <- identical(grp_vars, key_vars(.data)) &&
    identical(.drop, key_drop_default(.data))
  if (grp_key) {
    grped_tbl <- new_grouped_df(.data, groups = key_data(.data))
  } else {
    grped_tbl <- NextMethod()
  }
  build_tsibble(
    grped_tbl,
    key = !!key_vars(.data),
    key_data = if (grp_key) key_data(.data) else NULL,
    index = !!index(.data), index2 = !!index2(.data),
    ordered = is_ordered(.data), interval = interval(.data), validate = FALSE
  )
}

#' Group by key variables
#'
#' @description
#' \lifecycle{stable}
#'
#' @param .data A `tbl_ts` object.
#' @param ... Ignored.
#' @inheritParams dplyr::group_by
#' @export
#' @examples
#' tourism %>%
#'   group_by_key()
group_by_key <- function(.data, ..., .drop = key_drop_default(.data)) {
  group_by(.data, !!!key(.data), .drop = .drop)
}

#' @export
ungroup.grouped_ts <- function(x, ...) {
  tbl <- ungroup(as_tibble(x))
  build_tsibble(
    tbl,
    key_data = key_data(x), index = !!index(x),
    ordered = is_ordered(x), interval = interval(x), validate = FALSE
  )
}

#' @export
ungroup.tbl_ts <- function(x, ...) {
  attr(x, "index2") <- index_var(x)
  x
}

distinct.tbl_ts <- function(.data, ...) {
  dplyr::distinct(as_tibble(.data), ...)
}

#' @export
dplyr_row_slice.tbl_ts <- function(data, i, ..., preserve = FALSE) {
  loc_df <- summarise(as_tibble(data), !!".loc" := list2(i))
  ascending <- all(map_lgl(loc_df[[".loc"]], validate_order))
  res <- NextMethod()
  if (preserve) {
    update_meta2(res, data, ordered = ascending, interval = interval(data))
  } else {
    update_meta(res, data, ordered = ascending, interval = interval(data))
  }
}

#' @export
dplyr_row_slice.grouped_ts <- dplyr_row_slice.tbl_ts

#' @export
dplyr_col_modify.tbl_ts <- function(data, cols) {
  res <- NextMethod()
  idx_chr <- index_var(data)
  if (is_false(idx_chr %in% names(res))) { # index has been removed
    abort(sprintf(paste_inline(
      "Column `%s` (index) can't be removed for a tsibble.",
      "Do you need `as_tibble()` to work with data frame?"
    ), idx_chr))
  }

  vec_names <- names(cols)
  # either key or index is present in `cols`
  # suggests that the operations are done on these variables
  # validate = TRUE to check if tsibble still holds
  val_idx <- has_index(vec_names, data)
  if (val_idx) interval <- TRUE else interval <- interval(data)

  val_key <- has_any_key(vec_names, data)
  if (val_key) {
    key_vars <- setdiff(names(res), measured_vars(data))
    data <- remove_key(data, key_vars)
  }

  validate <- val_idx || val_key
  if (validate) {
    res <- retain_tsibble(res, key_vars(data), index(data))
  }
  build_tsibble(
    res,
    key = !!key_vars(data),
    key_data = if (val_key) NULL else key_data(data), index = !!index(data),
    index2 = !!index2(data), ordered = is_ordered(data), interval = interval,
    validate = FALSE, .drop = is_key_dropped(data)
  )
}

#' @export
dplyr_col_modify.grouped_ts <- dplyr_col_modify.tbl_ts

#' @export
dplyr_reconstruct.tbl_ts <- function(data, template) {
  update_meta(data, template,
    ordered = NULL, interval = is_regular(template),
    validate = TRUE)
}

#' @export
dplyr_reconstruct.grouped_ts <- dplyr_reconstruct.tbl_ts
