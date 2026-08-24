#!/usr/bin/env bash
# Drive the chassis fans off GPU and CPU temperature, because the board cannot.
#
#   sudo bash fan-curve.sh install     # module + unit + config, enable, start
#   sudo bash fan-curve.sh uninstall   # stop, disable, hand the fans back
#   sudo bash fan-curve.sh status      # what is bound, what is spinning
#   sudo bash fan-curve.sh test        # ramp to full for 8s, then restore
#   sudo bash fan-curve.sh run         # the daemon itself (what systemd calls)
#
# Why this exists: on this ROG Strix X670E-F the fan controller is a Nuvoton
# NCT6799D that Linux cannot see until nct6775 is loaded, so the BIOS SmartFan
# curve is the only thing managing airflow - and it is tuned for gaming bursts,
# not for a 5090 drawing 350-600 W for hours while k10temp reads Tctl 71 C.
#
# A *system* unit, unlike install-service.sh's deliberately-rootless user unit:
# writing /sys/class/hwmon/*/pwm* requires root and there is no way around it.
#
# THE TWO SAFETY PROPERTIES, because this controls cooling hardware:
#
#   1. It can only ever make fans spin FASTER. Every channel is clamped to a
#      floor recorded from the BIOS at install time, so the worst a bug or a
#      bad curve can do is make the machine loud. Nothing here can produce less
#      airflow than the board is already providing today.
#   2. It never touches FAN_EXCLUDE (channel 7 by default). On this board that
#      channel sits at pwm=255 with the only live tach (1856 RPM), which is how
#      ASUS drives an AIO_PUMP header - and an AIO pump must not be modulated
#      by a curve that thinks it is a fan. Slowing a pump is the one mistake
#      here that damages hardware rather than just making noise.
#
# Restores BIOS control (pwm_enable=5) on every exit path - clean stop, SIGTERM
# from systemd, or a crash - because a manual PWM value persists in the chip
# after the writer is gone. Note the failure mode that leaves: a daemon killed
# with SIGKILL cannot restore, so the fans stay at their last commanded value.
# Given property 1 that means "stuck loud", never "stuck slow".
set -euo pipefail

CONF="/etc/qwen5090/fan-curve.env"
UNIT="/etc/systemd/system/qwen5090-fans.service"
MODCONF="/etc/modules-load.d/qwen5090-fans.conf"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ "$(id -u)" == "0" ]] || die "needs root: sudo bash $0 $*"; }

# ---------------------------------------------------------------- discovery
# By name, never by index. /sys/class/hwmon/hwmonN numbering depends on probe
# order and genuinely moves between boots once you add or remove a module - a
# hardcoded hwmon6 would one day write a fan curve into an NVMe controller.
_hwmon_by_name() {
  local want="$1" h n
  for h in /sys/class/hwmon/hwmon*; do
    n=$(cat "$h/name" 2>/dev/null) || true
    [[ "$n" == "$want" ]] && { echo "$h"; return 0; }
  done
  return 1
}

find_chip() {
  local h=""
  h=$(_hwmon_by_name "${FAN_CHIP:-nct6799}") || true
  [[ -n "$h" ]] || h=$(_hwmon_by_name nct6798) || true
  [[ -n "$h" ]] || h=$(_hwmon_by_name nct6796) || true
  [[ -n "$h" ]] || return 1
  echo "$h"
}

