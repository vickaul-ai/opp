source("opp.R")

# NOTE: some filters are by-month; for locations that gave us annual data 
#       (e.g., MO), these by-month filters don't quite apply in the same
#       way. We have done separate manual checks to ensure the quality of
#       these annual datasets where included. When applying this script to
#       new data, make sure to treat annualized data with care.

load <- function(analysis = "disparity", use_cache = F) {
  
  dir_create(here::here("cache"))
  cache_path <- here::here("cache", str_c(analysis, ".rds"))
  if (use_cache & file_exists(cache_path))
    return(read_rds(cache_path))

  tbl <- opp_available()

  if (analysis == "vod_dst") {
    load_func <- load_dst_vod_for
  } else if (analysis == "vod_full") {
    load_func <- load_full_vod_for
  } else if (analysis == "disparity") {
    load_func <- load_disparity_for
  } else if (analysis == "mj") {
    load_func <- load_mj_for
    tbl %<>% filter(city == "Statewide")
  } else if (analysis == "mjt") {
    load_func <- load_mj_threshold_for
    tbl %<>% filter(city == "Statewide", state %in% c("CO", "WA"))
  } else if (startsWith(analysis, "pfs")) {
    tbl <-
      locations_used_in_analyses(use_cache)$data %>%
      select(state, city) %>%
      distinct()
    # NOTE: analysis == "pfs_stop"
    load_func <- load_base_for
    if (analysis == "pfs_search") {
      load_func <- load_disparity_for
    }
  }

  tmp <- opp_apply(
    function(state, city) {
      p <- load_func(state, city)
      p@metadata %<>% 
        mutate(state = state, city = city) %>%
        select(state, city, everything())
      p
    },
    tbl
  )
  
  res <- list(
    data = bind_rows(lapply(tmp, function(p) p@data)),
    metadata = bind_rows(lapply(tmp, function(p) p@metadata))
  )

  write_rds(res, cache_path)

  res
}


locations_used_in_analyses <- function(use_cache = F) {

  cache_path <- here::here("cache", "locations_used_in_analyses.rds")
  if (use_cache && file_exists(cache_path))
    return(read_rds(cache_path))

  f <- function(a) {
    d <- load(a, use_cache)
    d$metadata %<>% mutate(analysis = a) %>% select(analysis, everything())
    d$data %<>% select(state, city) %>% distinct() %>% mutate(analysis = a)
    d
  }

  locations <- list(data = tibble(), metadata = tibble())
  for (analysis in c("vod_dst", "vod_full", "disparity", "mj", "mjt")) {
    a <- f(analysis)
    locations$data %<>% bind_rows(a$data)
    locations$metadata %<>% bind_rows(a$metadata)
  }

  write_rds(locations, cache_path)

  locations
}


load_dst_vod_for <- function(state, city) {
  load_vod_base_for(state, city) %>%
    remove_states_that_dont_observe_dst() %>% 
    add_dst_dates() %>%
    # NOTE: 30 day radius is what Ridgeway did in Cincy RAND paper
    filter_to_dst_windows(day_radius = 30) %>% 
    remove_location_yrs_with_too_few_stops_per_race(geography, min_stops = 100) %>% 
    select_top_n_vod_geos(geography, n_geos = 20)
}


load_full_vod_for <- function(state, city) {
  load_vod_base_for(state, city) %>%
    remove_partial_years(geography) %>% 
    remove_location_yrs_with_too_few_stops_per_race(geography, min_stops = 100) %>% 
    select_top_n_vod_geos(geography, n_geos = 20)
}


load_vod_base_for <- function(state, city) {
  load_base_for(state, city) %>%
    remove_months_with_low_coverage(time, threshold = 0.5) %>% 
    remove_na(time) %>% 
    filter_to_races(races = c("white", "black")) %>%
    add_geography_for_vod() %>% 
    remove_na(geography) %>% 
    add_center_lat_lng() %>%
    remove_na(center_lat, center_lng) %>% 
    add_sunset_times(center_lat, center_lng) %>% 
    filter_to_intertwilight_time_period() %>%
    remove_sunset_to_dusk_time_period()
}


load_disparity_for <- function(state, city) {
  load_base_for(state, city) %>%
    remove_locations_with_unreliable_search_data() %>%
    remove_months_with_low_coverage(search_conducted, threshold = 0.5) %>%
    filter_to_discretionary_searches_if_search_basis(threshold = 0.5) %>%
    remove_na(search_conducted) %>% 
    remove_locations_with_unreliable_contraband_data() %>%
    remove_months_with_low_coverage(
      contraband_found, predicate = search_conducted, threshold = 0.5
    ) %>%
    remove_months_with_low_coverage(subgeography, threshold = 0.5) %>%
    remove_na(subgeography) %>% 
    remove_locations_with_too_few_searches_per_race(
      subgeography, min_searches = 50
    ) %>% 
    remove_locations_with_too_few_subgeographies(min_subgeos = 3)
}


