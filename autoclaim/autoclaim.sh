#!/usr/bin/env bash
# I recommend to use this script outside your BP node. If so I fully recommend
# to do it over a secured connection since you have to send your wallet's pass
# to your BP (or any other BP) node to be processed. You can install a reverse
# proxy like nginx (check:). Make sure you have a local  wallet defined with your
# BP key imported.
# This script was inspired by the one created by AnsenYu
# https://github.com/AnsenYu/ENUAvengers/tree/master/scripts/bpclaim
# Dragos Vlaicu - 07/05/2018 - ENU BP - eosbucharest
# Version: 1.2

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# lock the timezone to UTC to match the database
export TZ=Etc/UTC

# IF you are not using the default wallet you can mention it here
wallet=''
# one day in seconds
day=86400

# cleos wallet shortcut if the binaries were not installed after the build
# followed by the BP http(s) server
cleos='/usr/bin/cleos -u https://instar.greymass.com/'
# The ammount of coins you want to leave in your wallet. The rest will be staked
# it should be an integer from 0 to whatever you want
# WARNING: The rest of the coins will be staked
keep=0
passwd=$1
BP=$2

# Telegram configuration
# If you configure your bot_token you will automatically enable the notification.
# telegram bot token ID
bot_token=''
# private chat ID
chat_id=''


# PushBullet configuration
# Anything configured below will automatically enable pushbullet notifications.
# Leave it empty if you don't use it.
push_token=''


#script working directory
script="$(readlink -f $0)"
wd="$(dirname ${script})"
# log file
logfile="${wd}/instar_autoclaim.log"

function last() {
  now_epoch=$(date +"%s")
  time_diff=$((${now_epoch}-$1))
  echo ${time_diff}
}

function logall() {
  tolog=$@
  TS="$(date '+[%Y-%m-%d %H:%M:%S]')"
  echo "${TS} ${tolog}" | tee -a ${logfile}
  if [[ -z ${bot_token} ]]; then
    curl -s https://api.telegram.org/bot${bot_token}/sendMessage -d chat_id="${chat_id}" -d text="${TS} ${tolog}" > /dev/null
  fi
  if [[ -z ${push_token} ]]; then
    curl -u ${push_token}: https://api.pushbullet.com/v2/pushes -d type=note -d title="Instar autoclaim script" -d body="${TS} ${tolog}"

  fi
}

# Check if the two needed variables were given
# expected: wallet's password followed by BPUsername
if [ $# -ne 2 ]; then
  logall "You're missing a few arguments"
  logall "Please use the script like this: $0 BPWalletPwd BPUsername"
  exit 1
fi

# Validate the password format
if [[ ! $passwd =~ ^PW5.* ]]; then
  logall "Invalid wallet password. Exiting ..."
  exit 2
fi

# Check last claimed time
last_claim_time=$(${cleos} get table eosio eosio producers -l 10000 | jq -r '.rows[] | select(.owner == "'${BP}'") | .last_claim_time')
if [[ $? -ne 0 || ${last_claim_time} -eq 0 ]]; then
    logall "Invalid last claim time, claim manually to set a relevant time. Exiting ..."
    exit 3
fi
# calculate how much time it passed from last claim. if it's under a day we'll wait a bit more.
# adjust timestamp based on the update
last_claimed=$((${last_claim_time} / 1000000))

st=1
while [[ ${st} -ne 0 ]]; do
    if [[ $(last ${last_claimed}) -lt ${day} ]]; then
        sleep 2
    else
        # unlock the wallet
        ${cleos} wallet unlock -n ${wallet} --password ${passwd}
        # Check if the wallet gets unlocked successfully
        if [[ $? -ne 0 ]]; then
            logall "Unable to unlock your wallet with given password. Exiting ..."
            exit 4
        fi

        # try to claim your stakes
        claim=$(${cleos} system claimrewards ${BP} 2>&1)
        if [[ $? -ne 0 ]]; then
            sleep 2
            # we will try to claim again.
            claim=$(${cleos} system claimrewards ${BP} 2>&1)
            if [[ $? -ne 0 ]]; then
                ${cleos} wallet lock_all
                logall "Error wile claiming. Check log file and do it manually if you can. Exiting ..."
                echo "${claim}" >> ${logfile}
                exit 5
            fi
        fi
        logall "Claimed successfully"
        # Get the coins out of your wallet. WARNING: It will use all your coins from
        # your wallet. IF you want to keep some aside please configure the variable keep

        # check if bc is instaled.
        instbc=0
        # split wallet's coins in two to stake them evenly. It will get rounded down
        which bc >/dev/null
        if [[ $? -ne 0 ]]; then
            logall "bc is not installed. I will try to install it for you. Root access is needed."
            sudo apt-get update
            sudo apt-get install bc -y
            if [[ $? -ne 0 ]]; then
                logall " Unable to install bc. I'm unable to split your coins in half for staking. Please stake them manually."
                instbc=1
            fi
        fi

        if [[ ${instbc} -eq 0 ]]; then
            bpay=$(echo "${claim}" | awk -F '"' '/'${BP}' <= eosio.token/ && $4 == "eosio.bpay" {print substr($12,1, length($12)-7)}')
            if [[ -z ${bpay} ]]; then
                bpay=0
            fi
            vpay=$(echo "${claim}" | awk -F '"' '/'${BP}' <= eosio.token/ && $4 == "eosio.vpay" {print substr($12,1, length($12)-7)}')
            if [[ -z ${vpay} ]]; then
                vpay=0
            fi

            stotal=$(bc <<< "${bpay} + ${vpay}")
            #walletcoins=$(${cleos} get currency balance enu.token ${BP} | awk '{print $1}')
            logall "Today you claimed as blockproducer [${bpay}] and based on votes [${vpay}] in total: [${stotal}]"

            tostake=$(bc <<< "(${stotal} - ${keep}) / 2")
            if [[ ${tostake} -gt 0 ]]; then
                # Stake your coins
                ${cleos} system delegatebw ${BP} ${BP} "${tostake} INSTAR" "${tostake} INSTAR"
                logall "${tostake} ENU were staked for CPU and the same for Network"
            fi
        fi
        # Lock your wallet.
        ${cleos} wallet lock_all
        if [[ $? -eq 0 ]]; then
            logall "All wallets are locked now"
        fi
        st=0
    fi
done
