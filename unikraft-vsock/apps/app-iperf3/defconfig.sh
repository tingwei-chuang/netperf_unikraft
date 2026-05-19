#!/bin/bash
UK_DEFCONFIG=<(cat ./_defconfig | sed 's:<<PWD>>:'`pwd`':') make -B defconfig