load_mj_for <- function(state, city) {
  load_base_for(state, city) %>%
    # NOTE: truncate after 2015 since only a couple locations have data
    filter_to_date_range("2011-01-01", "2015-12-31") %>%
    remove_locations_with_unreliable_search_data(time_series = T) %>%
    filter_to_locations_with_data_before_and_after_legalization() %>%
    remove_months_with_low_coverage(search_conducted, threshold = 0.5) %>%
    add_mj_calculated_features()
}


load_mj_threshold_for <- function(state, city) {
  load_mj_for(state, city) %>%
    # NOTE: truncate after 2015 since only a couple locations have data
    filter_to_date_range("2011-01-01", "2015-12-31") %>%
    remove_na(search_conducted) %>%
    remove_months_with_low_coverage(subgeography, threshold = 0.5) %>%
    remove_na(subgeography)
}


load_base_for <- function(state, city) {
  new("Pipeline") %>%
    init(
      opp_load_clean_data(state, city) %>%
      # NOTE: raw_* columns aren't used in the analyses so drop them
      select(-matches("raw_")) %>%
      mutate(state = str_to_upper(state), city = str_to_title(city))
    ) %>%
    keep_only_highway_patrol_if_state() %>%
    filter_to_vehicular_stops() %>%
    filter_to_date_range("2011-01-01", "2018-12-31") %>%
    remove_months_with_too_few_stops(min_stops = 50) %>%
    remove_months_with_low_coverage(
      subject_race, additional_na_vals = "unknown", threshold = 0.5
    ) %>%
    filter_to_races(races = c("white", "black", "hispanic")) %>%
    add_subgeography() %>%
    remove_anomalous_subgeographies()
}


keep_only_highway_patrol_if_state <- function(p) {

  action <- "keeping only highway parol data"
  reason <- "some states have multiple departments, i.e. dept of agriculture"
  result <- "no change"

  print(action)

  is_state <- p@data$city[[1]] == "Statewide"
  has_multiple_departments <- "department_name" %in% colnames(p@data)
  if (is_state & has_multiple_departments) {
    n_before <- nrow(p@data)
    p@data %<>%
      filter(
        case_when(
          state == "NC" ~ department_name == "NC State Highway Patrol",
          state == "IL" ~ department_name == "ILLINOIS STATE POLICE",
          state == "CT" ~ department_name == "State Police",
          state == "MD" ~ department_name %in% c("Maryland State Police", "MSP"),
          state == "MS" ~ department_name == "Mississippi Highway Patrol",
          state == "MO" ~ department_name == "Missouri State Highway Patrol",
          state == "NE" ~ department_name == "Nebraska State Agency",
          # NOTE: it's a state, but none of those above, so keep it all
          TRUE ~ TRUE
        )
      )
    n_after <- nrow(p@data)
    if (n_before - n_after > 0)
      result <- "rows removed"
  }

  add_decision(p, action, reason, result)
}


filter_to_vehicular_stops <- function(p) {

  action <- "filter to vehicular stops"
  reason <- "pedestrian stops are qualitatively different"
  result <- "no change"

  print(action)

  details <- list(type_proportion <- count_pct(p@data, type))
  n_before <- nrow(p@data)
  p@data %<>% filter(type == "vehicular")
  n_after <- nrow(p@data)
  if (n_before - n_after > 0)
    result <- "rows removed"

  add_decision(p, action, reason, result, details)
}


filter_to_date_range <- function(p, start_date, end_date) {

  action <- sprintf("filter to %s-%s", start_date, end_date)
  reason <- "target time period for analysis"
  result <- "no change"

  print(action)

  n_before <- nrow(p@data)
  p@data %<>% filter(date >= as.Date(start_date), date <= as.Date(end_date))
  n_after <- nrow(p@data)
  if (n_before - n_after > 0)
    result <- "rows removed"

  add_decision(p, action, reason, result)
}


remove_months_with_too_few_stops <- function(p, min_stops) {

  action <- sprintf("remove months with fewer than %g stops", min_stops)
  reason <- "data is too sparse to trust"
  result <- "no change"

  print(action)

  month_count = count(p@data, month = format(date, "%Y-%m"))
  bad_months <- filter(month_count, n < min_stops) %>% pull(month)
  details <- list(month_count = month_count, bad_months = bad_months)

  if (length(bad_months) > 0) {
    p@data %<>% filter(!(format(date, "%Y-%m") %in% bad_months))
    result <- sprintf("removed months %s", str_c(bad_months, collapse = ", "))
  }

  add_decision(p, action, reason, result, details)
}


