#!/bin/sh



sqlite3 moocow.db <<EOF
	CREATE TABLE quotes (quote, timestamp, usermask, channel, quoteid integer primary key autoincrement);
EOF
