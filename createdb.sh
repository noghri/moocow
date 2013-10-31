#!/bin/sh
FILENAME=$1
if [ -z $FILENAME ]; then
       FILENAME="moocow.db"
fi

if [ -f $FILENAME ]; then
	echo "File $1 exists, do you which to overwrite? Y/N"
	read YN 
	if [ x$YN != 'xY' ]; then
		echo "Got $YN aborting..."
		exit 1
	fi
	rm $FILENAME
fi


sqlite3 $FILENAME <<EOF
	CREATE TABLE tscores (nick, score, id integer primary key autoincrement);
        CREATE TABLE trivia (question, answer, lastused, qid integer primary key autoincrement);
        CREATE TABLE rssfeeds (nick, title, rssurl, titleid integer primary key autoincrement);
	CREATE TABLE quotes (quote, timestamp, usermask, channel, quoteid integer primary key autoincrement);
	CREATE TABLE users (username unique, access, wzdefault , userid integer primary key autoincrement);
	CREATE TABLE usermask (hostmask, userid integer not null, foreign key(userid) REFERENCES users(userid) ON DELETE CASCADE);
	CREATE TABLE channel (channame unique, chankey, ownerid not null, chanid integer primary key autoincrement, foreign key(ownerid) REFERENCES users(userid));
	CREATE TABLE chanuser (chaccess, userid not null, chanid integer not null, chuserid integer primary key autoincrement, foreign key(chanid) REFERENCES channel(chanid) ON DELETE CASCADE, foreign key(userid) REFERENCES users(userid));
	
EOF