remove_months_with_low_coverage <- function(
  p, feature, predicate = NULL, additional_na_vals = NULL, threshold
) {
  featq <- enquo(feature)
  feat_name <- quo_name(featq)
  reason <- sprintf("%s data is unreliable", feat_name)
  action <- sprintf(
    "remove months where %s is recorded less than %g%% of the time",
    feat_name,
    threshold * 100
  )
  result <- "no change"
  print(action)
  
  if(!missing(predicate)) {
    predq <- enquo(predicate)
    pred_name <- quo_name(predq)
    if (!(pred_name %in% colnames(p@data))) {
      p@data %<>% slice(0)
      result <- sprintf("eliminated because predicate %s data is not recorded", pred_name)
      return(add_decision(p, action, reason, result))
    }
  }

  if (!(feat_name %in% colnames(p@data))) {
    p@data %<>% slice(0)
    result <- sprintf("eliminated because %s data is not recorded", feat_name)
    return(add_decision(p, action, reason, result))
  }
  base <- p@data
  
  if(!missing(predicate)) {
    base <- filter(base, !!predq)
  }
  
  if(not_null(additional_na_vals)) {
    base <- base %>% 
      mutate(!!feat_name := str_replace_all(
        !!featq, str_c(additional_na_vals, collapse = "|"), NA_character_
      ))
  }

  cvg <-
    base %>%
    group_by(month = format(date, "%Y-%m")) %>%
    summarize(coverage = coverage_rate(!!featq)) %>%
    ungroup()
  details <- list(coverage = cvg)

  bad_months <- filter(cvg, coverage < threshold) %>% pull(month)
  if (length(bad_months) > 0) {
    p@data %<>% filter(!(format(date, "%Y-%m") %in% bad_months))
    result <- sprintf("removed months %s", str_c(bad_months, collapse = ", "))
  }

  add_decision(p, action, reason, result, details)
}


remove_na <- function(p, ...) {

  featqs <- enquos(...)
  feat_names <- quos_names(featqs)

  feat_names_str <- str_c(feat_names, collapse = ", ")
  action <- sprintf("remove rows where %s is NA", feat_names_str)
  reason <- sprintf("each of %s is required for analysis", feat_names_str)
  result <- "no change"

  print(action)

  for (feat_name in feat_names) {
    if (!(feat_name) %in% colnames(p@data)) {
      p@data %<>% slice(0)
      result <- sprintf("eliminated because %s not recorded", feat_name)
      return(add_decision(p, action, reason, result))
    }
  }

  n_before <- nrow(p@data)
  for (featq in featqs)
    p@data %<>% filter(!is.na(!!featq))
  n_after <- nrow(p@data)
  if (n_before - n_after > 0)
    result <- "rows removed"

  add_decision(p, action, reason, result)
}


filter_to_races <- function(p, races) {

  action <- sprintf("filter to races %s", str_c(races, collapse = ", "))
  reason <- "analysis uses only these"
  result <- "no change"

  print(action)

  if (!("subject_race" %in% colnames(p@data))) {
    result <- "eliminated because race is not recorded"
    p@data %<>% slice(0)
    return(add_decision(p, action, reason, result))
  }

  details <- list(subject_race_proportion <- count_pct(p@data, subject_race))

  n_before <- nrow(p@data)
  p@data %<>% filter(subject_race %in% races) %>%
    mutate(subject_race = factor(subject_race, levels = races))
  n_after <- nrow(p@data)
  if (n_before - n_after > 0)
    result <- "rows removed"

  add_decision(p, action, reason, result, details)
}


add_subgeography <- function(p) {

  action <- "add subgeography"
  reason <- "necessary for some analyses"
  result <- "no change"

  print(action)

  if (nrow(p@data) == 0)
    return(add_decision(p, action, reason, result))

  subgeography_colnames <-
    if (p@data$city[[1]] == "Statewide") {
      quos_names(state_subgeographies)
    } else {
      quos_names(city_subgeographies)
    }

  subgeographies <- select_or_add_as_na(p@data, subgeography_colnames)
  # TODO(danj/amyshoe): add condition to select subgeography with reasonable numbers
  subgeography <- subgeographies %>% select_if(funs(which.min(sum(is.na(.)))))
  subgeography_selected <- colnames(subgeography)[[1]]
  colnames(subgeography) <- "subgeography"
  p@data %<>% bind_cols(subgeography)

  summary <-
    left_join(
      null_rates(subgeographies),
      n_distinct_values(subgeographies),
      by = "feature"
    ) %>%
    mutate(selected = feature == subgeography_selected)

  selected <- filter(summary, selected)

  result <- sprintf(
    "selected subgeography %s (%s null, %g distinct values)",
    subgeography_selected,
    selected$`null rate`,
    selected$`n distinct values`
  )
  details <- list(summary = summary)

  add_decision(p, action, reason, result, details)
}


