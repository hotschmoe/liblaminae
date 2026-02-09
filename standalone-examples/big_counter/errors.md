[login] Container ID: 6

  _                 _
 | | __ _ _ __ ___ (_)_ __   __ _  ___
 | |/ _` | '_ ` _ \| | '_ \ / _` |/ _ \
 | | (_| | | | | | | | | | | (_| |  __/
 |_|\__,_|_| |_| |_|_|_| |_|\__,_|\___|

Container-native research kernel for ARM64

Press ENTER to login...

[login] Login successful
[login] Requesting shell spawn...

[shell] Laminae v0.35.7 - Type 'help' for commands.
laminae> load big
[load] Fetching: http://10.0.2.2:8080/binary/2/big
[load] Target: 10.0.2.2:8080 (session=2)
[load] Received 14112 bytes
[load] Saved to /tmp/big
[spawn] Requesting spawn of '/tmp/big'...

[CONTAINER FAULT] DATA ABORT at 0x0000000000000010 PC=0x000000000001005C
[CRASH] Container 8 crashed: type=1 addr=0x0000000000000010 pc=0x000000000001005C
[spawn] Started container 8, waiting for exit...
[spawn] Container 8 exited with code 3735879936
laminae> load big2
[load] Fetching: http://10.0.2.2:8080/binary/2/big2
[load] Target: 10.0.2.2:8080 (session=2)
[load] Received 19706 bytes
[load] Saved to /tmp/big2
[spawn] Requesting spawn of '/tmp/big2'...

[CONTAINER FAULT] DATA ABORT at 0x0000000000000010 PC=0x000000000001005C
[CRASH] Container 9 crashed: type=1 addr=0x0000000000000010 pc=0x000000000001005C
[spawn] Started container 9, waiting for exit...
[spawn] Container 9 exited with code 3735879936



--------------------------------


laminae> load big
[load] Fetching: http://10.0.2.2:8080/binary/1/big
[load] Target: 10.0.2.2:8080 (session=1)
[load] Fetch failed: ReceiveFailed
laminae> load h_l
[load] Fetching: http://10.0.2.2:8080/binary/1/h_l
[load] Target: 10.0.2.2:8080 (session=1)
[load] Fetch failed: ConnectionFailed (socket: IccError)
laminae> mem

Memory Info:
  (Memory stats require kernel syscall - not yet implemented)
  Current SP: 0x7FFFFF01F9A0

laminae> stack

Stack Info:
  Current SP: 0x7FFFFF01F9A0
  Frame Pointer: 0x275E8
  Link Register: 0x1213C

laminae> load hll
[load] Fetching: http://10.0.2.2:8080/binary/1/hll
[load] Target: 10.0.2.2:8080 (session=1)
[load] Fetch failed: ReceiveFailed


---------------------------------


[shell] Laminae v0.35.7 - Type 'help' for commands.
laminae> load hl
[load] Fetching: http://10.0.2.2:8080/binary/2/hl
[load] Target: 10.0.2.2:8080 (session=2)
[load] Received 116 bytes
[load] Saved to /tmp/hl
[spawn] Requesting spawn of '/tmp/hl'...
[Embedded] Hello from embedded binary!
[HELLO_OK]
[spawn] Started container 8, waiting for exit...
[spawn] Container 8 exited with code 0
laminae> load bg
[load] Fetching: http://10.0.2.2:8080/binary/2/bg
[load] Target: 10.0.2.2:8080 (session=2)
[load] Fetch failed: ReceiveFailed


----------------------------------

[shell] Laminae v0.35.7 - Type 'help' for commands.
laminae> ls /tmp
(empty directory)
laminae> load bg
[load] Fetching: http://10.0.2.2:8080/binary/0/bg
[load] Target: 10.0.2.2:8080 (session=0)
[load] Received 924 bytes
[load] Saved to /tmp/bg
[spawn] Requesting spawn of '/tmp/bg'...
8145704Count00 ms20201[spawn] Started container 8, waiting for exit...
[spawn] Container 8 exited with code 0

----------------------------final yay!!

[shell] Laminae v0.35.7 - Type 'help' for commands.
laminae> load bigg
[load] Fetching: http://10.0.2.2:8080/binary/1/bigg
[load] Target: 10.0.2.2:8080 (session=1)
[load] Received 371 bytes
[load] Saved to /tmp/bigg
[spawn] Requesting spawn of '/tmp/bigg'...
=== BIG COUNTER ===
0 1 2 3 4 5 6 7 8 9 
Done 0ms
[BIG_COUNTER_OK]
[spawn] Started container 8, waiting for exit...
[spawn] Container 8 exited with code 0


------------- ANSWER

Networking — yeah, the truncation you saw earlier (924/1146 bytes) is the bottleneck. Once that's solid, you can go back to the fuller demo with banners, elapsed timing per count, etc. The code itself is proven to work — it's just a matter of how many bytes can survive the transfer.