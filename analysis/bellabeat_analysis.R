############################################################
# Bellabeat smart device analysis
# Google Data Analytics Certificate capstone case study
#
# Question: how do people use non-Bellabeat smart devices, and
# what does that suggest for Bellabeat's marketing?
#
# Data: "Crowd-sourced Fitbit datasets 03.12.2016-05.12.2016"
# (Furberg, Brinton, Keating, Ortiz; Zenodo record 53894; CC BY 4.0),
# export covering April 12 - May 12, 2016.
# https://zenodo.org/records/53894
#
# Run from the repository root:  Rscript analysis/bellabeat_analysis.R
# Writes tables to outputs/ and charts to outputs/charts/.
############################################################

suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
})

data_dir  <- "data"
out_dir   <- "outputs"
chart_dir <- file.path(out_dir, "charts")
dir.create(data_dir,  showWarnings = FALSE)
dir.create(chart_dir, showWarnings = FALSE, recursive = TRUE)

# ---- 1. Get the data ---------------------------------------------------------
zip_name <- "mturkfitbit_export_4.12.16-5.12.16.zip"
zip_path <- file.path(data_dir, zip_name)
if (!file.exists(zip_path)) {
  download.file(paste0("https://zenodo.org/records/53894/files/", zip_name, "?download=1"),
                zip_path, mode = "wb")
}
read_fitbit <- function(file) {
  read.csv(unz(zip_path, paste0("Fitabase Data 4.12.16-5.12.16/", file)),
           stringsAsFactors = FALSE)
}

daily  <- read_fitbit("dailyActivity_merged.csv")
sleep  <- read_fitbit("sleepDay_merged.csv")
weight <- read_fitbit("weightLogInfo_merged.csv")
hourly <- read_fitbit("hourlySteps_merged.csv")

# ---- 2. Clean ----------------------------------------------------------------
weekday_levels <- c("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")

daily <- daily %>%
  mutate(
    date         = as.Date(ActivityDate, format = "%m/%d/%Y"),
    day_of_week  = factor(weekdays(date), levels = weekday_levels),
    weekend      = day_of_week %in% c("Saturday", "Sunday"),
    wear_minutes = VeryActiveMinutes + FairlyActiveMinutes + LightlyActiveMinutes + SedentaryMinutes,
    # A day with zero steps is treated as a day the device was not worn
    worn         = TotalSteps > 0
  ) %>%
  distinct(Id, date, .keep_all = TRUE)

# 12 May 2016 is the export cut-off day and is only partly recorded
last_full_day <- max(daily$date) - 1

sleep <- sleep %>%
  mutate(date = as.Date(SleepDay, format = "%m/%d/%Y %I:%M:%S %p")) %>%
  distinct(Id, date, .keep_all = TRUE)

hourly <- hourly %>%
  mutate(
    time        = as.POSIXct(ActivityHour, format = "%m/%d/%Y %I:%M:%S %p", tz = "UTC"),
    hour        = as.integer(format(time, "%H")),
    day_of_week = factor(weekdays(as.Date(time)), levels = weekday_levels),
    weekend     = day_of_week %in% c("Saturday", "Sunday")
  )

# ---- 3. Which features do people use? ---------------------------------------
n_users <- n_distinct(daily$Id)
feature_use <- tibble::tibble(
  feature = c("Activity and steps", "Sleep tracking", "Weight logging",
              "Weight logging (any manual entry)"),
  users   = c(n_distinct(daily$Id[daily$worn]),
              n_distinct(sleep$Id),
              n_distinct(weight$Id),
              n_distinct(weight$Id[weight$IsManualReport == "True"]))
) %>%
  mutate(share_of_users = users / n_users)

weight_entries <- weight %>%
  count(Id, name = "entries") %>%
  arrange(desc(entries))

# ---- 4. How consistently is the device worn? --------------------------------
per_user <- daily %>%
  filter(date <= last_full_day) %>%
  group_by(Id) %>%
  summarise(
    days_recorded       = n(),
    days_worn           = sum(worn),
    full_day_wear_share = mean(wear_minutes >= 1440 & worn),
    mean_steps_worn     = mean(TotalSteps[worn]),
    .groups = "drop"
  ) %>%
  mutate(
    logs_sleep  = Id %in% sleep$Id,
    logs_weight = Id %in% weight$Id,
    activity_level = cut(mean_steps_worn,
                         breaks = c(-Inf, 5000, 7500, 10000, Inf),
                         labels = c("Under 5,000", "5,000-7,499", "7,500-9,999", "10,000+"),
                         right = FALSE)
  )