remove_anomalous_subgeographies <- function(p) {

  # TODO(danj/amyshoe): look for other anomalous subgeos
  action <- "remove anomalous subgeographies"
  reason <- "these regions are either qualitatively different or undefined"
  result <- "no change"

  print(action)

  if (nrow(p@data) == 0)
    return(add_decision(p, action, reason, result))

  details <- list(subgeography_proportion <- count_pct(p@data, subgeography))

  city <- p@data$city[[1]]
  n_before <- nrow(p@data)

  if (city == "Arlington") {

    p@data %<>% filter(!(subgeography %in% c("N", "E", "S", "W")))
    result <- str_c(
      "filtered out districts that aren't 'N', 'E', 'S', and 'W', ",
      "since they appear to be data entry errors"
    )

  } else if (city == "Louisville") {

    p@data %<>% filter(!str_detect(subgeography, "DIVISON"))
    result <- str_c(
      "filtered out division 'DIVISION' since it appears to be ",
      "a data entry error"
    )

  } else if (city == "Nashville") {

    p@data %<>% filter(subgeography != "U")
    result <- "filtered out precinct 'U' (Unknown)"

  } else if (city == "Philadelphia") {

    p@data %<>% filter(subgeography != "77")
    result <- str_c(
      "filtered out district 77 because it's the airport and HQ and ",
      "has qualitatively different stops"
    )

  } else if (city == "Plano") {

    p@data %<>% filter(subgeography != "999")
    result <- str_c(
      "filtered out sector '9999' since it appears to be ",
      "a data entry error"
    )

  } else if (city == "San Diego") {

    p@data %<>% filter(subgeography != "Unknown")
    result <- "filtered out service_area 'Unknown'"
  }

  n_after <- nrow(p@data)
  if (n_before - n_after > 0)
    result <- "rows removed"

  add_decision(p, action, reason, result)
}


filter_to_searches <- function(p) {

  action <- "filter to searches"
  reason <- "searches are the risk population"
  result <- "no change"

  print(action)

  if (!("search_conducted") %in% colnames(tbl)) {
    result <- "eliminated because search data not recorded"
    p@data %<>% slice(0)
    return(add_decision(p, action, reason, result))
  }

  n_before <- nrow(p@data)
  p@data %<>% filter(search_conducted)
  n_after <- nrow(p@data)
  if (n_before - n_after > 0)
    result <- "rows removed"

  add_decision(p, action, reason, result, details)
}



filter_to_discretionary_searches_if_search_basis <- function(p, threshold) {

  action <- str_c(
    "keep only plain view, consent, probable cause, k9 and NA searches ",
    "(assume NA is discretionary) where search_basis is reliable; ",
    "excludes arrest/warrant, probation/parole, inventory searches"
  )
  reason <- "the officer decides to make these searches and is not obligated"
  result <- "no change"

  print(action)

  if (!("search_basis") %in% colnames(tbl)) {
    result <- str_c(
      "search basis not recorded; ",
      "assuming all searches are discretionary"
    )
    return(add_decision(p, action, reason, result))
  }
  
  searches <- p@data %>% filter(search_conducted)
  
  cvg_rate <- coverage_rate(searches$search_basis)
  details <- list(coverage = cvg_rate)

  # TODO(danj/amyshoe): this is really what we want to do?
  if (cvg_rate < threshold) {
    result <- sprintf(
      str_c(
        "search basis coverage rate %g%% < %g%% (threshold), ",
        "making it unreliable; assuming all searches are discretionary"
      ),
      cvg_rate * 100,
      threshold * 100
    )
    return(add_decision(p, action, reason, result))
  }

  n_before <- nrow(p@data)
  p@data %<>% filter(
    !search_conducted |
      (search_conducted & is.na(search_basis)) |
      (search_conducted & search_basis %in% c("plain view", "consent", 
                                              "probable cause", "k9"))
  )
  n_after <- nrow(p@data)
  if (n_before - n_after > 0)
    result <- "rows removed"

  add_decision(p, action, reason, result, details)
}


remove_locations_with_unreliable_search_data <- function(p, time_series = F) {

  action <- "remove locations with unreliable search data"
  reason <- "has an unreiable and/or irregular recording policy"
  result <- "no change"

  print(action)

  if (nrow(p@data) == 0)
    return(add_decision(p, action, reason, result))

  city <- p@data$city[[1]]
  state <- p@data$state[[1]]

  if (city == "Statewide" & state %in% c("VA")) {
    p@data %<>% slice(0)
    result <- case_when(
      state == "VA"
        ~ str_c(
          "eliminated because it has weekly search recording with suspicious ",
          "spikes, i.e. an officer conducts 800-1500 searches in one week"
        ),
      TRUE ~ "no change"
    )
  }

  if (city %in% c("Arlington", "Pittsburgh")) {
    p@data %<>% slice(0)
    result <- case_when(
        city == "Arlington"
          ~ str_c(
            "eliminated because we lack the data dictionary for",
            "`6th digit (Search Outcome)` in the raw data"
          ),
        city == "Pittsburgh"
          ~ str_c(
            "eliminated because inferred search rate is very high; ",
            "see data readme for how search_conducted is inferred"
          ),
        TRUE ~ "no change"
    )
  }

  if (time_series & city == "Statewide" & state %in% c("IL", "MD", "MO", "NE")){
    p@data %<>% slice(0)
    result <- case_when(
      state == "IL"
      ~ "eliminated because search recording policy changes year to year",
      state == "MD"
      ~ "eliminated because before 2013 we are only given annual data",
      state == "MO"
      ~ "eliminated because it's all annual data",
      state == "NE"
      ~ str_c(
        "eliminated because it has unreliable quarterly dates, ",
        "i.e. in 2012 all patrol stops are in Q1"
      ),
      TRUE ~ "no change"
    )
  }
  
  add_decision(p, action, reason, result)
}

