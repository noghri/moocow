#!/bin/sh



sqlite3 moocow.db <<EOF
	CREATE TABLE quotes (quote, timestamp, usermask, channel, quoteid integer primary key autoincrement);
	CREATE TABLE users (username, host, access, wzdefault , channel, userid integer primary key autoincrement);
EOF
