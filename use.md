# Testing the librespot build on your Pi

This branch builds the Spotify Connect renderer (librespot) the same way moOde's
**Install** button in Renderer Config does, but caps how many compiler jobs run in
parallel so the board does not run out of RAM and swap to the SD card.

On a 1 GB board the current moOde build runs 4 jobs: 81 min, and the board
crashed twice during testing. Two jobs built the same package in 39 min.

## Run it

```bash
wget https://raw.githubusercontent.com/Gjuju/pkgbuildx86/test/librespot-cargo-jobs/librespot-test-build.sh
chmod +x librespot-test-build.sh
sudo ./librespot-test-build.sh
```

It asks how many parallel jobs to use and suggests a count for your board. Press
Enter to accept the suggestion.

Then wait. The build takes 25 to 90 min depending on the board and the job
count - around 40 min on a 1 GB Pi 3B, nearer 25 on a Pi 5. Nothing is
installed and no service is touched, so the player keeps working meanwhile.

## Running over SSH

Most people run this from another machine over SSH. **A build takes 25 to 90
minutes, and it dies the moment the SSH session ends** - whatever ends it:

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