remove_locations_with_unreliable_contraband_data <- function(p) {
  
  action <- "remove locations with unreliable contraband data"
  reason <- "has an unreliable and/or irregular recording policy"
  result <- "no change"
  
  print(action)
  
  if (nrow(p@data) == 0)
    return(add_decision(p, action, reason, result))
  
  city <- p@data$city[[1]]
  state <- p@data$state[[1]]
  
  if (city == "Statewide" & 
      state %in% c("AZ", "MA")
  ) {
    p@data %<>% slice(0)
    result <- case_when(
      state == "AZ"
      ~ str_c("eliminated because recording is messy and there are too many ",
              "contradicting ways to define contraband"),
      state == "MA"
      ~ "eliminated because recording is messy and unreliable",
      TRUE ~ "no change"
    )
  }
  
  add_decision(p, action, reason, result)
}

remove_locations_with_too_few_searches_per_race <- function(p, geo, min_searches) {
  geo_colq <- enquo(geo)
  
  action <- sprintf("remove locations with fewer than %d searches per race", 
                    min_searches)
  reason <- "need sufficient data for threshold test model"
  result <- "no change"
  
  print(action)
  
  if (nrow(p@data) == 0) {
    result <- sprintf("dataframe empty")
    return(add_decision(p, action, reason, result))
  }
  
  race_names <-
    p@data %>% 
    select(subject_race) %>% 
    distinct() %>% 
    mutate(subject_race = as.character(subject_race)) %>% 
    pull(subject_race)

  locations_with_no_searches <-
    p@data %>%
    group_by(!!geo_colq, subject_race) %>%
    filter(sum(search_conducted) == 0) %>%
    pull(!!geo_colq)
  
  locations_with_too_few_searches_per_location_race <-
    p@data %>% 
    filter(search_conducted) %>% 
    count(!!geo_colq, subject_race) %>% 
    spread(subject_race, n, fill = 0) %>%
    filter_at(
      vars(race_names),
      any_vars(. < min_searches)
    ) %>%
    pull(!!geo_colq)

  locations_to_remove <- c(
    locations_with_no_searches,
    locations_with_too_few_searches_per_location_race
  )

  n_before <- nrow(p@data)
  p@data %<>% filter(!(!!geo_colq %in% locations_to_remove))
  n_after <- nrow(p@data)
  
  details = list(eliminated = locations_to_remove)

  if (n_before - n_after > 0)
    result <- "rows removed"
  add_decision(p, action, reason, result, details)
}

remove_locations_with_too_few_subgeographies <- function(p, min_subgeos) {
  action <- sprintf("remove locations with fewer than %d subgeographies", 
                    min_subgeos)
  reason <- str_c("need sufficient subgeos for threshold test and ",
            "representative data for rolling up to geography")
  result <- "no change"
  
  print(action)
  
  if (nrow(p@data) == 0) {
    result <- sprintf("dataframe empty")
    return(add_decision(p, action, reason, result))
  }
  
  n_subgeos <- p@data %>% 
    select(subgeography) %>% 
    n_distinct()
  details = list(n_subgeographies = n_subgeos)
  
  if (n_subgeos < min_subgeos) {
    p@data %<>% slice(0) 
    result <- "location eliminated"
  }
  add_decision(p, action, reason, result, details)
}

filter_to_locations_with_data_before_and_after_legalization <- function(p) {

  action <- "filter to locations with data before and after 2012"
  reason <- "need data pre/post marijuana legalization"
  result <- "no change"

  print(action)

  if (nrow(p@data) == 0)
    return(add_decision(p, action, reason, result))

  date_range <- range(p@data$date, na.rm = TRUE)
  start_year <- year(date_range[1])
  end_year <- year(date_range[2])
  details <- list(date_range = date_range)
  if (start_year > 2012 | end_year < 2012) {
    p@data %<>% slice(0)
    result <- "eliminated: there isn't data before and after legalization"
    return(add_decision(p, action, reason, result, details))
  } 

  add_decision(p, action, reason, result, details)
}


