#!/bin/bash

# command info
if [ "$1" = "-h" ] || [ "$1" = "-help" ]; then
 echo "# Turns the RaspiBlitz into HDD CopyStation Mode"
 echo "# lightning is deactivated during CopyStationMode"
 echo "# reboot RaspiBlitz to set back to normal mode"
 exit 1
fi

####### CONFIG #############

# where to find the BITCOIN data directory (no trailing /)
pathBitcoinBlockchain="/mnt/hdd/bitcoin"

# where to find the LITECOIN data directory (no trailing /)
pathLitecoinBlockchain="/mnt/hdd/litecoin"

# where to find the RaspiBlitz HDD template directory (no trailing /)
pathTemplateHDD="/mnt/hdd/templateHDD"

# 0 = ask before formatting/init new HDD
# 1 = auto-formatting every new HDD that needs init
nointeraction=1

# override values if XXcopyStation.conf files exists
# use when you run this outside RaspiBlitz
# - clean Ubuntu install
# - install bitcoind as systemd service
# - disable automount: https://askubuntu.com/questions/89244/how-to-disable-automount-in-nautiluss-preferences#102601
# - clone the github to get script (or download)
# - set your pathes bitcoin/template in conf file
source ./XXcopyStation.conf 2>/dev/null
# -- start script with parameter "-foreground"

####### SCRIPT #############

# check sudo
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (with sudo)"
  exit 1
fi

