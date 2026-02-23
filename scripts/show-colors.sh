#!/usr/bin/env sh
set -eu

# Display xterm-256 colors and the current jmon memory palette in the terminal.
# This helps choose ANSI 256-color codes for bar colors.

reset_style() {
  printf '\033[0m'
}

fg() {
  printf '\033[38;5;%sm' "$1"
}

bg() {
  printf '\033[48;5;%sm' "$1"
}

bold() {
  printf '\033[1m'
}

dim() {
  printf '\033[2m'
}

print_swatch_fg() {
  code="$1"
  label="$2"
  fg "$code"
  printf '■■■■'
  reset_style
  printf ' %-10s (xterm %3s)\n' "$label" "$code"
}

print_jmon_palette() {
  bold; printf 'jmon memory palette (current)\n'; reset_style
  print_swatch_fg 20  "phys"
  print_swatch_fg 51  "used"
  print_swatch_fg 195 "mark"
  print_swatch_fg 231 "comm"
  print_swatch_fg 250 "empty"
  printf '\n'
}

print_run() {
  code="$1"
  count="$2"
  [ "$count" -le 0 ] && return 0
  fg "$code"
  i=0
  while [ "$i" -lt "$count" ]; do
    printf '■'
    i=$((i + 1))
  done
  reset_style
}

print_memory_bar_preview() {
  phys="$1"
  used="$2"
  mark="$3"
  comm="$4"
  empty="$5"

  # Simulated jmon memory bar layering:
  # used (blue), watermark trail, committed headroom, empty to Xmx, then physical extension beyond Xmx.
  # Fixed shape makes palette comparison easier across candidates.
  used_cells=22
  mark_trail_cells=7
  comm_cells=6
  empty_cells=9
  phys_ext_cells=8

  print_run "$used" "$used_cells"
  print_run "$mark" "$mark_trail_cells"
  print_run "$comm" "$comm_cells"
  print_run "$empty" "$empty_cells"
  print_run "$phys" "$phys_ext_cells"
}

print_memory_palette_candidate() {
  idx="$1"
  phys="$2"
  used="$3"
  mark="$4"
  comm="$5"
  empty="$6"

  printf '%2s) ' "$idx"
  print_memory_bar_preview "$phys" "$used" "$mark" "$comm" "$empty"
  printf '  phys=%-3s used=%-3s mark=%-3s comm=%-3s empty=%-3s\n' "$phys" "$used" "$mark" "$comm" "$empty"
}

print_memory_palette_candidates() {
  bold; printf '10 candidate memory palettes (simulated jmon bar)\n'; reset_style
  dim; printf 'Bar layout preview: used | mark trail | committed headroom | empty-to-Xmx | physical extension\n'; reset_style
  dim; printf 'All candidates keep empty=250 for readability; only blue family shades vary.\n\n'; reset_style

  # idx  phys used mark comm empty
  print_memory_palette_candidate "1" 27  45  153 195 250
  print_memory_palette_candidate "2" 25  45  117 195 250
  print_memory_palette_candidate "3" 24  39  117 195 250
  print_memory_palette_candidate "4" 33  45  159 195 250
  print_memory_palette_candidate "5" 27  51  123 195 250
  print_memory_palette_candidate "6" 26  44  117 189 250
  print_memory_palette_candidate "7" 18  45  111 189 250
  print_memory_palette_candidate "8" 31  50  153 231 250
  print_memory_palette_candidate "9" 19  43  117 153 250
  print_memory_palette_candidate "10" 20 51  159 231 250
  printf '\n'
}

print_named_hints() {
  bold; printf 'Quick ranges worth testing (blue/cyan)\n'; reset_style
  dim; printf 'Try: 27-39 (blue), 44-51 (cyan), 111-123 (light blue), 153-159, 189-195\n'; reset_style
  printf '\n'
}

print_fg_table() {
  bold; printf 'xterm-256 foreground swatches\n'; reset_style
  dim; printf 'Each entry shows a colored sample plus its code. Use values with \\x1b[38;5;N m in Zig.\n\n'; reset_style

  i=0
  while [ "$i" -le 255 ]; do
    fg "$i"
    printf '■■'
    reset_style
    printf '%3d  ' "$i"
    i=$((i + 1))
    if [ $((i % 8)) -eq 0 ]; then
      printf '\n'
    fi
  done
  if [ $((i % 8)) -ne 0 ]; then
    printf '\n'
  fi
  printf '\n'
}

print_bg_grid() {
  bold; printf 'xterm-256 background grid (labels choose black/white for contrast)\n'; reset_style
  dim; printf 'Useful for comparing neighboring shades quickly.\n\n'; reset_style

  i=0
  while [ "$i" -le 255 ]; do
    bg "$i"
    case "$i" in
      # Light colors: dark text label
      7|10|11|12|13|14|15|145|146|147|148|149|150|151|152|153|154|155|156|157|158|159|186|187|188|189|190|191|192|193|194|195|223|224|225|229|230|231|250|251|252|253|254|255)
        printf '\033[30m'
        ;;
      *)
        printf '\033[97m'
        ;;
    esac
    printf ' %3d ' "$i"
    reset_style
    printf ' '
    i=$((i + 1))
    if [ $((i % 6)) -eq 0 ]; then
      printf '\n'
    fi
  done
  if [ $((i % 6)) -ne 0 ]; then
    printf '\n'
  fi
  printf '\n'
}

print_usage_hint() {
  bold; printf 'Usage in jmon (Zig)\n'; reset_style
  printf '  const my_color = "\\x1b[38;5;45m";\n'
  printf '  // 45 is the xterm color code selected above\n'
}

print_jmon_palette
print_memory_palette_candidates
print_named_hints
print_fg_table
print_bg_grid
print_usage_hint
reset_style
