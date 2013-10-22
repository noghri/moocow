#!/bin.bash
if [ ! `which gcc` ]; then
     echo "gcc not installed, need gcc to build modules"
     exit 1
fi

if [ ! `which make` ]; then
    echo "make not installed, need make to build modules"
    exit 1
fi


if [ `which curl` ]; then
    curl -L http://cpanmin.us | perl - --sudo App::cpanminus
else
   echo "curl not available, trying cpan"
   if [ `which cpan` ]; then
       cpan App::cpanminus
   else
       echo "curl and cpan not available, cannot install"
       exit 1
   fi
fi

 if [ ! `pkg-config --cflags expat` ]; then
    echo "unable to find expat header files, these are needed to compile modules"
    echo "please installed expat header files, if they are installed, hit Y"
    read -p "Continue (y/n)?"
    [ "$REPLY" == "y" ] || exit 1 
fi
  
OLDIFS="$IFS"
IFS=';'
MODULES=$(egrep "^use" moocow.pl | grep -v qw  | awk '{print $2}' | egrep -v "^strict" | egrep -v "^warnings")
IFS="$OLDIFS"
MODULES=(${MODULES})

BASEMODULES=$(egrep "use .* qw" moocow.pl)
BASEMODULES=(${BASEMODULES})


for var in "${MODULES[@]}"
do
    cpanm --sudo ${var//;/}
done

CURBASE=""
for var in "${BASEMODULES[@]}"
do
    var="${var//use/}"
    var="${var//qw(/}"
    var="${var//)/}"
    var="${var//;/}"
    IFS=' ' read -a newarr <<< "${var}"
    if [  "${var}" ]; then
       if ! grep -q "::" <<<${var}; then
           CURBASE=${var}
           cpanm --sudo ${var}
       else
           cpanm --sudo $CURBASE::${var}
       fi
    fi
done