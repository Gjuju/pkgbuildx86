# Testing the librespot build on your Pi

This branch builds the Spotify Connect renderer (librespot) the same way moOde's
**Install** button in Renderer Config does, but caps how many compiler jobs run in
parallel so the board does not run out of RAM and swap to the SD card.

moOde currently builds with one job per core - four on a Pi 3B. On a 1 GB Pi 3B,
two jobs build the package in 40 min where one job takes 53 min, and three jobs
are no faster than two while writing a third more to the SD card. Measurements
in the appendix at the end of this page.

## Run it

```bash
wget https://raw.githubusercontent.com/Gjuju/pkgbuildx86/test/librespot-cargo-jobs/librespot-test-build.sh
chmod +x librespot-test-build.sh
sudo ./librespot-test-build.sh
```

It asks how many parallel jobs to use and suggests a count for your board. Press
Enter to accept the suggestion.

Then wait. Nothing is installed and no service is touched, so the player keeps
working meanwhile.

How long it takes depends mostly on how much RAM the board has, because the
compiler needs more than most Pis have and the rest comes from swap:

| board | RAM | expect |
| --- | --- | --- |
| Pi 5 | 4-8 GB | around 25 min |
| Pi 4 | 2-4 GB | 30 to 45 min |
| Pi 3B, 3B+ | 1 GB | 40 to 55 min (measured) |
| Pi 3A+, Zero 2 W | 512 MB | **about 6 hours, when it succeeds** |

**On a 512 MB board, expect hours - and expect it may not succeed.** One user
reported a successful build on a Pi 3A+ in roughly 6 hours, at moOde's default
of 4 jobs and on an older compiler. Others have had it fail. Plan to leave it
running overnight rather than watching it, and if it does fail, post the report:
those are the runs this whole exercise is about.

**A slow build is not a stuck build**, and the log is a poor way to tell the two
apart. Cargo only prints `Compiling <crate>` when it *starts* a crate, so the
file sits unchanged for as long as that crate takes. On a 512 MB board we have
watched it stay silent for over half an hour with the build working the whole
time. Look at the compiler instead:

```bash
top -bn1 | grep rustc
```

A `rustc` line means work is being done, whatever the log is doing. For a
certainty, run it again a minute later and check that the `TIME+` column has
grown - that column is CPU time actually consumed, so it only moves if the
compiler is running.

Killing it loses the measurement, and a killed run is not a failed run - it just
leaves us with no data for the board we know least about.

## Running over SSH

Most people run this from another machine over SSH. **The build runs for
somewhere between half an hour and several hours, see the table above, and it
dies the moment the SSH session ends** - whatever ends it:

- the laptop or desktop you are connected from going to sleep
- the wifi dropping, the router restarting, switching network
- closing the terminal window, or closing the laptop lid
- a phone or tablet SSH app being backgrounded by the system
- an idle timeout on your side or on the Pi

The reason is not the Pi giving up: when the session ends, the system sends a
hangup signal to everything running in that terminal, and the terminal itself
disappears, so the build has nowhere left to write. Running it with `&` in the
background does not help.

The fix is to start the build in a session that outlives the connection.

**With tmux** (or `screen`), which also keeps the question at the start working:

```bash
tmux new -s build
sudo ./librespot-test-build.sh
```

Press `Ctrl-b` then `d` to detach - the build keeps going. Reconnect later and
run `tmux attach -t build` to see where it is. With `screen`, the commands are
`screen -S build`, `Ctrl-a` then `d`, and `screen -r build`.

If neither is installed: `sudo apt install tmux`.

**Without tmux**, start it detached. It cannot ask you anything this way, so pass
the job count on the command line:

```bash
sudo nohup ./librespot-test-build.sh --auto > /dev/null 2>&1 &
tail -f ~/librespot-test-build.log
```

The `tail` is only a viewer - interrupting it or losing the connection leaves the
build running. Reconnect and `tail -f` again, or just read the file at the end.

## Report back

The script ends with a summary block like this one. Copy yours into your
forum reply:

```text
===== copy this into your forum reply =====
moode    10.3.1 2026-07-22
model    Raspberry Pi 3 Model B Rev 1.2
pirev    0xa22082 3B 1.2 1GB Embest BCM2837 3 1
os       RPiOS: 13.6 Trixie 64-bit | Linux: 6.18.34 64-bit (arm64)
ram      905 MB, 4 cores
rustc    1.96.0
jobs     2 chosen (1 advised)
stack    default, RUST_MIN_STACK not set
branch   test/librespot-cargo-jobs @ 3120e91
result   OK in 38m55s total, 33m10s compiling
disk     3823 MB written to mmcblk0
swap     3055 MB paged out, peak 1501 MB in use
load     peak 3.94 (1 min avg, 4 cores), sampled every 30 s
io       20% iowait, card busy 27% of the build, 4796 MB read
package  librespot_0.8.0-1moode1_arm64.deb
===========================================
```

