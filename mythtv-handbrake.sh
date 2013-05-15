#!/bin/bash

#By:
#http://reubencrane.com/blog/?p=80
#Modified by Marty Gilbert, 04/15/2013

#My attempt to cut commercials from myth recording and save as mkv
#Run as MythTV User Job with %FILE% as argument 1
#Argument 1: filename

######## USER SETTINGS ###############
logdir="/var/log/mythtv"
mythrecordingsdir="/video/storage"
tmpdir="/video/tmp" 
outdir="/video/videos"
#outdir="/tmp"
scriptstarttime=$(date +%F-%H%M%S)
logfile="$logdir/$scriptstarttime-COMCUT.log"

#Database Info
USER="mythtv";
PASS="mypass";
DB="mythconverg";

HANDBRAKE="/bin/HandBrakeCLI";
FFMPEG="/bin/ffmpeg";
MKVMERGE="/bin/mkvmerge";


######## NICE THE PROCESS ##################3
MYPID=$$
renice 19 $MYPID
ionice -c 3 -p $MYPID

######## CLEAN-UP FROM PREVIOUS JOB ###############
rm -f $tmpdir/tmp*.mpg*



######## GET INFO FROM DB ###############

CHANID=$(echo $1 | cut -c 1-4);
STARTTIME=$(echo $1 | cut -c 6-19);


#Retrieve recording info from mysql
W=$(mysql -u$USER -p$PASS $DB --disable-column-names -e "SELECT data FROM recordedmarkup WHERE chanid=$CHANID AND starttime=$STARTTIME AND type=30;");

L=$(mysql -u$USER -p$PASS $DB --disable-column-names -e "SELECT data FROM recordedmarkup WHERE chanid=$CHANID AND starttime=$STARTTIME AND type=31;");

FPS=$(mysql -u$USER -p$PASS $DB --disable-column-names -e "SELECT data FROM recordedmarkup WHERE chanid=$CHANID AND starttime=$STARTTIME AND type=32;");

#type values/meanings in recordedmarkup:
#   0 MARK_CUT_END
#   1 MARK_CUT_START
#   4 MARK_COMM_START
#   5 MARK_COMM_END
QRY=$(mysql -u$USER -p$PASS $DB --disable-column-names -e "SELECT type,mark FROM recordedmarkup WHERE chanid=$CHANID AND starttime=$STARTTIME AND type in (0,1,4,5) ORDER BY mark;");

NAME=$(mysql -u$USER -p$PASS $DB --disable-column-names -e "SELECT title FROM recordedprogram WHERE chanid=$CHANID AND starttime=$STARTTIME;");

USTART=$(mysql -u$USER -p$PASS $DB --disable-column-names -e "SELECT unix_timestamp(starttime) FROM recordedprogram WHERE chanid=$CHANID AND starttime=$STARTTIME;");

MYSTART=`date "+%Y_%m_%d_%I%M" -d "@$USTART"`

NAME=`echo "$NAME" | sed 's/ /_/g' | sed 's/://g' | sed 's/?//g' | sed s/"'"/""/g`
NAME="$MYSTART"_"$NAME";

#debug
echo "Query: $QRY" >> "$logfile";
echo "FPS: $FPS" >> "$logfile";
echo "NAME: $NAME" >> "$logfile";
echo "L: $L" >> "$logfile";
echo "W: $W" >> "$logfile";

##############
# FUNCTIONS
##############