add_mj_calculated_features <- function(p) {

  action <- "add legalization, treatment, search, and misdemeanor features"
  reason <- "these are required for the analysis"
  result <- "added the features"

  print(action)

  if (nrow(p@data) == 0)
    return(add_decision(p, action, reason, "no change"))

  if (!("subject_race" %in% colnames(p@data))) {
    result <- "eliminated because race is not recorded"
    p@data %<>% slice(0)
    return(add_decision(p, action, reason, result))
  }

  if (!("violation") %in% colnames(p@data))
    p@data %<>% mutate(violation = NA)

  if (!("search_basis") %in% colnames(p@data))
    p@data %<>% mutate(search_basis = NA)

  p@data %<>% 
    mutate(
      legalization_date = if_else(
        state == "CO",
        as.Date("2012-12-10"),
        # NOTE: default for control and WA is WA's legalization date
        as.Date("2012-12-09")
      ),
      is_before_legalization = date < legalization_date,
      is_treatment_state = state %in% c("WA", "CO"),
      is_treatment = is_treatment_state & !is_before_legalization,
      violation = str_to_lower(violation),
      # NOTE: search_basis = NA is interpreted as a discretionary search;
      # excludes other (non-discretionary)
      is_discretionary_search =
        search_conducted
        & (
          is.na(search_basis)
          | search_basis %in% c("k9", "plain view", "probable cause", "consent")
        ),
      is_drug_infraction_or_misdemeanor = str_detect(
        violation,
        str_c(
          # NOTE: Details on Colorado's marijuana policies:
          # https://www.colorado.gov/pacific/marijuana/driving-and-traveling
          # CO violations
          "possession of 1 oz or less of marijuana",
          # NOTE: these spike after legalization
          # "open marijuana container",

          # WA violations
          "drugs - misdemeanor",
          "drugs paraphernalia - misdemeanor",
          sep = "|"
        )
      )
    )

  add_decision(p, action, reason, result)
}


add_geography_for_vod <- function(p) {

  action <- "use county_name for states and city for cities as geography"
  reason <- "necessary for joint state-city vod models"
  result <- "no change"
  
  print(action)
  
  if (nrow(p@data) == 0)
    return(add_decision(p, action, reason, result))
  
  city <- p@data$city[[1]]
  geography_colname <- if_else(city == "Statewide", "county_name", "city")

  if (!(geography_colname %in% colnames(p@data))) {
    p@data %<>% slice(0)
    result <- sprintf("eliminated because %s not present", geography_colname)
    return(add_decision(p, action, reason, result))
  }
  
  p@data %<>%
    mutate(geography = str_c(UQ(sym(geography_colname)), state, sep = ", "))

  result <- sprintf(
    "selected geography %s (%g%% null, %g distinct values)",
    geography_colname,
    null_rate(p@data$geography) * 100,
    length(unique(p@data$geography))
  )
  
  add_decision(p, action, reason, result)
}


add_center_lat_lng <- function(p) {

  action <- "add center_lat and center_lng"
  reason <- "necessary for computing sunset times"
  result <- "no change"
  
  print(action)
  
  if (nrow(p@data) == 0)
    return(add_decision(p, action, reason, result))
  
  city <- p@data$city[[1]]
  state <- p@data$state[[1]]

  p@data %<>%
    left_join(
      if (city != "Statewide") {
        city_center_lat_lngs() %>%
          mutate(geography = str_c(city, state, sep = ", ")) %>%
          select(-city, -state)
      } else {
        geoCounty %>% 
        filter(state == state) %>%
        select(
          state,
          county,
          center_lat = lat,
          center_lng = lon
        ) %>% 
        mutate(
          # NOTE: match how states were processed, i.e. McHenry, ND is Mchenry, ND
          county = str_to_title(county),
          # NOTE: match how states were processed, i.e. "St. Johns" is "St Johns"
          county = str_replace_all(county, "\\.", "")
        ) %>% 
        unite(
          geography,
          c("county", "state"),
          sep = ", "
        )
      },
      by = "geography"
    )
  
  # NOTE: null rate for center_lat and center_lng will be identical
  result <- sprintf("added lat/lng (%s null)", null_rate(p@data$center_lat))
  
  add_decision(p, action, reason, result)
}


add_sunset_times <- function(
  p,
  lat_col,
  lng_col
) {

  lat_colq <- enquo(lat_col)
  lng_colq <- enquo(lng_col)

  action <- "add sunset times"
  reason <- "necessary for vod analysis"
  result <- "no change"
  
  print(action)
  
  if (nrow(p@data) == 0)
    return(add_decision(p, action, reason, result))

  p@data %<>% add_times(date, !!lat_colq, !!lng_colq, c("sunset", "dusk"))

  result <- sprintf(
    "added sunset times (%g%% NA)",
    null_rate(p@data$sunset) * 100
  )
  
  add_decision(p, action, reason, result)
}


filter_to_intertwilight_time_period <- function(p) {

  action <- "filter to the intertwilight time period"
  reason <- "necessary for the vod analysis"
  result <- "no change"
  
  print(action)
  
  if (nrow(p@data) == 0)
    return(add_decision(p, action, reason, result))
  
  n_before <- nrow(p@data)
  p@data %<>%
    mutate(
      minute = time_to_minute(time),
      sunset_minute = time_to_minute(sunset),
      dusk_minute = time_to_minute(dusk),
      min_dusk_minute = min(dusk_minute),
      max_dusk_minute = max(dusk_minute)
    ) %>%
    filter(
      # NOTE: filter to get only the intertwilight period
      minute >= min_dusk_minute,
      minute <= max_dusk_minute
    )
  n_after <- nrow(p@data)

  if (n_before - n_after > 0)
    result <- "rows removed"
  
  add_decision(p, action, reason, result)
}


