#!/bin/sh
test -z "$AUDIO_KBIT" && AUDIO_KBIT=80

getlen() {
	ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$1" | cut -d '.' -f 1
}
getdim() {
  res=$(ffprobe -v error -of flat=s=_ -select_streams v:0 -show_entries stream=height,width "$1")
  width=$(echo "$res" | grep width | cut -d = -f 2)
  height=$(echo "$res" | grep height | cut -d = -f 2)
}
mb() {
	echo $(($1 / (1024 * 1024)))
}
filesize() {
	stat "$1" | awk '/Size:/ {print $2}'
}
getrate() {
	mbs="$1"
	echo $((($mbs * 8192) / $len))

}
get_file_ext() {
	printf "%s" "$1" | awk '{n=split($0,a,".");print a[n];}'
}
strip_file_ext() {
	le=$(get_file_ext "$1"| wc -c)
	ls=$(printf "%s" "$1"|wc -c)
	l=$(($ls - $le))
	printf "%s" "$1"|cut -b -$l
}

scaled_height() {
# $1 - original width  - w
# $2 - original height - h
# $3 - new width       - n
cat << EOF | bc
w=$1
h=$2
n=$3
scale=20
f=w/n
scale=0
i=h/f
scale=1
j=h/f
define a(i,j) {
	scale=0
	if(i%2 ==0) return i;
	if(j-i>=0.5) return i+1;
	return i-1;
}
a(i,j)
EOF
}

getvobs() {
	vobs=
	for i in `seq 1 9` ; do
		for j in `seq 1 9` ; do
			f=$(printf "%s/VIDEO_TS/VTS_%.2d_%d.VOB" "$1" $i $j)
			[ -e "$f" ] || {
				test $j = 0 && continue
				break
			}
			vobs="${vobs}|$f"
		done
	done
	printf "%s" "$vobs"| cut -b 2-
}
dvdlen() {
	s="$IFS"
	IFS='
'
	l=0
	for x in $(getvobs "$1" | sed 's/|/\n/g') ; do
		l=$(($l + $(getlen "$x")))
	done
	printf %s "$l"
	IFS="$s"
}


DVD=false
vid="$1"
if test -d "$vid/VIDEO_TS" ; then
	output="$(basename "$vid")""-reencoded.mkv"
	len=$(dvdlen "$vid")
	vid="concat:""$(getvobs "$vid")"
	DVD=true
	echo "warning: DVD length calculation is buggy and can be completely off"
elif ! test -e "$vid"  ; then
	echo "video '$vid' not found"
	exit 1
else
	output=$(strip_file_ext "$vid")"-reencoded.mkv"
	len=$(getlen "$vid")
fi
getdim "$vid"
echo "seconds: $len"
echo "width : $width"
echo "height: $height"
if ! $DVD ; then
	sizemb=$(mb $(filesize "$vid"))
	echo "size: $sizemb MB"
	currrate=$(getrate $sizemb)
else
	currrate=0
	scan="-probesize 1G -analyzeduration 1G"
	ffmpeg -probesize 1G -analyzeduration 1G -i "$vid"
	echo "enter streams to pick like this: -map 0:1 -map 0:4"
	read maps
	echo "creating temp file: with map $maps"
	ffmpeg -probesize 1G -analyzeduration 1G -i "$vid" -f mpeg -c copy $maps intermediate.mpeg
	ffmpeg -probesize 1G -analyzeduration 1G -i intermediate.mpeg
	echo "enter new streams to pick: like -map 0:1 -map 0:4"
	read maps
	vid=intermediate.mpeg
fi
echo "bitrate: $currrate"

echo "----re-encoding----"
neww=0
while test $neww = 0 ; do
	echo "enter new width [default: $width, use -1 for auto-fit]"
	read neww
	[ -z "$neww" ] && neww=$width
	if test $(($neww % 2)) = 1 ; then
		echo "new width must be divisible by 2"
		neww=0
	elif test $neww = -1 ; then
		neww=$width
	fi
done
defh=$height
if test $neww != $width ; then
	defh=$(scaled_height $width $height $neww)
fi
newh=0
while test $newh = 0 ; do
	echo "enter new height [default: $defh, use -1 for auto-fit]"
	read newh
	[ -z "$newh" ] && newh=$defh
	if test $(($newh % 2)) = 1 ; then
		echo "new height must be divisible by 2"
		newh=0
	fi
done
newmb=
while test -z "$newmb" ; do
echo "enter desired size in MB"
read newmb
done
br=$(getrate $newmb)
vbr=$((br - $AUDIO_KBIT))
echo "targeted bitrate is ${AUDIO_KBIT}kb for audio and $vbr for video, total: $br"
echo "hit enter to accept, CTRL-C to break or a number if you want to set the video bitrate"
read n
test -z "$n" || vbr=$n

# delete already existing output file, so ffmpeg doesn't ask questions
test -f "$output" || rm -f "$output"

# option making mp4 start immediately (streamable): -movflags faststart
ffmpeg $scan -y -i "$vid" $maps -max_muxing_queue_size 1024 -c:v libx264 -preset medium -b:v ${vbr}k -vf scale=${neww}:${newh} -pass 1 -strict -2 -an -f mp4 /dev/null && \
ffmpeg $scan    -i "$vid" $maps -max_muxing_queue_size 1024 -c:v libx264 -preset medium -b:v ${vbr}k -vf scale=${neww}:${newh} -pass 2 -c:a libopus -strict -2 -b:a ${AUDIO_KBIT}k -ac 2 "$output" && \
rm -f ffmpeg2pass-0.log ffmpeg2pass-0.log.mbtree
#rm intermediate.mpeg
# copy mp4 into mkv, making it seekable: -i foo.mp4 -map 0 -c copy bar.mkv
