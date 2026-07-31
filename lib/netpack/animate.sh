# animate.sh — menu splash animation. Frames are composed as strings and
# redrawn in place; no dependency beyond printf and read -t. Sourced by
# bin/netpack after its palette is set. Any keypress or Ctrl-C skips it;
# NETPACK_NO_SPLASH=1 disables it.
# shellcheck shell=bash

# 42 columns matches the banner the menu draws afterwards.
SPLASH_W=42
SPLASH_H=12

# Starfield "row col" pairs: fixed, so they stay clear of the rocket.
SPLASH_STARS=(
  "0 4" "0 27" "1 14" "2 7" "2 38" "3 25" "4 2" "4 33"
  "5 10" "6 29" "6 5" "7 36" "8 13" "9 31" "10 3" "10 26"
)

SPLASH_PLANET="-O-"
SPLASH_PLANET_ROW=1
SPLASH_PLANET_COL=31

SPLASH_ROCKET=(
  '  /\  '
  ' |  | '
  ' |np| '
  ' |  | '
  "/|__|\\"
)
SPLASH_ROCKET_COL=18

# Exhaust below the nozzle, alternating per frame for flicker.
SPLASH_EXHAUST_A=(' vVVv ' "  ''  ")
SPLASH_EXHAUST_B=(' VvvV ' '  ..  ')

# Satellite flyby: drawn dim and before the rocket, so it passes behind.
SPLASH_SAT='=[o]='
SPLASH_SAT_ROW=3

# splice VAR COL TEXT — overwrite TEXT into VAR at COL, preserving width.
splice() {
  local -n __row=$1
  local col=$2 text=$3
  __row="${__row:0:col}${text}${__row:$((col + ${#text}))}"
}

# splice_clip VAR X TEXT — splice, clipping TEXT at both canvas edges so a
# sprite can enter and leave the frame. X may be negative.
splice_clip() {
  local x=$2 text=$3
  if (( x < 0 )); then
    text="${text:$(( -x ))}"
    x=0
  fi
  if (( x + ${#text} > SPLASH_W )); then
    text="${text:0:$(( SPLASH_W - x ))}"
  fi
  if [[ -n "$text" ]]; then
    splice "$1" "$x" "$text"
  fi
}

# splash_play [satellite] — run the launch once. The satellite joins about
# one launch in three, or always when forced (the preview command does).
# shellcheck disable=SC2120
splash_play() {
  [[ -t 1 ]] || return 0
  local sat=0
  if [[ "${1:-}" == satellite ]] || (( RANDOM % 3 == 0 )); then
    sat=1
  fi
  local sprite_h=${#SPLASH_ROCKET[@]}
  # Pad sits two rows up so the exhaust is on screen during ignition.
  local pad_top=$(( SPLASH_H - sprite_h - 2 ))
  local hold=4                                          # ignition frames
  local total=$(( hold + pad_top + sprite_h + 2 ))      # exhaust clears top
  local blank ch frame=0 skip=0 r rt i
  local -a canvas segs exhaust
  printf -v blank '%*s' "$SPLASH_W" ''

  # Ctrl-C skips the splash rather than killing the launcher; keep whatever
  # INT trap a caller may have installed.
  local prev_int
  prev_int="$(trap -p INT)"
  trap 'skip=1' INT
  printf '\033[?25l'

  while (( frame < total && ! skip )); do
    # Background: twinkling stars, then the planet.
    canvas=()
    segs=()
    for (( r = 0; r < SPLASH_H; r++ )); do
      canvas[r]=$blank
    done
    for i in "${!SPLASH_STARS[@]}"; do
      read -r r ch <<<"${SPLASH_STARS[$i]}"
      case $(( (frame / 3 + i) % 4 )) in
        0) splice "canvas[$r]" "$ch" '.' ;;
        1) splice "canvas[$r]" "$ch" '+' ;;
        2) splice "canvas[$r]" "$ch" '*' ;;
        3) splice "canvas[$r]" "$ch" '.' ;;
      esac
    done
    splice "canvas[$SPLASH_PLANET_ROW]" "$SPLASH_PLANET_COL" "$SPLASH_PLANET"
    if (( sat )); then
      # Right to left, two columns per frame.
      splice_clip "canvas[$SPLASH_SAT_ROW]" $(( SPLASH_W - 1 - 2 * frame )) "$SPLASH_SAT"
    fi

    # Rocket: held on the pad during ignition, then one row up per frame.
    rt=$pad_top
    (( frame > hold )) && rt=$(( pad_top - (frame - hold) ))
    for i in "${!SPLASH_ROCKET[@]}"; do
      r=$(( rt + i ))
      if (( r >= 0 && r < SPLASH_H )); then
        splice "canvas[$r]" "$SPLASH_ROCKET_COL" "${SPLASH_ROCKET[$i]}"
        segs[r]="$SPLASH_ROCKET_COL ${#SPLASH_ROCKET[$i]}"
      fi
    done
    exhaust=("${SPLASH_EXHAUST_A[@]}")
    (( frame % 2 )) && exhaust=("${SPLASH_EXHAUST_B[@]}")
    for i in "${!exhaust[@]}"; do
      r=$(( rt + sprite_h + i ))
      if (( r >= 0 && r < SPLASH_H )); then
        splice "canvas[$r]" "$SPLASH_ROCKET_COL" "${exhaust[$i]}"
        segs[r]="$SPLASH_ROCKET_COL ${#exhaust[$i]}"
      fi
    done

    # Emit: dim background, bold amber rocket, then rewind for the next frame.
    for (( r = 0; r < SPLASH_H; r++ )); do
      if [[ -n "${segs[r]:-}" ]]; then
        read -r i ch <<<"${segs[r]}"
        printf '%s%s%s%s%s%s%s\033[K\n' \
          "$C_DIM" "${canvas[r]:0:i}" \
          "${C_OFF}${C_BOLD}${C_AMBER}" "${canvas[r]:i:ch}" "$C_OFF" \
          "${C_DIM}${canvas[r]:$((i + ch))}" "$C_OFF"
      else
        printf '%s%s%s\033[K\n' "$C_DIM" "${canvas[r]}" "$C_OFF"
      fi
    done
    printf '\033[%dA' "$SPLASH_H"

    # The frame clock doubles as the skip key: any keypress ends the splash.
    if read -rs -n1 -t 0.07; then
      skip=1
    fi
    (( frame++ )) || true
  done

  # Clear the canvas so the menu draws on a clean screen, restore the cursor.
  printf '\033[J\033[?25h'
  trap - INT
  [[ -n "$prev_int" ]] && eval "$prev_int"
  return 0
}

# splash_maybe — play the splash when it makes sense: interactive terminal,
# not opted out, and enough rows that the animation will not scroll away.
splash_maybe() {
  [[ -t 0 && -t 1 ]] || return 0
  [[ -z "${NETPACK_NO_SPLASH:-}" ]] || return 0
  local rows
  rows="$(term_rows)"
  (( rows >= SPLASH_H + 2 )) || return 0
  # shellcheck disable=SC2119
  splash_play
}