remove_sunset_to_dusk_time_period <- function(p) {

  action <- "remove the time between when the sun sets and it is dark (dusk)"
  reason <- "necessary for the vod analysis"
  result <- "no change"
  
  print(action)
  
  if (nrow(p@data) == 0)
    return(add_decision(p, action, reason, result))
  
  n_before <- nrow(p@data)
  p@data %<>% filter(!(minute >= sunset_minute & minute <= dusk_minute)) 
  n_after <- nrow(p@data)

  if (n_before - n_after > 0)
    result <- "rows removed"
  
  add_decision(p, action, reason, result)
}


remove_partial_years <- function(
  p,
  feature, 
  days_per_yr_threshold = 100,
  max_start_day = "01-15",
  min_end_day = "12-15"
) {

  featq <- enquo(feature)
  feat_name <- quo_name(featq)
  
  action <- sprintf("remove %s-years with partial data", feat_name)
  reason <- "need full-year comparison in vod"
  result <- "no change"
  
  print(action)
  
  if (!(feat_name) %in% colnames(p@data)) {
    p@data %<>% slice(0)
    result <- sprintf("eliminated because %s not present", feat_name)
    return(add_decision(p, action, reason, result))
  }
  
  days_represented_by_feat <-
    p@data %>% 
    count(!!featq, date) %>% 
    mutate(yr = year(date)) %>% 
    group_by(!!featq, yr) %>% 
    summarize(n_days_represented = n())
  # NOTE: removing feature with not enough of a full year will also
  # knock out aggregate data, which is intended.
  remove_yr_if_missing_days <- days_represented_by_feat %>% 
    filter(n_days_represented < days_per_yr_threshold)
  
  n_before <- nrow(p@data)
  p@data %<>% 
    mutate(yr = year(date)) %>% 
    inner_join(
      days_represented_by_feat %>% 
        filter(n_days_represented >= days_per_yr_threshold),
        select(-n_days_represented),
      by = c("geography", "yr")
    )
  n_after_days_per_yr_filter <- nrow(p@data)
  
  months_represented_by_feat <-
    p@data %>% 
    mutate(month = as.yearmon(date)) %>% 
    count(!!featq, yr, month) %>% 
    group_by(!!featq, yr) %>% 
    summarize(n_months_represented = n())
  remove_yr_if_missing_months <- months_represented_by_feat %>% 
    filter(n_months_represented < 12)
  
  p@data %<>% 
    inner_join(
      months_represented_by_feat %>% 
        filter(n_months_represented == 12),
      select(-n_months_represented),
      by = c("geography", "yr")
    )
  n_after_months_per_yr_filter <- nrow(p@data)
  
  date_ranges_represented_by_feat <-
    p@data %>% 
    group_by(!!featq, yr) %>% 
    summarize(min_date = min(date), max_date = max(date))
  remove_yr_if_not_complete <- date_ranges_represented_by_feat %>% 
    filter(
      format(min_date,"%m-%d") > max_start_day |
      format(max_date,"%m-%d") < min_end_day
    )
  
  p@data %<>% 
    inner_join(
      date_ranges_represented_by_feat %>% 
        filter(
          format(min_date,"%m-%d") <= max_start_day |
          format(max_date,"%m-%d") >= min_end_day 
        ),
      select(-date_range),
      by = c("geography", "yr")
    )
  n_after_date_range_filter <- nrow(p@data)
  
  details <- list(
    incomplete_feat_years_by_day = remove_yr_if_missing_days,
    prop_removed_by_day = (n_before - n_after_days_per_yr_filter) / n_before,
    incomplete_feat_years_by_month = remove_yr_if_missing_months, 
    prop_removed_by_month =
      (n_after_days_per_yr_filter - n_after_months_per_yr_filter) / 
          n_after_days_per_yr_filter,
    incomplete_feat_yrs_by_range = remove_yr_if_not_complete,
    prop_removed_by_range = 
      (n_after_days_per_yr_filter - n_after_date_range_filter) / 
        n_after_days_per_yr_filter
  )
  
  if (n_before - n_after_date_range_filter > 0)
    result <- "rows removed"
  add_decision(p, action, reason, result, details)
  
}