A build that fails prints the same block, with what it got to. Those runs are the
most useful ones, please post them too.

The full log is `librespot-test-build.log` in your home directory.

## If the build fails with a rustc crash

There is a known crash that has nothing to do with your board or with anything
you did. The log ends like this:

```text
error: rustc interrupted by SIGSEGV, printing backtrace
  libLLVM.so...(llvm::FPPassManager::runOnFunction+0x6b0)
error: could not compile `librespot-protocol` (lib)   (signal: 11)
```

The compiler runs out of stack while generating code for one crate. It is not
out of memory, and it is not caused by the number of jobs - it hits at random,
so the same command may well succeed on the next attempt.

**Please post the failed report first**, then try again with a bigger compiler
stack, which is the remedy rustc itself suggests:

```bash
sudo ./librespot-test-build.sh --stack --keep-clone
```

`--keep-clone` reuses what is already downloaded. Post that second report too,
and say whether it was a retry - whether the workaround helps is exactly what we
are trying to find out.

## Install what was built

The package is left in your home directory. To install it:

```bash
cd ~
sudo moodeutl --installpkg spotify
```

Then reboot and turn Spotify Connect on in Configure > Renderers.

## Options

```bash
sudo ./librespot-test-build.sh --jobs 4      # force a job count, no prompt
sudo ./librespot-test-build.sh --auto        # no prompt, let the script decide
sudo ./librespot-test-build.sh --keep-clone  # reuse the download, for a retry
sudo ./librespot-test-build.sh --stack       # build with a bigger compiler stack
sudo ./librespot-test-build.sh --help
```

`--keep-clone` resets the copy already in your home directory onto the latest
version of the branch instead of downloading it again - use it for a second run.
Without it, every run starts from a fresh download.

`--stack` raises the compiler stack to 16 MB for that run only, nothing is kept
on your system. It is off by default so that a normal run measures what moOde's
own Install button does.

Download the script rather than piping it into a shell - piped, it cannot ask you
anything and will pick the job count on its own.

## Appendix: measurements so far

One board, one compiler, one variable - the job count. Raspberry Pi 3B rev 1.2,
905 MB usable, rustc 1.96.0, moOde 10.3.1, Trixie arm64, on its SD card. All
three built with `--stack`.

| jobs | time | written | swapped out | peak swap | read | peak load | card busy |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | **53m10s** | 1931 MB | 1153 MB | 1114 MB | 2164 MB | 2.10 | 10% |
| 2 | **39m42s** | 3635 MB | 2856 MB | 1494 MB | 4940 MB | 4.36 | 30% |
| 3 | 39m26s | 4705 MB | 3933 MB | 1514 MB | 6606 MB | 6.88 | 44% |

Going from 1 to 2 jobs saves 25% of the time. Going from 2 to 3 saves nothing -
16 seconds, which is noise - and writes 29% more to the card. Two is the knee of
the curve on a 1 GB board, which is what the heuristic advises there.

The peak swap figures show why. Even a single rustc pushes 1114 MB into swap on
a 905 MB board, so one compiler already exceeds the RAM. By two jobs the working
set has plateaued at about 1500 MB, and a third job only makes swap churn
faster: it moves more pages without ever holding more of them.

The cost is not free. Two jobs write 88% more to the card than one. That is a
fair trade for 13 minutes on a one-off build, but if you care more about your SD
card than about the wait, one job is a legitimate choice.

One report from outside this table: a Pi 3A+ (512 MB) built successfully in
about 6 hours at 4 jobs, on rustc 1.85. It shows the default *can* finish on
512 MB, not that it reliably does - other users on small boards see it fail,
which is what started this.

Not yet measured: a 512 MB board on a current compiler, and 4 jobs on a 2 GB
board. If you have either, those are the two runs worth posting.

### Where the card writes come from

moOde swaps to a 4 GB file on the card itself (`Mechanism=swapfile`,
`FixedSizeMiB=4096`), not to zram, so every paged out megabyte is a real write.
Comparing the two figures shows what the extra jobs actually cost:

| jobs | swapped out | written in total | share that is swap |
| --- | --- | --- | --- |
| 1 | 1153 MB | 1931 MB | 60% |
| 2 | 2856 MB | 3635 MB | 79% |
| 3 | 3933 MB | 4705 MB | **84%** |

The build itself writes about the same in all three runs, roughly 780 MB - it
produces identical artifacts, so it should. Everything above that, and all of
the growth, is paging. Past two jobs on a 1 GB board the card is not doing more
work, it is just moving pages back and forth, for no time saved at all.
