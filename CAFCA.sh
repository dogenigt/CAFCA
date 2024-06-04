#!/bin/bash

#CONSTS:

SCRIPT=$(readlink -f $0)
HOMEDIR=$(getent passwd pi | cut -d: -f6)
DIR=$(cd $(dirname $SCRIPT) && pwd)

args=("$@")
root_user=

log_dir="$DIR/log"
log_file="$log_dir/CAFCA.log"
rc_log='/dev/shm/runcommand.log'
rc_info='/dev/shm/runcommand.info'
ra_log="$log_dir/retroarch/retroarch.log"

teensy_kbd='/dev/input/by-id/usb-Teensyduino_Serial_Keyboard_Mouse_Joystick_1008140-if02-event-kbd'

data_dir="$DIR/data"
game_table="$data_dir/$system/game_table"

file_regionlist="$data_dir/tmp/regionlist"
file_coins_count="$data_dir/tmp/cafca_coins_cnt"
file_start_count="$data_dir/tmp/cafca_start_cnt"

bypass=$(grep bypass "$data_dir/.settings" | cut -d'=' -f2 | cut -d'#' -f1)

debug=1
testing=0

action='DUMP'
mode='RUNCMD'
coin_key="KEY_C"
start_key="KEY_S"
title_str='GAMEINFO:'
system='mame-libretro'

game=''
game_title=''
coin_addr=''
credits_str=''
scanmode=''
file_matchlist=''

retro_running=0
game_ready=0
game_listed=0
identified=0
scanning=0
matches=0
title_found=0
credits=0
last_credits=0
coins_count=0
start_count=0

declare -A data=()
declare -a regions=()

#___________________________________________________
#

Main() {
  retro_running=1
  serialSend "GAME_LOADED 1"

  get_gamename
  game_table="$data_dir/$system/game_table"

  game_listed=$(cat "$game_table" | grep -wc "$game")
  [[ $game_listed -gt 0 ]] && get_gamedata

  wait_for_game
  serialSend "GAME_READY 1"

  watch_credits

  [[ "$action" == DUMP ]] && cafca_dump
  [[ "$action" == SCAN ]] && cafca_scan

  while (( $retro_running )); do
    retro_running=$(ps -ef | grep -v grep | grep -c -m1 retroarch)

    [[ $identified -gt 0 ]] && credits=$(sudo scanmem -p `pidof retroarch` -c"dump $coin_addr 1;exit" 2>&1 | awk 'NR==15' | awk -F' ' '{print $2}') || calc_credits 1

    if [[ $credits != $last_credits ]]; then
      last_credits=$credits
      serialSend "CREDITS $credits"; debug "credits: $credits"
    fi
    sleep 1
  done

}

#___________________________________________________
#

cafca_scan() {
  scanmode=$(grep -w scanmode "$DIR/data/.settings" | cut -d'=' -f2 | cut -d'#' -f1)

  file_matchlist="$data_dir/$system/scans/$game"
  wipe "$file_matchlist"

  scan_monitor &
  scan_coin

  serialSend "LCD 0 SCANMEM DONE!"

  if [[ $(grep -Pc '\[ 0\]' "$log_dir/expect.log") -gt 0 ]]; then
    debug "found match in log!\n"
    serialSend "LCD 0 MATCH IDENTIFIED"
    sleep 1

    debug "\n\nMATCHLIST: \n"
    grep -P -A10 '\[ 0\]' "$log_dir/expect.log" | awk '{$1=$1;print}' | sed '/exit/d' | sed s'/[,+]//g' | sed 's/[[]//; s/]//' | sudo tee "$file_matchlist"
    debug "\n"
    dump_addr
  fi
}

