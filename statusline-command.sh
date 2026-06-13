#!/usr/bin/env bash
# Claude Code statusLine command — compact with icons
# Reads JSON from stdin, outputs a single status line

input=$(cat)

# --- Parse all fields with a single jq call ---
eval "$(echo "$input" | jq -r '
  @sh "cwd=\(.workspace.current_dir // .cwd // "")",
  @sh "project_dir=\(.workspace.project_dir // .cwd // ".")",
  @sh "model=\(.model.display_name // "")",
  @sh "remaining=\(.context_window.remaining_percentage // "")",
  @sh "total_in=\(.context_window.total_input_tokens // 0)",
  @sh "total_out=\(.context_window.total_output_tokens // 0)",
  @sh "duration_ms=\(.cost.total_duration_ms // 0)",
  @sh "five_hour_used=\(.rate_limits.five_hour.used_percentage // "")",
  @sh "five_hour_reset=\(.rate_limits.five_hour.resets_at // "")",
  @sh "seven_day_used=\(.rate_limits.seven_day.used_percentage // "")"
' 2>/dev/null)"

# --- Directory (Starship substitution) ---
home="$HOME"
cwd="${cwd/#$home/\~}"
cwd="${cwd/#\~\/WebstormProjects\//}"
IFS='/' read -ra parts <<< "$cwd"
count=${#parts[@]}
if [ "$count" -gt 3 ]; then
    cwd="${parts[$((count-3))]}/${parts[$((count-2))]}/${parts[$((count-1))]}"
fi

# --- Git branch + dirty ---
branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$project_dir" symbolic-ref --short HEAD 2>/dev/null || \
         GIT_OPTIONAL_LOCKS=0 git -C "$project_dir" rev-parse --short HEAD 2>/dev/null)
if [ -n "$branch" ]; then
    dirty=$(GIT_OPTIONAL_LOCKS=0 git -C "$project_dir" status --porcelain 2>/dev/null)
    staged=$(echo "$dirty" | grep -c '^[MARCDT]' 2>/dev/null || true)
    modified=$(echo "$dirty" | grep -c '^.[MARCDT?]' 2>/dev/null || true)
fi

# --- Format tokens (19734 → 19.7k) ---
total_tok=$((total_in + total_out))
if [ "$total_tok" -ge 1000000 ]; then
    tok_str="$(awk "BEGIN{printf \"%.1f\", $total_tok/1000000}")M"
elif [ "$total_tok" -ge 1000 ]; then
    tok_str="$(awk "BEGIN{printf \"%.1f\", $total_tok/1000}")k"
else
    tok_str="${total_tok}"
fi

# --- Format duration ---
duration_s=$((duration_ms / 1000))
dur_h=$((duration_s / 3600))
dur_m=$(( (duration_s % 3600) / 60 ))
if [ "$dur_h" -gt 0 ]; then
    dur_str="${dur_h}h${dur_m}m"
else
    dur_str="${dur_m}m"
fi

# --- Colors ---
cyan='\033[0;36m'
purple='\033[0;35m'
blue='\033[0;34m'
yellow='\033[0;33m'
green='\033[0;32m'
red='\033[0;31m'
dim='\033[2m'
rst='\033[0m'

# === Assemble output ===

# Directory (cyan)
printf "${cyan} %s${rst}" "$cwd"

# Git branch + dirty (purple + yellow)
if [ -n "$branch" ]; then
    printf "  ${purple} %s${rst}" "$branch"
    if [ "$staged" -gt 0 ] 2>/dev/null; then
        printf " ${green}+%d${rst}" "$staged"
    fi
    if [ "$modified" -gt 0 ] 2>/dev/null; then
        printf " ${yellow}~%d${rst}" "$modified"
    fi
fi

# Model (blue)
if [ -n "$model" ]; then
    printf "  ${blue} %s${rst}" "$model"
fi

# Duration (before context)
printf "  ${dim}󱑂 ${dur_str}${rst}"

# Context remaining + session tokens (yellow)
if [ -n "$remaining" ]; then
    remaining_int=$(printf '%.0f' "$remaining")
    printf "  ${yellow}󰄰 %d%%${rst}" "$remaining_int"
    if [ "$total_tok" -gt 0 ]; then
        printf " ${dim}· %s${rst}" "$tok_str"
    fi
fi

# Rate limit — 5h (green)
if [ -n "$five_hour_used" ]; then
    used_int=$(printf '%.0f' "$five_hour_used")
    rem_pct=$((100 - used_int))
    printf "  ${green}󱐋 5h - %d%%" "$rem_pct"
    if [ -n "$five_hour_reset" ]; then
        now=$(date +%s)
        diff_s=$((five_hour_reset - now))
        if [ "$diff_s" -gt 0 ]; then
            diff_h=$((diff_s / 3600))
            diff_m=$(( (diff_s % 3600) / 60 ))
            if [ "$diff_h" -gt 0 ]; then
                printf " ${dim}(%dh%dm)${green}" "$diff_h" "$diff_m"
            else
                printf " ${dim}(%dm)${green}" "$diff_m"
            fi
        fi
    fi
    printf "${rst}"
fi

# Rate limit — 7d (green)
if [ -n "$seven_day_used" ]; then
    used7_int=$(printf '%.0f' "$seven_day_used")
    rem7_pct=$((100 - used7_int))
    printf "  ${green}󰃭 7d - %d%%${rst}" "$rem7_pct"
fi

printf '\n'
