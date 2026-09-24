#!/bin/zsh
# Double-clickable launcher; the Makefile owns build and run.
cd "$(dirname "$0")" && exec make run
