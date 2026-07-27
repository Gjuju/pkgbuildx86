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

The script ends with a summary block. Copy it into your forum reply:

```text
===== copy this into your forum reply =====
model    Raspberry Pi 3 Model B Plus Rev 1.3
os       Debian GNU/Linux 13 (trixie) (aarch64, arm64)
ram      926 MB, 4 cores
rustc    1.96.0
jobs     2 auto (2 advised)
branch   test/librespot-cargo-jobs @ 802f222
result   OK in 73m12s
disk     8213 MB written to mmcblk0
swap     5104 MB paged out, peak 782 MB in use
load     peak 2.10 (1 min avg, 4 cores), sampled every 30 s
io       11% iowait, card busy 34% of the build, 1204 MB read
package  librespot_0.8.0-1moode1_arm64.deb
===========================================
```

A build that fails prints the same block, with what it got to. Those runs are the
most useful ones, please post them too.

The full log is `librespot-test-build.log` in your home directory.

## Install what was built

The package is left in your home directory. To install it:

```bash
cd ~
sudo moodeutl --installpkg spotify
```

Then reboot and turn Spotify Connect on in Configure > Renderers.

## Options

```bash
sudo ./librespot-test-build.sh --jobs 4     # force a job count, no prompt
sudo ./librespot-test-build.sh --auto       # no prompt, let the script decide
sudo ./librespot-test-build.sh --help
```

Download the script rather than piping it into a shell - piped, it cannot ask you
anything and will pick the job count on its own.