# ---------------------------------------------------------------- settings
load_conf() {
  # shellcheck disable=SC1090
  [[ -f "$CONF" ]] && source "$CONF"
  FAN_CHANNELS="${FAN_CHANNELS:-1 2 3 4 5 6}"
  FAN_EXCLUDE="${FAN_EXCLUDE:-7}"
  FAN_FLOOR="${FAN_FLOOR:-208}"
  FAN_INTERVAL="${FAN_INTERVAL:-2}"
  # "temp:pwm" points, ascending. Below the first point the floor applies.
  FAN_CURVE_GPU="${FAN_CURVE_GPU:-60:208 65:224 70:240 75:255}"
  FAN_CURVE_CPU="${FAN_CURVE_CPU:-65:208 72:224 78:240 85:255}"
  # Degrees C, not PWM units - see step_level. FAN_HYSTERESIS is the old,
  # wrongly-scaled name; honoured as a fallback so an existing config keeps
  # working, and 4 happens to be a sensible number of degrees too.
  FAN_HYSTERESIS_C="${FAN_HYSTERESIS_C:-${FAN_HYSTERESIS:-3}}"
}

# Curve state: one level index per curve, held between samples rather than
# recomputed from scratch. -1 means "below the first point", i.e. the floor.
#
# The level has to be *held* for hysteresis to be expressible at all, and it
# has to be expressed in DEGREES, on the way down. The first version of this
# compared PWM values with a threshold of 4 while the curve steps 16 at a time,
# so every downward step cleared it trivially and the guard never fired: a GPU
# sitting on a boundary - flickering 69/70 C, which is precisely what a loaded
# 5090 does - flipped the fans between 87% and 94% every 2 seconds.
GPU_LEVEL=-1
CPU_LEVEL=-1

# Step a level toward where `temp` says it belongs. Up is immediate; down needs
# the temperature to fall FAN_HYSTERESIS_C below the threshold that put us here.
step_level() {
  local temp="$1" curve="$2" level="$3" pt
  local -a T=()
  for pt in $curve; do T+=("${pt%%:*}"); done
  local n=${#T[@]}
  while (( level + 1 < n )) && (( temp >= T[level+1] )); do level=$(( level + 1 )); done
  # The level >= 0 guard is load-bearing: bash reads T[-1] as the LAST element,
  # so without it a floor-level curve would compare against the top threshold.
  while (( level >= 0 )) && (( temp < T[level] - FAN_HYSTERESIS_C )); do level=$(( level - 1 )); done
  echo "$level"
}

level_pwm() {
  local curve="$1" level="$2" pt
  (( level < 0 )) && { echo "$FAN_FLOOR"; return; }
  local -a P=()
  for pt in $curve; do P+=("${pt##*:}"); done
  echo "${P[level]}"
}

read_gpu_temp() {
  command -v nvidia-smi >/dev/null 2>&1 || { echo 0; return; }
  local t=""
  t=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1) || true
  [[ "$t" =~ ^[0-9]+$ ]] && echo "$t" || echo 0
}

read_cpu_temp() {
  local h="" t=""
  h=$(_hwmon_by_name k10temp) || true
  [[ -n "$h" ]] || { echo 0; return; }
  t=$(cat "$h/temp1_input" 2>/dev/null) || true       # Tctl
  [[ "$t" =~ ^[0-9]+$ ]] && echo $(( t / 1000 )) || echo 0
}

# ---------------------------------------------------------------- the daemon
declare -A SAVED_EN
CHIP=""

restore_bios() {
  local i
  [[ -n "$CHIP" ]] || return 0
  for i in $FAN_CHANNELS; do
    # 5 = SmartFan IV, the chip's own automatic curve. Fall back to whatever
    # was there at startup if we somehow recorded something else.
    echo "${SAVED_EN[$i]:-5}" > "$CHIP/pwm${i}_enable" 2>/dev/null || true
  done
  echo ">> fan control handed back to the BIOS curve"
}