engagement_by_day <- daily %>%
  filter(date <= last_full_day) %>%
  group_by(date) %>%
  summarise(users_wearing = sum(worn), .groups = "drop")

wear_summary <- tibble::tibble(
  metric = c("Users", "Days in period (full days)", "Mean days worn per user",
             "Users who wore it every day", "Share of worn days that were full 24-hour wear",
             "Users wearing on day 1", "Users wearing on last full day"),
  value  = c(n_users,
             as.numeric(last_full_day - min(daily$date)) + 1,
             round(mean(per_user$days_worn), 1),
             sum(per_user$days_worn == max(per_user$days_recorded)),
             round(sum(daily$wear_minutes >= 1440 & daily$worn & daily$date <= last_full_day) /
                   sum(daily$worn & daily$date <= last_full_day), 3),
             engagement_by_day$users_wearing[1],
             tail(engagement_by_day$users_wearing, 1))
)

# ---- 5. How active are they? -------------------------------------------------
worn_days <- daily %>% filter(worn)

activity_summary <- tibble::tibble(
  metric = c("Mean daily steps (worn days)", "Median daily steps (worn days)",
             "Share of worn days with 10,000+ steps", "Share of worn days with 7,500+ steps",
             "Mean sedentary hours per worn day", "Mean very + fairly active minutes per worn day",
             "Correlation: daily steps vs calories (all days)"),
  value  = c(round(mean(worn_days$TotalSteps)),
             round(median(worn_days$TotalSteps)),
             round(mean(worn_days$TotalSteps >= 10000), 3),
             round(mean(worn_days$TotalSteps >= 7500), 3),
             round(mean(worn_days$SedentaryMinutes) / 60, 1),
             round(mean(worn_days$VeryActiveMinutes + worn_days$FairlyActiveMinutes), 1),
             round(cor(daily$TotalSteps, daily$Calories), 2))
)

steps_by_weekday <- worn_days %>%
  group_by(day_of_week) %>%
  summarise(mean_steps = mean(TotalSteps), days = n(), .groups = "drop")

weekend_vs_weekday <- worn_days %>%
  group_by(weekend) %>%
  summarise(mean_steps = mean(TotalSteps), days = n(), .groups = "drop")

steps_by_hour <- hourly %>%
  group_by(weekend, hour) %>%
  summarise(mean_steps = mean(StepTotal), .groups = "drop")

activity_levels <- per_user %>% count(activity_level, name = "users")

# ---- 6. Sleep ----------------------------------------------------------------
sleep_summary <- tibble::tibble(
  metric = c("Users with sleep records", "Nights recorded",
             "Mean hours asleep per night", "Share of nights under 7 hours asleep",
             "Mean minutes in bed but awake"),
  value  = c(n_distinct(sleep$Id), nrow(sleep),
             round(mean(sleep$TotalMinutesAsleep) / 60, 2),
             round(mean(sleep$TotalMinutesAsleep < 420), 3),
             round(mean(sleep$TotalTimeInBed - sleep$TotalMinutesAsleep), 1))
)

write.csv(feature_use,        file.path(out_dir, "feature_use.csv"), row.names = FALSE)
write.csv(weight_entries,     file.path(out_dir, "weight_entries_by_user.csv"), row.names = FALSE)
write.csv(per_user,           file.path(out_dir, "per_user_summary.csv"), row.names = FALSE)
write.csv(engagement_by_day,  file.path(out_dir, "users_wearing_by_day.csv"), row.names = FALSE)
write.csv(wear_summary,       file.path(out_dir, "wear_summary.csv"), row.names = FALSE)
write.csv(activity_summary,   file.path(out_dir, "activity_summary.csv"), row.names = FALSE)
write.csv(steps_by_weekday,   file.path(out_dir, "steps_by_weekday.csv"), row.names = FALSE)
write.csv(weekend_vs_weekday, file.path(out_dir, "steps_weekend_vs_weekday.csv"), row.names = FALSE)
write.csv(steps_by_hour,      file.path(out_dir, "steps_by_hour.csv"), row.names = FALSE)
write.csv(activity_levels,    file.path(out_dir, "users_by_activity_level.csv"), row.names = FALSE)
write.csv(sleep_summary,      file.path(out_dir, "sleep_summary.csv"), row.names = FALSE)