remove_location_yrs_with_too_few_stops_per_race <- function(p, geo, min_stops) {
  geo_colq <- enquo(geo)
  
  action <- sprintf("remove location-years with fewer than %d stops per race", 
                    min_stops)
  reason <- "need sufficient data for vod model"
  result <- "no change"
  
  print(action)
  
  if (nrow(p@data) == 0) {
    result <- sprintf("dataframe empty")
    return(add_decision(p, action, reason, result))
  }
  
  race_names <- p@data %>% 
    select(subject_race) %>% 
    distinct() %>% 
    mutate(subject_race = as.character(subject_race)) %>% 
    pull(subject_race)
  
  location_yrs_removed <- p@data %>% 
    mutate(yr = year(date)) %>% 
    count(!!geo_colq, yr, subject_race) %>% 
    spread(subject_race, n, fill = 0) %>%
    filter_at(
      vars(race_names),
      all_vars(. < min_stops)
    )
  details = list(eliminated = location_yrs_removed)
  
  n_before <- nrow(p@data)
  p@data %<>%
    inner_join(
      p@data %>% 
        mutate(yr = year(date)) %>% 
        count(!!geo_colq, yr, subject_race) %>% 
        spread(subject_race, n, fill = 0) %>% 
        filter_at(
          vars(race_names), 
          all_vars(. >= min_stops)
        ) %>% 
        select(!!geo_colq, yr)
    )
  n_after <- nrow(p@data)
  
  if (n_before - n_after > 0)
    result <- "rows removed"
  add_decision(p, action, reason, result, details)
}


select_top_n_vod_geos <- function(p, geo, n_geos) {

  geo_colq <- enquo(geo)
  
  reason <- "VOD model can't handle too many locations"
  result <- "no change"
  
  if (nrow(p@data) == 0) {
    action <- sprintf("select top %d geos", n_geos)
    print(action)
    result <- sprintf("dataframe empty")
    return(add_decision(p, action, reason, result))
  }
  
  if (str_to_lower(p@data$city[[1]]) == "statewide") {
    action <- sprintf("choose top %d counties for states", n_geos)
  } else {
    action <- sprintf("select top %d geos", n_geos)
    result <- "single city; action not relevant"
    print(action)
    return(add_decision(p, action, reason, result))
  }
  
  print(action)
  
  ranked_geos <- p@data %>%
    count_pct(state, !!geo_colq) 
  details = list(ranked_geos = ranked_geos)
  
  n_before <- nrow(p@data)
  p@data %<>%
    inner_join(
      p@data %>%
        count(state, !!geo_colq) %>%
        group_by(state) %>% 
        top_n(n_geos, n) %>% 
        select(!!geo_colq)
    )
  n_after <- nrow(p@data)
  
  if (n_before - n_after > 0)
    result <- "geographies removed"
  add_decision(p, action, reason, result, details)
}
  
remove_states_that_dont_observe_dst <- function(p) {
  action <- "remove locations from states that don't observe DST"
  reason <- "DST model makes no sense in these cases"
  result <- "no change"
  
  print(action)
  
  if (nrow(p@data) == 0)
    return(add_decision(p, action, reason, result))
  
  state <- p@data$state[[1]]
  
  if (state %in% c("AZ", "HI")) {
    result <- sprintf("removed %s", state)
    p@data <- tibble()
    return(add_decision(p, action, reason, result))
  }
  
  add_decision(p, action, reason, result)
}

add_dst_dates <- function(p) {
  action <- "add DST dates"
  reason <- "necessary for DST model"
  result <- "no change"
  
  print(action)
  
  if (nrow(p@data) == 0)
    return(add_decision(p, action, reason, result))
  
  p@data %<>%
    mutate(year = year(date)) %>% 
    left_join(
      # NOTE: this only goes from 2011-2018; if you're using this analysis for
      # later or earlier years, make sure to add those dates, or compute
      # generaically (2nd Sunday in March; 1st Sunday in Nov)
      read_rds(here::here("resources", "dst_start_end_dates.rds")), 
      by = "year"
    )
  
  dst_null_rates <- null_rate(select(p@data, dst_start, dst_end))
  details = list(null_rates = dst_null_rates)
  result <- "added dst dates"
  
  add_decision(p, action, reason, result, details)
}


filter_to_dst_windows <- function(p, day_radius) {
  action <- sprintf("Filter to %d-day radius around each DST shift", day_radius)
  reason <- "necessary for DST model"
  result <- "no change"
  
  print(action)
  
  if (nrow(p@data) == 0)
    return(add_decision(p, action, reason, result))
  
  n_before <- nrow(p@data)
  p@data %<>% 
    mutate(
      # define spring as the day_radius around start of DST
      spring = date >= dst_start - days(day_radius)
        & date <= dst_start + days(day_radius),
      # define fall as the day_radius around end of DST
      fall = date >= dst_end - days(day_radius) 
        & date <= dst_end + days(day_radius)
    ) %>% 
    filter(spring | fall) %>% 
    mutate(season = if_else(spring, "spring", "fall"))
  n_after <- nrow(p@data)
  
  if (n_before - n_after > 0)
    result <- "rows removed"

  # TODO(amyshoe): add details with counts per year/season
  add_decision(p, action, reason, result)
}