cmd_run() {
  need_root run
  load_conf
  CHIP=$(find_chip) || die "no NCT67xx hwmon found - is nct6775 loaded?"
  echo ">> chip: $CHIP ($(cat "$CHIP/name"))"
  echo ">> channels: $FAN_CHANNELS   excluded: $FAN_EXCLUDE   floor: $FAN_FLOOR"

  local i
  for i in $FAN_CHANNELS; do
    [[ -w "$CHIP/pwm${i}" ]] || die "cannot write $CHIP/pwm${i}"
    SAVED_EN[$i]=$(cat "$CHIP/pwm${i}_enable" 2>/dev/null || echo 5)
  done
  trap 'restore_bios; exit 0' EXIT INT TERM

  for i in $FAN_CHANNELS; do echo 1 > "$CHIP/pwm${i}_enable"; done

  local gpu cpu want_g want_c want last=0
  while :; do
    gpu=$(read_gpu_temp); cpu=$(read_cpu_temp)
    GPU_LEVEL=$(step_level "$gpu" "$FAN_CURVE_GPU" "$GPU_LEVEL")
    CPU_LEVEL=$(step_level "$cpu" "$FAN_CURVE_CPU" "$CPU_LEVEL")
    want_g=$(level_pwm "$FAN_CURVE_GPU" "$GPU_LEVEL")
    want_c=$(level_pwm "$FAN_CURVE_CPU" "$CPU_LEVEL")
    want=$(( want_g > want_c ? want_g : want_c ))
    (( want < FAN_FLOOR )) && want=$FAN_FLOOR      # property 1, enforced here
    (( want > 255 )) && want=255

    # step_level already applied the hysteresis, so any change here is real.
    if (( want != last )); then
      for i in $FAN_CHANNELS; do echo "$want" > "$CHIP/pwm${i}" 2>/dev/null || true; done
      printf '%s  gpu=%sC cpu=%sC -> pwm %s (%s%%)\n' \
        "$(date '+%H:%M:%S')" "$gpu" "$cpu" "$want" "$(( want * 100 / 255 ))"
      last=$want
    fi
    sleep "$FAN_INTERVAL"
  done
}

# ---------------------------------------------------------------- test
cmd_test() {
  need_root test
  load_conf
  CHIP=$(find_chip) || die "no NCT67xx hwmon found - is nct6775 loaded?"
  local i
  declare -A OLD_PWM
  for i in $FAN_CHANNELS; do
    SAVED_EN[$i]=$(cat "$CHIP/pwm${i}_enable"); OLD_PWM[$i]=$(cat "$CHIP/pwm${i}")
  done
  trap 'for i in $FAN_CHANNELS; do echo "${OLD_PWM[$i]}" > "$CHIP/pwm${i}" 2>/dev/null || true; done; restore_bios' EXIT INT TERM
  echo ">> channels $FAN_CHANNELS to full for 8s - LISTEN. Channel(s) $FAN_EXCLUDE untouched."
  for i in $FAN_CHANNELS; do echo 1 > "$CHIP/pwm${i}_enable"; echo 255 > "$CHIP/pwm${i}"; done
  sleep 8
}

# ---------------------------------------------------------------- status
cmd_status() {
  load_conf
  local h="" i
  h=$(find_chip) || { echo "chip:    NOT BOUND (nct6775 not loaded)"; }
  if [[ -n "$h" ]]; then
    echo "chip:    $h ($(cat "$h/name"))"
    printf "%-5s %-8s %-8s %-8s\n" CH PWM PCT RPM
    for i in $FAN_CHANNELS $FAN_EXCLUDE; do
      printf "%-5s %-8s %-8s %-8s\n" "$i" \
        "$(cat "$h/pwm${i}" 2>/dev/null || echo -)" \
        "$(( $(cat "$h/pwm${i}" 2>/dev/null || echo 0) * 100 / 255 ))%" \
        "$(cat "$h/fan${i}_input" 2>/dev/null || echo -)"
    done
  fi
  echo "gpu:     $(read_gpu_temp) C"
  echo "cpu:     $(read_cpu_temp) C (Tctl)"
  echo "module:  $(lsmod | grep -q '^nct6775' && echo loaded || echo 'NOT loaded')"
  # Both of these print a word AND return non-zero when the unit is absent,
  # so a `|| echo` fallback appends a second line rather than replacing it.
  echo "unit:    $(systemctl is-active qwen5090-fans 2>/dev/null | head -1) / $(systemctl is-enabled qwen5090-fans 2>/dev/null | head -1)"
}

