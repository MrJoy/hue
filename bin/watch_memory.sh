#!/bin/bash

while [ 1 ]; do
  ps auxwww |
    grep rub[y] |
    grep flux_hue |
    awk '{ print $6 }' | perl -pse 's/\n/, /g' | perl -pse 's/, $/\n/'
  sleep 1
done
