#!/bin.bash
OLDIFS="$IFS"
IFS=';'
MODULES=$(egrep "^use" moocow.pl | grep -v qw  | awk '{print $2}' | egrep -v "^strict" | egrep -v "^warnings")
IFS="$OLDIFS"
MODULES=(${MODULES})

BASEMODULES=$(egrep "use .* qw" moocow.pl)
BASEMODULES=(${BASEMODULES})


for var in "${MODULES[@]}"
do
    echo "cpanm --sudo ${var//;/}"
done

CURBASE=""
for var in "${BASEMODULES[@]}"
do
    var="${var//use/}"
    var="${var//qw(/}"
    var="${var//)/}"
    var="${var//\n/}"
    IFS=' ' read -a newarr <<< "${var}"
    if [  "${var}" ]; then
       if ! grep -q "::" <<<${var}; then
           CURBASE=${var}
           echo "cpanm --sudo ${var}"
       else
          echo "cpanm --sudo $CURBASE::${var}"
       fi
    fi
done
