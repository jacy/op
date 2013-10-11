#!/bin/sh
# NOTE: mustache templates need \ because they are not awesome.
rebar compile
erl -pa ebin  deps/*/ebin  -sname ujacy
