#!/bin/bash
pelican content -o output -s pelicanconf.py
ghp-import output
git push git@github.com:pliniker/pliniker.github.io.git gh-pages:master
