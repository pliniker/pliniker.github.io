#!/bin/bash -ex

cd _site
git checkout master
cd ..
./site rebuild