# make sure that its running in screen
# call with '-foreground' to prevent running in screen
if [ "$1" != "-foreground" ]; then 
  screenPID=$(screen -ls | grep "copystation" | cut -d "." -f1 | xargs)
  if [ ${#screenPID} -eq 0 ]; then
    # start copystation in sreen 
    echo "starting copystation screen session"
    screen -S copystation -dm /home/admin/XXcopyStation.sh -foreground
    screen -d -r
    exit 0
  else
    echo "changing into running copystation screen session"
    screen -d -r
    exit 0
  fi
fi

clear
echo "******************************"
echo "RASPIBLITZ COPYSTATION SCRIPT"
echo "******************************"
echo

echo "*** CHECKING CONFIG"

# check that path information is valid
if [ -d "$pathBitcoinBlockchain" ]; then
  echo "OK found $pathBitcoinBlockchain"
else
  echo "FAIL path of 'pathBitcoinBlockchain' does not exists: ${pathBitcoinBlockchain}"
  exit 1
fi

# check that path information is valid
if [ -d "$pathTemplateHDD" ]; then
  echo "OK found $pathTemplateHDD"
else
  echo "Creating: ${pathTemplateHDD}"
  mkdir ${pathTemplateHDD}
  chmod 777 ${pathTemplateHDD}
fi

# make sure that lnd is stopped (if runnning)
systemctl stop lnd 2>/dev/null
systemctl stop background 2>/dev/null


if [ "${nointeraction}" == "1" ]; then
  echo "setting RaspiBlitz LCD info"
  sudo sed -i "s/^state=.*/state=copystation/g" /home/admin/raspiblitz.info 2>/dev/null
  sudo sed -i "s/^message=.*/message='Disconnect target HDDs!'/g" /home/admin/raspiblitz.info 2>/dev/null
  echo "Disconnect target HDDs! .. 30ses until continue."
  sleep 30
else
  echo
  echo "*** INIT HDD SCAN"
  echo "Please make sure that no HDDs that you want to sync later to are not connected now."
  echo "PRESS ENTER when ready."
  read key
fi

# finding system drives (the drives that should not be synced to)
systemDrives=$(lsblk -o NAME | grep "^sd")
echo "OK - the following drives detected as system drives:"
echo "$systemDrives"
echo

if [ "${nointeraction}" == "1" ]; then
  sudo sed -i "s/^message=.*/message='Connect now target HDDs ..'/g" /home/admin/raspiblitz.info 2>/dev/null
  sleep 5
fi

# BASIC IDEA:
# 1. get fresh data from bitcoind --> template data
# 2. detect HDDs
# 3. sync HDDs with template data
# repeat

echo 
echo "*** RUNNING ***"
lastBlockchainUpdateTimestamp=1

while :
do
  
  ################################################
  # 1. get fresh data from bitcoind for template data

  # only execute every 30min
  nowTimestamp=$(date +%s)
  secondsDiff=$(echo "${nowTimestamp}-${lastBlockchainUpdateTimestamp}" | bc)
  echo "seconds since last update from bitcoind: ${secondsDiff}"
  echo

  if [ ${secondsDiff} -gt 3000 ]; then
  
    echo "******************************"
    echo "Bitcoin Blockchain Update"
    echo "******************************"

    # stop blockchains
    echo "Stopping Blockchain ..."
    systemctl stop bitcoind 2>/dev/null
    systemctl stop litecoind 2>/dev/null
    sleep 10

    # sync bitcoin
    echo "Syncing Bitcoin ..."

    sudo sed -i "s/^message=.*/message='Updating Template: Bitcoin'/g" /home/admin/raspiblitz.info 2>/dev/null

    # make sure the bitcoin directory in template folder exists
    if [ ! -d "$pathTemplateHDD/bitcoin" ]; then
      echo "creating the bitcoin subfolder in the template folder"
      mkdir ${pathTemplateHDD}/bitcoin
      chmod 777 ${pathTemplateHDD}/bitcoin
    fi

    rsync -a --info=progress2 ${pathBitcoinBlockchain}/chainstate ${pathBitcoinBlockchain}/indexes ${pathBitcoinBlockchain}/blocks ${pathBitcoinBlockchain}/testnet3 ${pathTemplateHDD}/bitcoin

    if [ -d "${pathLitecoinBlockchain}" ]; then

      # sync litecoin
      echo "Syncing Litecoin ..."

      echo "creating the litecoin subfolder in the template folder"
      mkdir ${pathTemplateHDD}/litecoin 2>/dev/null
      chmod 777 ${pathTemplateHDD}/litecoin 2>/dev/null

      sudo sed -i "s/^message=.*/message='Updating Template: Litecoin'/g" /home/admin/raspiblitz.info 2>/dev/null

      rsync -a --info=progress2 ${pathLitecoinBlockchain}/chainstate ${pathLitecoinBlockchain}/indexes ${pathLitecoinBlockchain}/blocks ${pathTemplateHDD}/litecoin

    fi

    # restart bitcoind (to let further setup while syncing HDDs)
    echo "Restarting Blockchain ..."
    systemctl start bitcoind 2>/dev/null
    systemctl start litecoind 2>/dev/null

    # update timer
    lastBlockchainUpdateTimestamp=$(date +%s)
  fi

  ################################################
  # 2. detect connected HDDs and loop thru them

  sleep 4
  echo "" > ./.syncinfo.tmp
  lsblk -o NAME | grep "^sd" | while read -r detectedDrive ; do
    isSystemDrive=$(echo "${systemDrives}" | grep -c "${detectedDrive}")
    if [ ${isSystemDrive} -eq 0 ]; then

      # check if drives 1st partition is named BLOCKCHAIN & in EXT4 format
      isNamedBlockchain=$(lsblk -o NAME,FSTYPE,LABEL | grep "${detectedDrive}" | grep -c "BLOCKCHAIN")
      isFormatExt4=$(lsblk -o NAME,FSTYPE,LABEL | grep "${detectedDrive}" | grep -c "ext4")
      
      # init a fresh device
      if [ ${isNamedBlockchain} -eq 0 ] || [ ${isFormatExt4} -eq 0 ]; then

        echo "*** NEW EMPTY HDD FOUND ***"
        echo "Device: ${detectedDrive}"
        echo "isNamedBlockchain: ${isNamedBlockchain}"
        echo "isFormatExt4:" ${isFormatExt4}

        # check if size is OK
        size=$(lsblk -o NAME,SIZE -b | grep "^${detectedDrive}" | awk '$1=$1' | cut -d " " -f 2)
        echo "size: ${size}"
        if [ ${size} -lt 250000000000 ]; then
          read key
            whiptail --title "FAIL" --msgbox "
THE DEVICE IS TOO SMALL <250GB
Please remove device and PRESS ENTER
            " 9 46
        else

          # find biggest partition
          biggestSize=0
          lsblk -o NAME,SIZE -b | grep "─${detectedDrive}" | while read -r partitionLine ; do
            partition=$(echo "${partitionLine}" | cut -d ' ' -f 1 | tr -cd "[:alnum:]")
            size=$(echo "${partitionLine}" | tr -cd "[0-9]")
            if [ ${size} -gt ${biggestSize} ]; then
              formatPartition="${partition}"
              biggestSize=$size
            fi
            echo "${formatPartition}" > .formatPartition.tmp    
          done

          formatPartition=$(cat .formatPartition.tmp)
          rm .formatPartition.tmp
          
          if [ ${#formatPartition} -eq 0 ]; then
            whiptail --title "FAIL" --msgbox "
NO PARTITIONS FOUND ON THAT DEVICE
Format on external computer with FAT32 first.
Please remove device now.
            " 10 46
          else

            # if config value "nointeraction=1" default to format
            if [ "${nointeraction}" != "1" ]; then
              whiptail --title "Format HDD" --yes-button "Format" --no-button "Cancel" --yesno "
Found new HDD. Do you want to FORMAT now?
Please temp lable device with: ${formatPartition}
              " 10 54
              choice=$?
            else
              choice=0
              sudo sed -i "s/^message=.*/message='Formatting new HDD: ${formatPartition}'/g" /home/admin/raspiblitz.info 2>/dev/null
            fi

            # on cancel
            if [ "${choice}" != "0" ]; then
              whiptail --title "Format HDD" --msgbox "
OK NO FORMAT - Please remove decive now.
              " 8 46
              exit 1
            fi

            # format the HDD
            echo "Starting Formatting of device ..."
            sudo mkfs.ext4 /dev/${formatPartition} -F -L BLOCKCHAIN

          fi

        fi

      fi # end init new HDD

      ################################################
      # 3. sync HDD with template data      

      partition=$(lsblk -o NAME,FSTYPE,LABEL | grep "${detectedDrive}" | grep "BLOCKCHAIN" | cut -d ' ' -f 1 | tr -cd "[:alnum:]")
      if [ ${#partition} -gt 0 ]; then

        # temp mount device
        echo "mounting: ${partition}"
        mkdir /mnt/hdd2 2>/dev/null
        sudo mount -t ext4 /dev/${partition} /mnt/hdd2

        # rsync device
        mountOK=$(lsblk -o NAME,MOUNTPOINT | grep "${detectedDrive}" | grep -c "/mnt/hdd2")
        if [ ${mountOK} -eq 1 ]; then
          if [ "${nointeraction}" == "1" ]; then
            sudo sed -i "s/^message=.*/message='Syncing from Template: ${partition}'/g" /home/admin/raspiblitz.info 2>/dev/null
          fi
          rsync -a --info=progress2 ${pathTemplateHDD}/* /mnt/hdd2
          chmod -r 777 /mnt/hdd2
          rm -r /mnt/hdd2/lost+found 2>/dev/null
          echo "${partition} " >> ./.syncinfo.tmp
        else
          echo "FAIL: was not able to mount --> ${partition}"
        fi
        
        # unmount device
        sudo umount -l /mnt/hdd2

      fi

    fi
  done

  clear
  echo "**** SYNC LOOP DONE ****"
  synced=$(cat ./.syncinfo.tmp | tr '\r\n' ' ')
  echo "HDDs ready synced: ${synced}"
  echo "*************************"
  echo "Its safe to disconnect/remove HDDs now."
  echo "To stop copystation script: CTRL+c"
  echo ""

  sudo sed -i "s/^message=.*/message='Ready HDDs: ${synced}'/g" /home/admin/raspiblitz.info 2>/dev/null

  sleep 25

  clear
  echo "starting new sync loop"
  sleep 5

done