#!/bin/bash -ex

cd _site
git add --all
git commit
git push origin master
cd ..