#### ffmpeg Cut Src Files into clips ###
function ffmpeg_cut_src {
    #convert QRY to array
    array=( $( for i in $QRY ; do echo $i ; done ) )
    SS=0.0 #SLOW SEEK
    SKIP=0 #FAST SEEK 
    cnt=${#array[@]} #NUMBER OF ARRAY ELEMENTS
    if [ "$cnt" -eq 0 ]; then
        #encode file to the $tmpdir so it can be processed
        #does this do anything? or can I just copy it?
        "$FFMPEG" -i "$mythrecordingsdir/$1" -vcodec copy -acodec copy "$tmpdir/tmp_orig.mpg"
        #cp "mythrecordingsdir/$1" "$tmpdir/tmp_orig.mpg"
        echo "No slices. One big file" >> "$logfile"
        return 1;
    fi

    for (( i=0 ; i<cnt ; i++ ))
    do
        if [ ${array[$i]} == 0 ] || [ ${array[$i]} == 5 ]; then 
            (( i++ ))
            SS=$(echo "${array[$i]} / $FPS * 1000" | bc -l)
            if [ "$SS" -ne 0 ]; then
                SS=${SS:0:(${#SS}-17)}
            fi
        elif [ ${array[$i]} == 1 ] || [ ${array[$i]} == 4 ]; then 
            (( i++ ))
            T=$(echo "(${array[$i]} / $FPS * 1000) - $SS" | bc -l)
            if [ "$T" -ne 0 ]; then
                T=${T:0:(${#T}-17)}
            fi
    
            #if SLOW SEEK is greater then 30 seconds the use FAST SEEK
            if [ $(echo "scale=0;$SS/1" | bc -l) -gt 30 ]; then
                SKIP=$(echo "$SS-30" | bc -l)
                SS=30
            fi
            prettyI=`printf "%03d" $i`;
            "$FFMPEG" -ss $SKIP -i $mythrecordingsdir/$1 -ss $SS \
                -t $T -vcodec copy -acodec copy $tmpdir/tmp$prettyI.mpg
        fi
    done
    return $cnt;
}

#### HandBrakeCLI files ####
function handbrake_encode {
    #for file in $(find $tmpdir -name tmp\*.mpg | sort); do
    #echo "for file in $(ls -rt $tmpdir/tmp*.mpg); do"
    for file in $(ls -1 $tmpdir/tmp*.mpg); do
        echo "File Found for Encoding - $file" >> "$logfile"
        if [ "$1" -eq 1 ]; then
            echo "only one file found" >> "$logfile";
            output="$outdir/$NAME.mkv"
        else 
            output="$file.mkv"
        fi

        "$HANDBRAKE" -i "$file" -o "$output" -f mkv -e x264 --x264-preset superfast --x264-profile high --x264-tune film -q 30 -E lame --ac 2 --ab 128 --audio-fallback ffac3 --crop 0:0:0:0 -w $W -l $L --decomb
        echo "HandBrakeCLI exit code:$?" >> "$logfile"
    done
}

#### MKVMERGE FILES ######
function merge_files {
    MERGE=" "
    PLUS=""
    #for file in $(find $tmpdir -name tmp\*.mpg.mkv | sort); do
    #echo "for file in $(ls -rt $tmpdir/tmp*.mpg.mkv); do"
    for file in $(ls -1 $tmpdir/tmp*.mpg.mkv); do
        echo "File Found for Merging - $file"
        MERGE=$(echo "$MERGE $PLUS$file")
        PLUS="+"
    done

    echo "$MKVMERGE" -o $outdir/$NAME.mkv "$MERGE" >> "$logfile"
    "$MKVMERGE" -o $outdir/$NAME.mkv $MERGE 
    echo "mkvmerge exit code:$? " >> "$logfile"
}

###### END OF FUNCTIONS #########


######## BEGIN MAIN EXECUTION ###############

echo "ComCut & Transcode job $1 starting at $scriptstarttime" >> "$logfile"

#cut the file, if commercials were flagged
ffmpeg_cut_src $1;
numslices=$?

#Encode the slice(s)
handbrake_encode $numslices;

#If more than one slice, combine them
if [ "$numslices" -gt 1 ]; then
    merge_files;
fi

echo "Job Finished! $(date +%F-%H%M%S)"  >> "$logfile"


######## END MAIN EXECUTION ###############


