#!/bin/bash

 
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
pkg-config  --cflags expat > /dev/null
expat_exists=$?
 if [ $expat_exists -ne 0 ]; then
    echo "unable to find expat header files, these are needed to compile modules"
    echo "please installed expat header files, if they are installed, hit Y"
    read -p "Continue (y/n)?"
    [ "$REPLY" == "y" ] || exit 1 
fi
  
OLDIFS="$IFS"
IFS=';'
MODULES=$(grep "^use" moocow.pl | grep -v qw  | awk '{print $2}' | grep -v "^strict" | grep -v "^warnings")
IFS="$OLDIFS"
MODULES=(${MODULES})

BASEMODULES=$(grep "use .* qw" moocow.pl)
BASEMODULES=(${BASEMODULES})
if [ `uname` == "Darwin" ]; then
    echo "DARWIN!"
PERLVERSION=$(perl -v | grep -o "v[0-9]\.*[0-9]*" | cut -c 2-)
CPANM="/opt/local/libexec/perl$PERLVERSION/sitebin/cpanm"
else
    CPANM=`which cpanm`
fi

for var in "${MODULES[@]}"
do
    $CPANM --sudo ${var//;/}
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
           $CPANM --sudo  ${var}
       else
           $CPANM --sudo  $CURBASE::${var}
       fi
    fi
done
$CPANM --sudo  Config::Tiny
$CPANM --sudo  DBD::SQLite
$CPANM --sudo  local::lib
$CPANM --sudo  XMLRCP::Lite
$CPANM --sudo  -f LWP::UserAgent::WithCache
