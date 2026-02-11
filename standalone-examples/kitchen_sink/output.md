Press ENTER to login...

[login] Login successful
[login] Requesting shell spawn...

[shell] Laminae v0.38.2 - Type 'help' for commands.
laminae> load ks
[load] downloading ks
[load] saved to /tmp/ks (6494 bytes, 7ms)
laminae> spawn /tmp/ks
[spawn] Requesting spawn of '/tmp/ks'...

+== LAMINAE Kitchen Sink Demo ==+

== 1 Identity ==
  CID(zero-sc): 8
  CID(syscall): 8
  Platform: virt [EMU]
  Time: 32551ms

== 2 Console Ring ==
[ring] zero-syscall write!
  + ring buffer direct write
  seq=212 ovf=0
  VA: con=10000000 heap=30000000 dev=20000000

== 3 Timing ==
  10x yield: 50400ns (5040ns/ea)
  sleep(10ms): 0.0ms
  timer delta: 8288ns

== 4 Containers ==
  count=8
   [8] ks t=0
   [2] virt t=3
   [6] login t=0
   [5] wasm3 t=1
   [3] netd t=1
   [4] c_lwIP t=0
   [7] shell t=0
   [1] lamina t=2
  log(0B): 

== 5 Namespace ==
  register => 0
  lookup => 8 (self)
  + miss => error (ok)

== 6 SHM ==
  + map_create
  attach ERR ffffffffffffffea

== 7 Heap ==
  break: 30010000
  + brk(+4K)
  verify: 256/256
  + brk reset

== 8 FS ==
  fs_open ERR ffffffffffffffea
  / : 2 entries
    sys
    tmp

== 9 DevGraph ==
  dev_count ERR fffffffffffffff3

== 10 Cache ==
  clean => 0
  inv => 0
  c+i => 0

== 11 Barriers ==
  + DMB SY
  + DMB ISH
  + DSB SY
  + ISB
  + DSB+ISB
  + full+fence
  + SEV

== 12 WaitEvent ==
  reason=TIMEOUT 26us

== 13 Errors ==
  isErr(0)=F isErr(42)=F isErr(BASE)=T
  CTX_SW=cafebabec0de0000

== DONE ==
  9.2ms
  27 syscalls + 7 zero-syscall ops

[KITCHEN_SINK_OK]
[spawn] Started container 8, waiting for exit...
[spawn] Container 8 exited with code 0