# ---------------------------------------------------------------- install
cmd_install() {
  need_root install
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found - this needs systemd."

  echo ">> loading nct6775"
  modprobe nct6775 || die "modprobe nct6775 failed"
  echo "nct6775" > "$MODCONF"                    # so it comes back after a reboot

  load_conf
  local chip="" floor=""
  chip=$(find_chip) || die "nct6775 loaded but no NCT67xx hwmon appeared"

  # Record the BIOS baseline as the floor, so the guarantee is measured from
  # this machine's actual configuration rather than from a number I guessed.
  floor=$(cat "$chip/pwm1" 2>/dev/null) || true
  [[ "$floor" =~ ^[0-9]+$ ]] || floor=208

  if [[ -f "$CONF" ]]; then
    echo ">> keeping existing $CONF"
  else
    mkdir -p "$(dirname "$CONF")"
    cat > "$CONF" <<CONFEOF
# Chassis fan curve. Restart to apply:  systemctl restart qwen5090-fans
#
# Channels driven together as a group. Per-fan curves would be nicer but need
# a pwmconfig mapping pass, and on this board only one tach line reports RPM
# (fan7), so there is nothing to map the other six against from software.
FAN_CHANNELS="1 2 3 4 5 6"

# NEVER driven by this daemon. Channel 7 is the AIO pump on this machine:
# pwm=255 with the only live tach. Modulating a pump is how you cook a CPU.
FAN_EXCLUDE="7"

# Hard lower clamp, recorded from the BIOS SmartFan value at install time.
# The daemon can raise fans above this and never lower them below it, which is
# what makes a bad curve a noise problem instead of a thermal one. Lower it
# only once you have confirmed by ear which header drives what.
FAN_FLOOR=$floor

# "temp:pwm" points, ascending, pwm out of 255. The GPU curve is the one that
# matters here - it is what pulls 600 W - and the CPU curve is a backstop.
FAN_CURVE_GPU="60:$floor 65:224 70:240 75:255"
FAN_CURVE_CPU="65:$floor 72:224 78:240 85:255"

FAN_INTERVAL=2

# Degrees C the temperature must fall BELOW a curve threshold before the fans
# step back down. Guards against audible pumping when a temperature sits on a
# boundary; raise it if you still hear the fans hunting.
FAN_HYSTERESIS_C=3
CONFEOF
    echo ">> wrote $CONF (floor recorded from BIOS: $floor)"
  fi

  cat > "$UNIT" <<UNITEOF
[Unit]
Description=Qwen5090 chassis fan curve (NCT6799D)
Documentation=file://$SELF
After=multi-user.target

[Service]
Type=simple
EnvironmentFile=-$CONF
ExecStart=/usr/bin/env bash $SELF run
# The daemon restores BIOS control from its own EXIT trap; SIGTERM lets it.
KillSignal=SIGTERM
TimeoutStopSec=15
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF
  echo ">> wrote $UNIT"

  systemctl daemon-reload
  systemctl enable --now qwen5090-fans
  sleep 3
  systemctl --no-pager --lines=15 status qwen5090-fans || true
}

cmd_uninstall() {
  need_root uninstall
  systemctl disable --now qwen5090-fans 2>/dev/null || true
  rm -f "$UNIT" "$MODCONF"
  systemctl daemon-reload 2>/dev/null || true
  echo ">> removed unit and module autoload. $CONF kept; delete it by hand if you want."
  echo ">> nct6775 is still loaded for this boot; the fans are back on the BIOS curve."
}

case "${1:-status}" in
  run)       cmd_run ;;
  test)      cmd_test ;;
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status ;;
  *)         die "usage: $0 {install|uninstall|status|test|run}" ;;
esac