# ---- 7. Charts ---------------------------------------------------------------
blue <- "#2a78d6"; orange <- "#eb6834"
theme_bb <- theme_minimal(base_size = 12) +
  theme(panel.grid.minor = element_blank(),
        panel.grid.major.x = element_blank(),
        panel.grid.major.y = element_line(color = "#e6e6e3", linewidth = 0.3),
        legend.position = "top", legend.title = element_blank(),
        plot.title = element_text(face = "bold"),
        plot.subtitle = element_text(color = "#52514e"),
        plot.caption = element_text(color = "#52514e", size = 8, hjust = 0))
caption <- "Source: Fitbit data from 33 users, April 12 - May 12, 2016 (Furberg et al., Zenodo 53894)."
save_chart <- function(p, name, w = 8, h = 4.5) {
  ggsave(file.path(chart_dir, name), p, width = w, height = h, dpi = 150, bg = "white")
}

p1 <- ggplot(feature_use %>% filter(feature != "Weight logging (any manual entry)"),
             aes(reorder(feature, users), users)) +
  geom_col(fill = blue, width = 0.6) +
  geom_text(aes(label = paste0(users, " of ", n_users)), hjust = -0.15, size = 3.6) +
  coord_flip() +
  scale_y_continuous(limits = c(0, n_users * 1.15), breaks = seq(0, 30, 10)) +
  labs(title = "Everyone tracked steps; few logged weight",
       subtitle = "Users who recorded each feature at least once", x = NULL, y = "Users", caption = caption) +
  theme_bb + theme(panel.grid.major.y = element_blank(),
                   panel.grid.major.x = element_line(color = "#e6e6e3", linewidth = 0.3))
save_chart(p1, "feature_use.png", h = 3.6)

p2 <- ggplot(engagement_by_day, aes(date, users_wearing)) +
  geom_line(color = blue, linewidth = 0.9) +
  geom_point(color = blue, size = 1.6) +
  scale_y_continuous(limits = c(0, n_users), breaks = seq(0, 30, 10)) +
  labs(title = "Fewer users wore the device as the month went on",
       subtitle = "Users with any steps recorded, by day", x = NULL, y = "Users", caption = caption) +
  theme_bb
save_chart(p2, "users_wearing_by_day.png")

p3 <- ggplot(steps_by_hour %>% mutate(weekend = ifelse(weekend, "Weekend", "Weekday")),
             aes(hour, mean_steps, color = weekend)) +
  geom_line(linewidth = 0.9) +
  geom_point(size = 1.6) +
  scale_color_manual(values = c(Weekday = blue, Weekend = orange)) +
  scale_x_continuous(breaks = seq(0, 23, 3), labels = function(h) sprintf("%02d:00", h)) +
  labs(title = "Weekday steps peak at midday and early evening",
       subtitle = "Average steps per hour", x = "Hour of day", y = "Steps", caption = caption) +
  theme_bb
save_chart(p3, "steps_by_hour.png")

p4 <- ggplot(activity_levels, aes(activity_level, users)) +
  geom_col(fill = blue, width = 0.6) +
  geom_text(aes(label = users), vjust = -0.5, size = 3.6) +
  scale_y_continuous(limits = c(0, max(activity_levels$users) * 1.2), breaks = function(l) seq(0, floor(l[2]), by = 2)) +
  labs(title = "Most users average under 10,000 steps a day",
       subtitle = "Users by average daily steps on days worn", x = "Average daily steps", y = "Users",
       caption = caption) +
  theme_bb
save_chart(p4, "users_by_activity_level.png")

# ---- 8. Console summary ------------------------------------------------------
print(feature_use); print(wear_summary); print(activity_summary)
print(weekend_vs_weekday); print(steps_by_weekday); print(activity_levels); print(sleep_summary)