dump_addr() {
  if [[ "$action" == DUMP ]]; then
    debug "\n\ndump_addr: ${regions[@]}"
    for (( i=0; i<${#regions[@]}; i++)); do
      BASE="${regions[$i]}"
      OFFS="${data[OFFS]}"
      ADDR="";printf -v ADDR "0x%X\n" $(( BASE + OFFS)) &>/dev/null; ADDR=$(echo "$ADDR" | tr '[A-Z]' '[a-z]')
      VAL=$(sudo scanmem -p `pidof retroarch` -c"dump $ADDR 1;exit" 2>&1 | awk 'NR==15' | awk -F' ' '{print $2}')

      calc_credits 1

      if [[ "$VAL" == "$credits_str" ]]; then
        LASTVAL="$credits_str"
        printf -v credits_str '%02d' "$(( credits+1 ))" &>/dev/null
        sudo scanmem -p `pidof retroarch` -c"write i16 $ADDR $credits_str;exit" &>/dev/null && sleep 0.5
        VAL=$(sudo scanmem -p `pidof retroarch` -c"dump $ADDR 1;exit" 2>&1 | awk 'NR==15' | awk -F' ' '{print $2}')

        calc_credits 1 && sleep 0.5
        sudo scanmem -p `pidof retroarch` -c"write i16 $ADDR $credits_str;exit" &>/dev/null

        if [[ ! $VAL == $LASTVAL ]]; then
          if [[ $VAL == $credits_str ]]; then
            coin_addr="$ADDR"
            identified=1 && break
          fi
        fi
      fi
    done
  elif [[ "$action" == SCAN ]]; then
    local match_len=$(cat "$file_matchlist" | wc -l)

    for ((i=1; i<=$match_len; i++)); do
      local line=$(awk -v line="$i" 'NR==line {print $0}' "$file_matchlist")
      local ADDR=$(echo $line | awk '{print "0x"$2}')

      VAL=$(sudo scanmem -p `pidof retroarch` -c"dump $ADDR 1;exit" 2>&1 | awk 'NR==15' | awk -F' ' '{print $2}')
      calc_credits 1
      debug "Match $i addr: $ADDR"

      if [[ "$VAL" == "$credits_str" ]]; then
        LASTVAL="$VAL"
        sudo scanmem -p `pidof retroarch` -c"write i8 $ADDR 0;exit" &>/dev/null && sleep 0.5
        VAL=$(sudo scanmem -p `pidof retroarch` -c"dump $ADDR 1;exit" 2>&1 | awk 'NR==15' | awk -F' ' '{print $2}')

        if [[ ! $VAL == $LASTVAL ]] && [[ $VAL == 00 ]]; then
          debug "IDENTIFIED: $ADDR"

          sudo cp -f "$game_table" "$game_table.bak"
          [[ $game_listed -gt 0 ]] && sudo sed -i "/$game/d" "$game_table"

          echo "$line" | \
            awk -v name="$game" '{
              a=$4;b=$3;c=$5;d=$6;
              $1=$2=$3=$4=$5=$6="";
              pos=index($0, $7);
              e=substr($0, pos,length($0))
              print name"   0x"a"\t"b"\t"c"\t"d"   "e
            }' \
          | sudo tee -a "$game_table"

          cat "$game_table" | sort | sudo tee "$game_table"

          coin_addr="$ADDR"
          sleep 5 # REM
          identified=1 && break
        fi
      fi
    done
  fi
}


cafca_dump() {
  while (( ! $credits )); do calc_credits; done

  serialSend "CREDITS $credits"

  [[ $game_listed -gt 0 ]] && getAddr

  if [[ $identified -gt 0 ]]; then
    serialSend "LCD 0 GAME DATA FOUND:"
    serialSend "LCD 1 $coin_addr: $credits_str"
  fi

}

getAddr() {
  local scan_args='option region_scan_level 3;reset;lregions;exit'
  sudo scanmem -p `pidof retroarch` -c"$scan_args" 2>&1 |& grep --line-buffered -P -A1000 '\[ 0\]' |& sed s'/[][,]//g' | sudo tee "$file_regionlist" &>/dev/null && sudo sed -i '/> exit/d' "$file_regionlist"

  for i in {1..3}; do
    get_regions "${data[NAME]}" $i
    [[ $identified -gt 0 ]] && break
  done

  if [[ $identified -gt 0 ]]; then
    debug "IDENTIFIED:\n\t$coin_addr: $credits_str\n"
    last_credits="$credits_str"
  fi
}

get_regions() {
  local region_list=$(cat "$file_regionlist")
  local region_count=$(cat "$file_regionlist" | wc -l)
  local reg_num=${data[NUM]}
  local range=5

  debug "\n\nget_regions():\n\targs (${#}): ${@}\n\tregions: $region_count\n"

  [[ ${#} -lt 2 ]] && iter=1 || iter=${2}
  [[ ${1} == code ]] && iter=$(( iter - 1 ))

  if [[ $iter == 0 ]]; then
    reg_start=$reg_num
    reg_end=$(( reg_start + 1 ))
  elif [[ $iter == 1 ]]; then
    reg_range=$(calc_range $reg_num $range)
    reg_start=$(echo "$reg_range" | cut -d' ' -f1)
    reg_end=$(echo "$reg_range" | cut -d' ' -f2); reg_end=$(( reg_end+1 ))
  elif [[ $iter -gt 1 ]]; then
    reg_start=1
    reg_end=$region_count
  fi

  for (( i=$reg_start; i<$reg_end; i++)); do
    line=$(awk -v ln="$(( i + 1 ))" 'NR==ln' "$file_regionlist" | awk '{$1=$1; print}')
    name=$(echo "$line" | awk '{print $5}')
    [[ $name == ${data[NAME]} ]] && regions+=("0x$(echo $line | awk '{print $2}')")
  done

  dump_addr
}

scan_coin() {
  /usr/bin/expect -c '
    log_user 1
    exp_internal 0

    set timeout -1
    set cafca_path "/home/pi/CAFCA"
    set log_path "/home/pi/CAFCA/log/expect.log"
    set coin_file "/home/pi/CAFCA/data/tmp/cafca_coins_cnt"
    set scanmode [exec grep -w scanmode "$cafca_path/data/.settings" | cut -d'=' -f2 | cut -d'#' -f1]
    set coin_key "c"

    set pid [exec pidof retroarch]
    set ready 0
    set scanned 0
    set matched 0
    set matches 999
    set match_limit 4
    set credits 0
    set last_credits 0

    exec echo -e "\n" > "$log_path"
    log_file "$log_path"

    send_user "\n\nEXPECT:\nscanmode: $scanmode\n\n"

    spawn scanmem -p $pid

    proc startup {} {
      expect {
        "Please" {
          exec sleep 1
          send "option region_scan_level 3\rreset\r"
          exec sleep 1
          exp_continue
        }
        "*suitable*" {
          set ::ready 1
          exec sleep 1
        }
      }

      if {$::scanmode != "AUTO"} {
        while {$::credits == $::last_credits} {
          set ::credits [exec cat "$::coin_file"]
        }
      }
      while {$::matches > $::match_limit} { get_coin }
      exec sleep 1
      send "list\r"

      expect "* 0*" {
        send "exit\r"
      }
    }

    proc get_coin {} {
      if {$::scanmode == "AUTO"} { insert_coin }

      set ::credits [exec cat "$::coin_file"]
      exec sleep 1

      if {$::credits != $::last_credits} {
        set ::last_credits $::credits
        set_state 1
        exec sleep 1
        send "$::credits\r"
        exec sleep 1

        expect {
          "*currently*" {
            set_state 0
            set ::matches [lindex [split [lindex [split $expect_out(buffer) "\n"] end-1 ] " " ] end-1 ]
            exec sleep 1

            if {$::matches == 0} {
              set ::matches 999
              send "option region_scan_level 3\rreset\r"
            } elseif {$::matches == "other"} {
              set ::matches 1
            }
          }
        }
      }
    }

    proc insert_coin {} {
      exec printf $::coin_key > /tmp/vkbdd.fifo
      exec sleep 1
      set ::credits [expr {$::credits + 1}]
      exec echo "$::credits" | sudo tee "$::coin_file"
      exec sleep 1
    }

    proc set_state {arg {second ""} args} {
      if {$second eq ""} {
        exec sed -i "/SCANNING/d" /home/pi/CAFCA/data/states
        exec echo "SCANNING=$arg" | sudo tee -a /home/pi/CAFCA/data/states
      }
    }

    startup
    expect eof
  '
}

scan_monitor() {
  local state=0
  local last_state=0

  exec echo "SCANNING=0" | sudo tee /home/pi/CAFCA/data/states &>/dev/null

  serialSend "LCD 0 SCANMEM READY"

  while (( ! $identified )); do
    state=$(grep -w -m1 SCANNING "$data_dir/states" | cut -d= -f2)
    if [[ $state -ne $last_state ]] && [[ $state > 0 ]]; then
      serialSend "LCD 0 SCANMEM SCANNING"; sleep 1

      while [[ $state -gt 0 ]]; do
        state=$(grep -w -m1 SCANNING "$data_dir/states" | cut -d= -f2)
        str=$(awk 'END{print}' "$log_dir/expect.log" | grep searching | awk '{$1=$1;print}')
        if [[ ${#str} -gt 0 ]]; then
          numbs=$(echo "$str" | awk '{print $1}')
	  dots=$(echo "$str" | awk -F'ok' '{print $1}' | cut -d. -f2- | wc -m)
          percentage=$(echo "$numbs $dots" | awk '{split($1,ints,"/"); a = (ints[1]*10); b = (ints[2]*10); c = $2; printf "%0.2f\n", (((a+c)/b)*100)}')
          output_str=$(echo "$numbs ($percentage)")
          serialSend "LCD 1 $output_str"
        fi
        sleep 1
      done
      last_state=$state

      matches=$(grep -w currently "$log_dir/expect.log" | tail -1 | grep currently | awk '{print $5}')
      [[ $matches -le 5  ]] && serialSend "LCD 0 SCANMEM DONE!" || serialSend "LCD 0 SCANMEM READY"
      serialSend "LCD 1 $matches MATCHES."
    fi
  done
}

wait_for_game() {
  limit=20
  repeats=0
  last_len=0

  while (( ! $game_ready )); do
    log_len=$(wc -l $ra_log | cut -d' ' -f1)

    if [[ $repeats -lt $limit ]]; then
      [[ $log_len == $last_len ]] && repeats=$(( repeats + 1 ))
      last_len=$log_len
    else
      game_ready=1 && break
    fi
    (( ! $title_found )) && get_title
    sleep 0.5
  done

  serialSend "GAME_READY 1"
  debug "\n\n"
  debug "Game Ready!"
  debug "last log: \x22$(awk 'END{print}' $ra_log)\x22"
}

get_title() {
  game_title=$(grep -wc "$title_str" $ra_log)
  if [[ $game_title -gt 0 ]]; then
    game_title=$(grep -w -A1 "$title_str" $ra_log | awk -F':' '{if(NR==1){str=$2}else{str="("$0")"}; printf "%s ", str} END {print ""}')
    debug "GAME TITLE:    $game_title"
    serialSend "GAME_TITLE $game_title"
    title_found=1
  fi
}

get_gamedata() {
  local table_data=$(cat "$game_table" | grep -w "$game" | awk '{$1=$1;print}')

  data[GAME]=$(echo "$table_data" | awk '{print $1}')
  data[OFFS]=$(echo "$table_data" | awk '{print $2}')
  data[NUM]=$(echo "$table_data" | awk '{print $3}')
  data[NAME]=$(echo "$table_data" | awk '{print $4}')
  data[TYPE]=$(echo "$table_data" | awk -F'\[' '{print substr($2,0,length($2))}')

  debug "\n\nget_gamedata():"
  for i in "${!data[@]}"; do
    debug "$i:\t\t${data[$i]}"
  done
}

get_gamename() {
  if [[ "$mode" == RUNCMD ]]; then
    system=$(awk 'NR==1' $rc_info); debug "SYSTEM: $system"
    game=$(awk -F'/' 'NR==3 {print $NF}' $rc_info | cut -d. -f1); debug "GAME: $game"
  fi

  game_name=$(echo "$game" | tr '[:lower:]' '[:upper:]')
  serialSend "GAME_NAME $game_name"
}

calc_range() {
  base=$1
  int=$2
  sum=$(( base - int ))

  if [[ $sum -le 0 ]]; then
    start=1; end=$(( int+int ))
  else
    start=$sum; end=$(( base+int ))
  fi

  echo "$start $end" # return
}

calc_credits() {
  coins_count=$(cat "$file_coins_count")
  start_count=$(cat "$file_start_count")
  credits=$(( coins_count - start_count ))
  [[ $# > 0 ]] && printf -v credits_str '%02d' "$credits" &>/dev/null
}

watch_credits() {
  read_inputs &
}

read_inputs() {
  local coins_cnt=0
  local start_cnt=0
  local limit_start=20
  local t_start=$limit_start
  local last_start=$(date +%s)

  while read -r line; do
    pressed=$(echo "$line" | grep -E "$coin_key|$start_key" | \
      awk -v C="$coin_key" -v S="$start_key" '{
        if ($2 == C) print "COIN"
        if ($2 == S) print "START"
      }')

    coins_cnt=$(cat "$file_coins_count")
    start_cnt=$(cat "$file_start_count")

    if [[ $pressed == COIN ]]; then
      echo "$(( coins_cnt + 1 ))" | sudo tee $file_coins_count &>/dev/null
    elif [[ $pressed == START ]]; then
      if [[ $coins_cnt -gt 0 ]]; then
        if [[ $start_cnt -gt 0 ]]; then
          t_start=$(( `date +%s` - $last_start ))
          if [[ $t_start -ge $limit_start ]]; then
            echo "$(( start_cnt + 1 ))" | sudo tee $file_start_count &>/dev/null
            last_start=$(date +%s); t_start=0
          fi
        else
          echo "$(( start_cnt + 1 ))" | sudo tee $file_start_count &>/dev/null
          last_start=$(date +%s); t_start=0
        fi
      fi
    fi

    if [[ "$action" == SCAN ]]; then
      scanning=$(grep -w -m1 SCANNING "$data_dir/states" | cut -d= -f2)
      while (( $scanning )); do
        scanning=$(grep -w -m1 SCANNING "$data_dir/states" | cut -d= -f2)
      done
    fi
  done< <(thd --dump "$teensy_kbd" 2>&1 |& grep --line-buffered -E "$coin_key|$start_key" | awk -W interactive '{$1=$1;print}' | grep --line-buffered -Ew "EV_KEY $coin_key 1|EV_KEY $start_key 1" 2>&1)
}

wipe() {
  file="$@"
  [[ ! -f "$file" ]] && sudo touch "$file" &>/dev/null \
  || echo -e "\n" | sudo tee "$file" &>/dev/null
  sudo chmod 775 "$file" &>/dev/null
}

serialSend() {
 [ -c /dev/ttyACM0 ] && printf "${@}" > /tmp/pyserial.fifo
 sleep 0.5
}

press_key() {
  printf $@ > /tmp/vkbdd.fifo
}

debug() {
  (( $debug )) && echo -e "[DEBUG] $@"
}

cleanup() {
  debug "Cleaning up..."
  serialSend "GAME_STOPPED 1"
  (( $retro_running )) && printf '\033' >/tmp/vkbdd.fifo #sudo pkill retroarch
}

#_____________________________________________________
#
# SETUP
#
#---------------------------------------------------

(( ! $(id -u) )) && root_user=1 || root_user=0

trap cleanup EXIT

wipe "$log_file"
wipe "$ra_log"

ra_log_owner=$(ls -l "$log_dir/retroarch" | grep "$(echo $ra_log | cut -d/ -f7)" | awk '{print $3" "$4}')

[[ $ra_log_owner != "pi pi" ]] && sudo chown pi:pi "$ra_log"

exec > >(sudo tee $log_file 2>&1)

debug "\n\nC A F C A\n\n`date '+%d/%m-%Y %T'`\n\nHOMEDIR:\t$HOMEDIR\nDIR:\t\t$DIR\nSCRIPT:\t\t$SCRIPT\nROOT USER:\t$root_user\n"

if [ "${#args[@]}" -gt 0 ]; then
  testing=0
  action=$(echo "$1" | tr '[:lower:]' '[:upper:]')
  [ "${#args[@]}" -gt 1 ] && mode=$(echo "$2" | tr '[:lower:]' '[:upper:]')
  debug "ARGS: \x27${args[@]}\x27 (${#args[@]})\n\n"
else
  debug "NO ARGS..\n"
fi

debug "MODE:\t$mode\n\tACTION:\t$action\n\n"

wipe "$file_regionlist"
wipe "$file_coins_count" && echo 0 | sudo tee "$file_coins_count" &>/dev/null
wipe "$file_start_count" && echo 0 | sudo tee "$file_start_count" &>/dev/null

[[ $bypass -ne 1 ]] && Main

exit 0

#____________________________________________________
