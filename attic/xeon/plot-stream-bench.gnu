#!/usr/bin/env gnuplot
set term postscript enhanced color 20

set log xy
se gri
set out "benchmark-stream-xeon.eps"
set xlabel "memory footprint(MB)"
set ylabel "load bandwidth (GB/s)"
set arrow from 40,10 to 40,1000 nohead lc 2
set arrow from 4,10 to 4,1000 nohead lc 2
set label 1 at first 100,12 "Memory"
set label 3 at first 10,12 "L3"
set label 2 at first 1,12 "L2"
plot 'benchmark-stream-xeon.txt' u (4*$1/2**20):(2*$4) lw 2 ps 4 t ""
