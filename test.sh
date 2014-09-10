#!/bin/sh
# NOTE: mustache templates need \ because they are not awesome.
cd src
erl -make
erl -sname dmb -s mnesia start
dmb:setup().
dmb:run(100, 1, 1).