#!/bin/bash

PID=$$
SCRIPT=$(readlink -f "$0")
DIR=$(cd "$(dirname $SCRIPT)" && pwd)
HOMEDIR=$(getent passwd pi | cut -d: -f6)

credits_log="$DIR/log/credits.log"
ra_log=$(sed -n '/^RETROARCH_LOG=/ { s/\(.*\)=//g; s/\x27//g; p }' "$DIR/.settings")
game_info=$(sed -n '/^ACTIVE_GAME=/ { s/\(.*\)=//g; s/\x27//g; p }' "$DIR/.settings")

HAS_DATA=0
IDENTIFIED=0
LAST_VAL=
VAL=
ADDR=

declare -A data=()

# -------------------------------------------------------------------------

getData() {
  data[GAME]="${game_info#*'/'}"
  data[SYSTEM]="${game_info%'/'*}"
  addr_data=$(grep -w -m1 "^${data[GAME]}\( \|$\)" "$DIR/data/${data[SYSTEM]}/table" | awk '{$1=$1="";print}')

  if [[ ${#addr_data} -gt 0 ]]; then
    for i in OFFSET REGNUM REGNAM VARPOS DATYPE; do (( count++ ));
      data["$i"]=$(echo "$addr_data" | awk -v pos="$count" '{print $pos}')
    done
    HAS_DATA=1
  fi
}

# -------------------------------------------------------------------------

waitForGame() {
  local GAME_READY=0
  declare -a words=('hiscore.dat' 'SET_GEOMETRY')

  while [[ $GAME_READY -eq 0 ]]; do GAME_READY=$(grep -c "$(echo ${words[*]} | sed s'/ /\\|/g')" $ra_log); done
  sleep $1
}

# -------------------------------------------------------------------------

checkMiscReg() {
  local COINS=
  local COINS_LAST=
  declare -a regs=("${data[REGNUM]}")

  for i in {1..10}; do
    regs+=("$(( ${data[REGNUM]} - i ))")
    regs+=("$(( ${data[REGNUM]} + i ))")
  done

  for reg in "${regs[@]}"; do
    data[REGNUM]="$reg"; ADDR=$(dumpAddr)
    VAL=$(sudo scanmem -p `pidof retroarch` -c"dump $ADDR 1;exit" 2>&1 | awk 'NR==15' | awk -F' ' '{print $2}')
    COINS=$(sed -n '/^C:/ {s/\(.*:\)//;p}' "$credits_log")
    [[ "$VAL" =~ ^[0-9A-Fa-f]+$ ]] && [[ $(echo "$((16#$VAL))") -eq $COINS ]] && { IDENTIFIED=1; break; }
  done
}

# -------------------------------------------------------------------------

dumpAddr() {
  local scan_args="option region_scan_level 3; reset; dregions !${data[REGNUM]}; lregions; exit"
  local REG_OFFS=$(sudo scanmem -p `pidof retroarch` -c"$scan_args" 2>&1 |& grep --line-buffered -A1 "lregions" | awk 'NR==2' | awk '$1=$1 {print}' | cut -d] -f2 | awk -F" " '{print $1}' | cut -d, -f1); REG_OFFS="0x${REG_OFFS}"
  printf -v ADDR "0x%X\n" $(( REG_OFFS + ${data[OFFSET]} )) &>/dev/null; echo "${ADDR,,}"
}


# _________________________________________________________________________

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf "C:0\nS:0\nX:0\n" > "$credits_log"

  while [[ $(pgrep -c retroarch) -lt 1 ]]; do :; done

  getData
  waitForGame 1

  if [[ $HAS_DATA -gt 0 ]]; then
    if [[ "${data[REGNAM]}" == misc ]]; then
      while [[ $(sed -n '/^C:/ {s/\(.*:\)//;p}' "$credits_log") -lt 1 ]] && [[ $(pgrep -c retroarch) -gt 0 ]]; do :; done
      checkMiscReg
    else
      ADDR=$(dumpAddr)
      IDENTIFIED=1
    fi
  fi

  while [[ $(pgrep -c retroarch) -gt 0 ]]; do
    if [[ $IDENTIFIED -gt 0 ]] && [[ ${#ADDR} -gt 0 ]]; then
      VAL=$(sudo scanmem -p `pidof retroarch` -c"dump $ADDR 1;exit" 2>&1 | awk 'NR==15 {print $2}')
      [[ "$VAL" =~ ^[0-9A-Fa-f]+$ ]] && VAL=$VAL || VAL=$LAST_VAL
      CREDITS="$((16#$VAL))";
    else
      VAL=$(sed -n '/^X:/ {s/\(.*:\)//;p}' "$credits_log")
      CREDITS="$VAL"
    fi

    if [[ $VAL != $LAST_VAL ]]; then
      echo "$( (( ${#ADDR} )) && echo $ADDR || echo COINS ) : $VAL ( $CREDITS )"
      LAST_VAL=$VAL
    fi
    sleep 1
  done
fi
