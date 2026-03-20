#!/bin/bash

set -euvo pipefail

bun build --compile src/interpreter.ts --outfile bin/ktg
bun build --compile src/compiler.ts --outfile bin/ktgc

sudo ln -sf bin/ktg /usr/local/bin/ktg
sudo ln -sf bin/ktgc /usr/local/bin/ktgc
