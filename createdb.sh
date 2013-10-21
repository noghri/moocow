#!/bin/sh

if [ -z $1 ]; then
    echo "Please pass the filename where the database will be stored"
    exit 1
fi

if [ -f $1 ]; then
	echo "File $1 exists, do you which to overwrite? Y/N"
	read YN 
	if [ x$YN != 'xY' ]; then
		echo "Got $YN aborting..."
		exit 1
	fi
	rm $1
fi


sqlite3 $1 <<EOF
	CREATE TABLE quotes (quote, timestamp, usermask, channel, quoteid integer primary key autoincrement);
	CREATE TABLE users (username unique, access, wzdefault , userid integer primary key autoincrement);
	CREATE TABLE usermask (hostmask, userid integer not null, foreign key(userid) REFERENCES users(userid) ON DELETE CASCADE);
	CREATE TABLE channel (channame unique, ownerid not null, chanid integer primary key autoincrement, foreign key(ownerid) REFERENCES users(userid));
	CREATE TABLE chanuser (chaccess, userid not null, chanid integer not null, chuserid integer primary key autoincrement, foreign key(chanid) REFERENCES channel(chanid) ON DELETE CASCADE);
	
EOF
